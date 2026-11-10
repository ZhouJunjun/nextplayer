package dev.anilbeesetti.nextplayer.feature.player.service

import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageButton
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import dev.anilbeesetti.nextplayer.core.ui.R as coreUiR
import kotlin.math.abs
import kotlin.math.min

internal const val ACTION_SHOW_FLOATING_WINDOW =
    "dev.anilbeesetti.nextplayer.SHOW_FLOATING_WINDOW"
internal const val ACTION_HIDE_FLOATING_WINDOW =
    "dev.anilbeesetti.nextplayer.HIDE_FLOATING_WINDOW"

/** Playback position the full screen player should resume at when leaving the floating window. */
internal const val EXTRA_FLOATING_RESUME_POSITION =
    "dev.anilbeesetti.nextplayer.FLOATING_RESUME_POSITION"

private const val CONTROLS_AUTO_HIDE_DELAY_MS = 3000L
private const val PROGRESS_UPDATE_INTERVAL_MS = 500L
private const val WINDOW_HORIZONTAL_MARGIN_DP = 10
private const val WINDOW_BOTTOM_MARGIN_DP = 5
private const val WINDOW_MIN_HEIGHT_DP = 72
private const val WINDOW_CORNER_RADIUS_DP = 12
private const val TOP_BUTTON_SIZE_DP = 36
private const val TOP_BUTTON_PADDING_DP = 11
private const val TOP_BUTTON_MARGIN_DP = 4
private const val CENTER_BUTTON_SIZE_DP = 64
private const val CENTER_BUTTON_PADDING_DP = 16
private const val PROGRESS_BAR_HEIGHT_DP = 3f
private const val PROGRESS_TOUCH_HEIGHT_DP = 18
private const val PROGRESS_HORIZONTAL_MARGIN_DP = 8
private const val PROGRESS_BOTTOM_MARGIN_DP = 4
private const val TRACK_COLOR = 0x66FFFFFF
private val SURFACE_ATTACH_RETRY_DELAYS_MS = longArrayOf(120, 360, 900)
private const val DEFAULT_ASPECT_RATIO = 16f / 9f

internal fun Context.requestShowFloatingWindow() {
    runCatching {
        startService(
            Intent(this, PlayerService::class.java).setAction(ACTION_SHOW_FLOATING_WINDOW),
        )
    }
}

internal fun Context.requestHideFloatingWindow() {
    runCatching {
        startService(
            Intent(this, PlayerService::class.java).setAction(ACTION_HIDE_FLOATING_WINDOW),
        )
    }
}

/**
 * A movable overlay window that renders the session player through a [SurfaceView].
 *
 * A surface view is used on purpose: it is composited straight by SurfaceFlinger, so the app does
 * no per frame work. The trade off is that a surface view lives in its own layer, which means the
 * rounded outline of the window can clip the letterbox area but never the video itself — a texture
 * view would give real rounded corners at the cost of an extra draw and more power per frame.
 *
 * The controls follow the usual miniature player layout: close in the top start corner, full screen
 * in the top end corner, play/pause in the middle and a seek bar that spans the bottom edge. The
 * window is sized from the video aspect ratio, its width is the screen width minus a small margin,
 * its height never exceeds half of the screen height, and it starts 5dp above the bottom edge.
 * Unlike picture in picture the window is owned by the playback service, so it outlives the player
 * activity and keeps the video on screen when the device screen is turned off.
 */
