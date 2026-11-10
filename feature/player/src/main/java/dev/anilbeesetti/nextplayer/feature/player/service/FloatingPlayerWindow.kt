package dev.anilbeesetti.nextplayer.feature.player.service

import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import dev.anilbeesetti.nextplayer.core.ui.R as coreUiR
import kotlin.math.min

internal const val ACTION_SHOW_FLOATING_WINDOW =
    "dev.anilbeesetti.nextplayer.SHOW_FLOATING_WINDOW"
internal const val ACTION_HIDE_FLOATING_WINDOW =
    "dev.anilbeesetti.nextplayer.HIDE_FLOATING_WINDOW"

/** Playback position the full screen player should resume at when leaving the floating window. */
internal const val EXTRA_FLOATING_RESUME_POSITION =
    "dev.anilbeesetti.nextplayer.FLOATING_RESUME_POSITION"

private const val CONTROLS_AUTO_HIDE_DELAY_MS = 3000L
private const val WINDOW_HORIZONTAL_MARGIN_DP = 10
private const val WINDOW_MIN_HEIGHT_DP = 72
private const val WINDOW_CORNER_RADIUS_DP = 12
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
 * A bottom docked overlay window that renders the session player through a [SurfaceView].
 *
 * The window is sized from the video aspect ratio: its width is the screen width minus a small
 * margin, its height never exceeds half of the screen height. Unlike picture in picture, the
 * window is owned by the playback service, so it outlives the player activity and keeps the video
 * on screen when the device is turned off and on again.
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

    private var rootView: FrameLayout? = null
    private var videoView: SurfaceView? = null
    private var controlsView: View? = null
    private var playPauseButton: ImageButton? = null

    private val attachSurfaceRunnable = Runnable { attachSurface() }
    private val hideControlsRunnable = Runnable { hideControls() }

    var isShowing: Boolean = false
        private set

    private val playerListener = object : Player.Listener {
        override fun onVideoSizeChanged(videoSize: VideoSize) {
            resizeWindow(videoWidth = videoSize.width, videoHeight = videoSize.height)
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            updatePlayPauseIcon(isPlaying = isPlaying)
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_ENDED) hide()
        }
    }

    fun show() {
        if (isShowing || rootView != null) return

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
        isShowing = true
        player.addListener(playerListener)
        updatePlayPauseIcon(isPlaying = player.isPlaying)
        attachSurface()
        // The player activity clears the surface while it is torn down, so re-attach a few times.
        for (delay in SURFACE_ATTACH_RETRY_DELAYS_MS) {
            handler.postDelayed(attachSurfaceRunnable, delay)
        }
        showControls()
        handler.postDelayed(hideControlsRunnable, CONTROLS_AUTO_HIDE_DELAY_MS)
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
            clipToOutline = true
            isClickable = true
            setOnClickListener { toggleControls() }
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
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
            ).apply { bottomMargin = (8 * density).toInt() },
        )

        videoView = video
        controlsView = controls
        return root
    }

    private fun buildControlsView(): LinearLayout {
        val padding = (4 * density).toInt()
        val bar = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#99000000"))
                cornerRadius = 20 * density
            }
            setPadding(padding, padding, padding, padding)
        }

        playPauseButton = createButton(
            iconRes = coreUiR.drawable.ic_pause,
            onClick = { togglePlayback() },
        )
        val fullScreenButton = createButton(
            iconRes = coreUiR.drawable.ic_fit_screen,
            onClick = { onOpenFullScreen() },
        )
        val closeButton = createButton(
            iconRes = coreUiR.drawable.ic_close,
            onClick = { onClose() },
        )

        bar.addView(playPauseButton)
        bar.addView(fullScreenButton)
        bar.addView(closeButton)
        return bar
    }

    private fun createButton(iconRes: Int, onClick: () -> Unit): ImageButton =
        ImageButton(context).apply {
            setImageResource(iconRes)
            imageTintList = ColorStateList.valueOf(Color.WHITE)
            background = null
            val buttonSize = (36 * density).toInt()
            layoutParams = LinearLayout.LayoutParams(buttonSize, buttonSize)
            val padding = (8 * density).toInt()
            setPadding(padding, padding, padding, padding)
            setOnClickListener { onClick() }
        }

    private fun togglePlayback() {
        if (player.isPlaying) player.pause() else player.play()
        showControls()
        handler.removeCallbacks(hideControlsRunnable)
        handler.postDelayed(hideControlsRunnable, CONTROLS_AUTO_HIDE_DELAY_MS)
    }

    private fun updatePlayPauseIcon(isPlaying: Boolean) {
        playPauseButton?.setImageResource(
            if (isPlaying) coreUiR.drawable.ic_pause else coreUiR.drawable.ic_play,
        )
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
        }
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
}