@OptIn(UnstableApi::class)
internal class FloatingPlayerWindow(
    private val context: Context,
    private val player: Player,
    private val onClose: () -> Unit,
    private val onOpenFullScreen: () -> Unit,
) {

    private val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val handler = Handler(Looper.getMainLooper())
    private val density = context.resources.displayMetrics.density
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop

    private var rootView: FrameLayout? = null
    private var videoView: SurfaceView? = null
    private var controlsView: View? = null
    private var playPauseButton: ImageButton? = null
    private var progressView: SeekProgressView? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    /** Current window offsets, in the [Gravity.BOTTOM] or [Gravity.CENTER_HORIZONTAL] frame. */
    private var windowX = 0
    private var windowY = 0

    private var dragStartRawX = 0f
    private var dragStartRawY = 0f
    private var dragStartX = 0
    private var dragStartY = 0
    private var isDragging = false

    private val attachSurfaceRunnable = Runnable { attachSurface() }
    private val hideControlsRunnable = Runnable { hideControls() }
    private val updateProgressRunnable = object : Runnable {
        override fun run() {
            updateProgress()
            handler.postDelayed(this, PROGRESS_UPDATE_INTERVAL_MS)
        }
    }

    var isShowing: Boolean = false
        private set

    private val playerListener = object : Player.Listener {
        override fun onVideoSizeChanged(videoSize: VideoSize) {
            resizeWindow(videoWidth = videoSize.width, videoHeight = videoSize.height)
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            updatePlayPauseIcon(isPlaying = isPlaying)
            updateProgress()
            // Controls stay put while paused, they only fade out during playback.
            handler.removeCallbacks(hideControlsRunnable)
            if (isPlaying) {
                handler.postDelayed(hideControlsRunnable, CONTROLS_AUTO_HIDE_DELAY_MS)
            } else {
                showControls()
            }
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_ENDED) hide() else updateProgress()
        }
    }

    fun show() {
        if (isShowing || rootView != null) return

        windowX = 0
        windowY = (WINDOW_BOTTOM_MARGIN_DP * density).toInt()
        val params = createLayoutParams(
            videoWidth = player.videoSize.width,
            videoHeight = player.videoSize.height,
        )
        val root = buildRootView(
            windowWidth = params.width,
            windowHeight = params.height,
        )
        if (runCatching { windowManager.addView(root, params) }.isFailure) return

        rootView = root
        layoutParams = params
        isShowing = true
        player.addListener(playerListener)
        updatePlayPauseIcon(isPlaying = player.isPlaying)
        updateProgress()
        attachSurface()
        // The player activity clears the surface while it is torn down, so re-attach a few times.
        for (delay in SURFACE_ATTACH_RETRY_DELAYS_MS) {
            handler.postDelayed(attachSurfaceRunnable, delay)
        }
        showControls()
        handler.postDelayed(hideControlsRunnable, CONTROLS_AUTO_HIDE_DELAY_MS)
        handler.postDelayed(updateProgressRunnable, PROGRESS_UPDATE_INTERVAL_MS)
    }

    fun hide() {
        if (!isShowing) return
        isShowing = false
        handler.removeCallbacksAndMessages(null)
        player.removeListener(playerListener)
        // The surface is left alone on purpose: whoever hides this window either already owns the
        // surface (the full screen player) or stops the whole session right after.
        rootView?.let { view -> runCatching { windowManager.removeView(view) } }
        rootView = null
        videoView = null
        controlsView = null
        playPauseButton = null
        progressView = null
        layoutParams = null
    }

    private fun attachSurface() {
        if (!isShowing) return
        val view = videoView ?: return
        if (!view.holder.surface.isValid) return
        runCatching { player.setVideoSurfaceView(view) }
    }

    private fun buildRootView(windowWidth: Int, windowHeight: Int): FrameLayout {
        val root = FrameLayout(context).apply {
            background = GradientDrawable().apply {
                setColor(Color.BLACK)
                cornerRadius = WINDOW_CORNER_RADIUS_DP * density
            }
            // Rounds the window itself: the letterbox bars get rounded corners, the video surface
            // keeps its own square corners because a surface view is drawn in a separate layer.
            clipToOutline = true
            isClickable = true
            setOnTouchListener { view, event -> handleTouch(view, event) }
        }

        val video = SurfaceView(context).apply {
            holder.addCallback(
                object : SurfaceHolder.Callback {
                    override fun surfaceCreated(holder: SurfaceHolder) = attachSurface()

                    override fun surfaceChanged(
                        holder: SurfaceHolder,
                        format: Int,
                        width: Int,
                        height: Int,
                    ) = attachSurface()

                    override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
                },
            )
        }
        val (videoWidth, videoHeight) = fitVideoInWindow(
            containerWidth = windowWidth,
            containerHeight = windowHeight,
        )
        root.addView(
            video,
            FrameLayout.LayoutParams(videoWidth, videoHeight, Gravity.CENTER),
        )

        val controls = buildControlsView()
        root.addView(
            controls,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        val progress = SeekProgressView().apply {
            setFraction(currentFraction())
        }
        root.addView(
            progress,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                (PROGRESS_TOUCH_HEIGHT_DP * density).toInt(),
                Gravity.BOTTOM,
            ).apply {
                val margin = (PROGRESS_HORIZONTAL_MARGIN_DP * density).toInt()
                marginStart = margin
                marginEnd = margin
                bottomMargin = (PROGRESS_BOTTOM_MARGIN_DP * density).toInt()
            },
        )

        videoView = video
        controlsView = controls
        progressView = progress
        return root
    }

    /** Drags the window around; a touch without movement toggles the controls as before. */
    private fun handleTouch(view: View, event: MotionEvent): Boolean {
        val params = layoutParams ?: return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                dragStartRawX = event.rawX
                dragStartRawY = event.rawY
                dragStartX = params.x
                dragStartY = params.y
                isDragging = false
                // Do not let the controls disappear while the window is being dragged.
                handler.removeCallbacks(hideControlsRunnable)
            }

            MotionEvent.ACTION_MOVE -> {
                val deltaX = event.rawX - dragStartRawX
                val deltaY = event.rawY - dragStartRawY
                if (!isDragging &&
                    (abs(deltaX) > touchSlop || abs(deltaY) > touchSlop)
                ) {
                    isDragging = true
                    hideControls()
                }
                if (isDragging) {
                    windowX = clampX(
                        value = (dragStartX + deltaX).toInt(),
                        windowWidth = params.width,
                    )
                    // Y grows upwards from the bottom edge, hence the inverted delta.
                    windowY = clampY(
                        value = (dragStartY - deltaY).toInt(),
                        windowHeight = params.height,
                    )
                    params.x = windowX
                    params.y = windowY
                    runCatching { windowManager.updateViewLayout(view, params) }
                }
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (isDragging) {
                    isDragging = false
                } else {
                    toggleControls()
                }
            }
        }
        return true
    }

    /**
     * Builds an empty full size container that only hosts the buttons, so the icons sit straight on
     * the video without a scrim behind them. The container itself is not clickable, which lets a
     * touch that misses a button fall through to the window and start a drag.
     */
    private fun buildControlsView(): FrameLayout {
        val container = FrameLayout(context)

        playPauseButton = createButton(
            iconRes = coreUiR.drawable.ic_pause,
            sizeDp = CENTER_BUTTON_SIZE_DP,
            paddingDp = CENTER_BUTTON_PADDING_DP,
            onClick = { togglePlayback() },
        )
        val fullScreenButton = createButton(
            iconRes = coreUiR.drawable.ic_fit_screen,
            sizeDp = TOP_BUTTON_SIZE_DP,
            paddingDp = TOP_BUTTON_PADDING_DP,
            onClick = { onOpenFullScreen() },
        )
        val closeButton = createButton(
            iconRes = coreUiR.drawable.ic_close,
            sizeDp = TOP_BUTTON_SIZE_DP,
            paddingDp = TOP_BUTTON_PADDING_DP,
            onClick = { onClose() },
        )

        val margin = (TOP_BUTTON_MARGIN_DP * density).toInt()
        container.addView(
            playPauseButton,
            FrameLayout.LayoutParams(
                (CENTER_BUTTON_SIZE_DP * density).toInt(),
                (CENTER_BUTTON_SIZE_DP * density).toInt(),
                Gravity.CENTER,
            ),
        )
        container.addView(
            closeButton,
            FrameLayout.LayoutParams(
                (TOP_BUTTON_SIZE_DP * density).toInt(),
                (TOP_BUTTON_SIZE_DP * density).toInt(),
                Gravity.TOP or Gravity.START,
            ).apply {
                marginStart = margin
                topMargin = margin
            },
        )
        container.addView(
            fullScreenButton,
            FrameLayout.LayoutParams(
                (TOP_BUTTON_SIZE_DP * density).toInt(),
                (TOP_BUTTON_SIZE_DP * density).toInt(),
                Gravity.TOP or Gravity.END,
            ).apply {
                marginEnd = margin
                topMargin = margin
            },
        )
        return container
    }

    private fun createButton(
        iconRes: Int,
        sizeDp: Int,
        paddingDp: Int,
        onClick: () -> Unit,
    ): ImageButton = ImageButton(context).apply {
        setImageResource(iconRes)
        imageTintList = ColorStateList.valueOf(Color.WHITE)
        background = null
        val size = (sizeDp * density).toInt()
        val padding = (paddingDp * density).toInt()
        layoutParams = FrameLayout.LayoutParams(size, size)
        setPadding(padding, padding, padding, padding)
        setOnClickListener { onClick() }
    }

    private fun togglePlayback() {
        // The player listener refreshes the icon and the controls visibility once the state settles.
        if (player.isPlaying) player.pause() else player.play()
        updateProgress()
    }

    private fun updatePlayPauseIcon(isPlaying: Boolean) {
        playPauseButton?.setImageResource(
            if (isPlaying) coreUiR.drawable.ic_pause else coreUiR.drawable.ic_play,
        )
    }

    private fun currentFraction(): Float {
        val duration = player.duration
        if (duration <= 0) return 0f
        return (player.currentPosition.toFloat() / duration).coerceIn(0f, 1f)
    }

    private fun updateProgress() {
        val progress = progressView ?: return
        // While the user is scrubbing the bar the thumb follows the finger, not the player.
        if (progress.isScrubbing) return
        progress.setFraction(currentFraction())
    }

    private fun toggleControls() {
        val controls = controlsView ?: return
        if (controls.visibility == View.VISIBLE) {
            hideControls()
        } else {
            showControls()
            handler.postDelayed(hideControlsRunnable, CONTROLS_AUTO_HIDE_DELAY_MS)
        }
    }

    private fun showControls() {
        controlsView?.visibility = View.VISIBLE
    }

    private fun hideControls() {
        controlsView?.visibility = View.GONE
    }

    private fun resizeWindow(videoWidth: Int, videoHeight: Int) {
        val root = rootView ?: return
        val video = videoView ?: return
        val params = createLayoutParams(videoWidth = videoWidth, videoHeight = videoHeight)
        val (width, height) = fitVideoInWindow(
            containerWidth = params.width,
            containerHeight = params.height,
        )
        video.layoutParams = FrameLayout.LayoutParams(width, height, Gravity.CENTER)
        layoutParams = params
        runCatching { windowManager.updateViewLayout(root, params) }
    }

    private fun createLayoutParams(
        videoWidth: Int,
        videoHeight: Int,
    ): WindowManager.LayoutParams {
        val screenWidth = screenSize().first
        val screenHeight = screenSize().second
        val width = (screenWidth - WINDOW_HORIZONTAL_MARGIN_DP * density).toInt().coerceAtLeast(1)
        val height = min(
            (width / aspectRatio(videoWidth = videoWidth, videoHeight = videoHeight)).toInt(),
            screenHeight / 2,
        ).coerceAtLeast((WINDOW_MIN_HEIGHT_DP * density).toInt())

        return WindowManager.LayoutParams(
            width,
            height,
            windowType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            x = clampX(value = windowX, windowWidth = width)
            y = clampY(value = windowY, windowHeight = height)
        }
    }

    private fun clampX(value: Int, windowWidth: Int): Int {
        val limit = ((screenSize().first - windowWidth) / 2).coerceAtLeast(0)
        return value.coerceIn(-limit, limit)
    }

    private fun clampY(value: Int, windowHeight: Int): Int {
        val limit = (screenSize().second - windowHeight).coerceAtLeast(0)
        return value.coerceIn(0, limit)
    }

    /** Fits the video inside the window without distorting it. */
    private fun fitVideoInWindow(containerWidth: Int, containerHeight: Int): Pair<Int, Int> {
        val width = containerWidth.coerceAtLeast(1)
        val height = containerHeight.coerceAtLeast(1)
        val aspect = aspectRatio()
        var fittedWidth = width
        var fittedHeight = (width / aspect).toInt()
        if (fittedHeight > height) {
            fittedHeight = height
            fittedWidth = (height * aspect).toInt()
        }
        return fittedWidth.coerceAtLeast(1) to fittedHeight.coerceAtLeast(1)
    }

    private fun aspectRatio(
        videoWidth: Int = player.videoSize.width,
        videoHeight: Int = player.videoSize.height,
    ): Float = if (videoWidth > 0 && videoHeight > 0) {
        videoWidth.toFloat() / videoHeight
    } else {
        DEFAULT_ASPECT_RATIO
    }

    private fun screenSize(): Pair<Int, Int> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.currentWindowMetrics.bounds
            return bounds.width() to bounds.height()
        }
        val metrics = context.resources.displayMetrics
        return metrics.widthPixels to metrics.heightPixels
    }

    private fun windowType(): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
    } else {
        @Suppress("DEPRECATION")
        WindowManager.LayoutParams.TYPE_PHONE
    }

    /**
     * The thin bar along the bottom edge. It is only a few dp tall but grabs a taller touch band, so
     * dragging the bar scrubs the video while the rest of the window keeps moving the window.
     */
    private inner class SeekProgressView : View(context) {

        private val barHeight = PROGRESS_BAR_HEIGHT_DP * density
        private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = TRACK_COLOR }
        private val progressPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }

        private var fraction = 0f

        /** True while a finger is on the bar, so the periodic refresh does not fight the drag. */
        var isScrubbing = false
            private set

        fun setFraction(value: Float) {
            val clamped = value.coerceIn(0f, 1f)
            if (abs(clamped - fraction) < 0.001f) return
            fraction = clamped
            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            val radius = barHeight / 2f
            val centerY = height / 2f
            canvas.drawRoundRect(
                0f,
                centerY - radius,
                width.toFloat(),
                centerY + radius,
                radius,
                radius,
                trackPaint,
            )
            val filled = width * fraction
            if (filled > 0f) {
                canvas.drawRoundRect(
                    0f,
                    centerY - radius,
                    filled.coerceAtLeast(barHeight),
                    centerY + radius,
                    radius,
                    radius,
                    progressPaint,
                )
            }
        }

        override fun onTouchEvent(event: MotionEvent): Boolean {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    parent?.requestDisallowInterceptTouchEvent(true)
                    isScrubbing = true
                    setFraction(fractionAt(x = event.x))
                }

                MotionEvent.ACTION_MOVE -> setFraction(fractionAt(x = event.x))

                MotionEvent.ACTION_UP -> {
                    val target = fractionAt(x = event.x)
                    setFraction(target)
                    isScrubbing = false
                    seekTo(target)
                }

                MotionEvent.ACTION_CANCEL -> isScrubbing = false
            }
            return true
        }

        private fun fractionAt(x: Float): Float =
            if (width <= 0) 0f else (x / width).coerceIn(0f, 1f)

        private fun seekTo(target: Float) {
            val duration = player.duration
            if (duration <= 0) return
            runCatching { player.seekTo((duration * target).toLong()) }
            updateProgress()
        }
    }
}
