package dev.anilbeesetti.nextplayer.feature.player.service

import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Typeface
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
import android.view.accessibility.CaptioningManager
import android.widget.FrameLayout
import android.widget.ImageButton
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.SubtitleView
import dev.anilbeesetti.nextplayer.core.model.PlayerPreferences
import dev.anilbeesetti.nextplayer.feature.player.extensions.toTypeface
import dev.anilbeesetti.nextplayer.core.ui.R as coreUiR
import kotlin.math.abs

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
/** The border is drawn in pixels on purpose: one hairline, the same width on every screen. */
private const val WINDOW_BORDER_WIDTH_PX = 1
private val WINDOW_BORDER_COLOR = 0xFF9E9E9E.toInt()
private const val TOP_BUTTON_SIZE_DP = 36
private const val TOP_BUTTON_PADDING_DP = 11
private const val TOP_BUTTON_MARGIN_DP = 4
private const val CENTER_BUTTON_SIZE_DP = 128
private const val CENTER_BUTTON_PADDING_DP = 32
private const val PROGRESS_BAR_HEIGHT_DP = 3f
private const val PROGRESS_TOUCH_HEIGHT_DP = 18
private const val PROGRESS_HORIZONTAL_MARGIN_DP = 8
private const val PROGRESS_BOTTOM_MARGIN_DP = 4
private const val TRACK_COLOR = 0x66FFFFFF
private val SURFACE_ATTACH_RETRY_DELAYS_MS = longArrayOf(120, 360, 900)
private const val DEFAULT_ASPECT_RATIO = 16f / 9f
/** A video wider than this gets the crop button and is shown cropped to this ratio by default. */
private const val CROP_TARGET_ASPECT_RATIO = 16f / 9f
/** How small and how large the subtitles may get relative to the window height. */
private const val MIN_TEXT_SIZE_FRACTION = 0.03f
private const val MAX_TEXT_SIZE_FRACTION = 0.12f

/** Where the last window position is kept, so the next window opens in the same place. */
private const val POSITION_PREFERENCES = "floating_player_window"
private const val KEY_WINDOW_X = "window_x"
private const val KEY_WINDOW_Y = "window_y"

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
 * A surface view is composited straight by SurfaceFlinger, so the app does no per frame work. It is
 * its own layer, so it cannot be clipped: the window is a plain rectangle and the border is painted
 * by a view on top of the video instead of a window outline.
 *
 * The controls follow the usual miniature player layout: full screen in the top start corner, close
 * in the top end corner, a large play/pause in the middle and a seek bar along the bottom edge. The
 * bar and the buttons are one set: they appear and disappear together. Subtitles are drawn by a
 * subtitle view over the video, fed by the cues of the session player, so whatever track was picked
 * in the full screen player keeps showing here without being selected twice.
 *
 * A video wider than 16:9 is cropped to 16:9 by default and gets an extra button in the top start
 * corner to switch back to its own ratio. The window is rebuilt for whichever ratio is on show, so
 * the picture always fills it edge to edge. The rest of the sizing is picked by the orientation of
 * the video: a landscape or square video is as wide as the screen minus a small margin, a portrait
 * video is half of the screen tall, and the other dimension always follows the aspect ratio, so the
 * border sits on the edge of the video.
 *
 *
 * The window starts where it was left last time: the last position is stored when a drag finishes,
 * so the next window opens in the same place. A landscape video is as wide as the screen allows, so
 * while it is dragged it stays horizontally centered (5dp on each side) and only moves vertically.
 * While playing the window keeps the screen on, and unlike picture in picture it is owned by the
 * playback service, so it outlives the player activity and keeps the video on screen when the
 * device screen is turned off.
 */
@OptIn(UnstableApi::class)
internal class FloatingPlayerWindow(
    private val context: Context,
    private val player: Player,
    private val preferences: PlayerPreferences,
    private val onClose: () -> Unit,
    private val onOpenFullScreen: () -> Unit,
) {

    private val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val handler = Handler(Looper.getMainLooper())
    private val density = context.resources.displayMetrics.density
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val positionPreferences =
        context.getSharedPreferences(POSITION_PREFERENCES, Context.MODE_PRIVATE)

    private var rootView: FrameLayout? = null
    private var videoView: SurfaceView? = null
    private var subtitleView: SubtitleView? = null
    private var controlsView: View? = null
    private var playPauseButton: ImageButton? = null
    private var progressView: SeekProgressView? = null
    private var cropButton: ImageButton? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    /** False when the video plays at its own ratio, true when it is cropped to 16:9. */
    private var isCropped: Boolean = false

    /** The ratio the default crop state was picked for, so a new video starts from the default. */
    private var videoAspectForCrop: Float = DEFAULT_ASPECT_RATIO

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
            val aspect = aspectRatio(
                videoWidth = videoSize.width,
                videoHeight = videoSize.height,
            )
            // A different video starts out in the default state: cropped when it is wider than
            // 16:9. While the same video keeps playing, whatever the user picked stays.
            if (abs(aspect - videoAspectForCrop) > 0.001f) {
                videoAspectForCrop = aspect
                isCropped = supportsCrop(aspect = aspect)
            }
            updateCropButton()
            applyVideoScalingMode()
            resizeWindow(videoWidth = videoSize.width, videoHeight = videoSize.height)
        }

        override fun onCues(cueGroup: CueGroup) {
            subtitleView?.setCues(cueGroup.cues)
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            updatePlayPauseIcon(isPlaying = isPlaying)
            updateProgress()
            // The screen is only held awake while something is actually playing.
            applyKeepScreenOn(keepScreenOn = isPlaying)
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

        restoreWindowPosition()
        val videoAspect = aspectRatio()
        videoAspectForCrop = videoAspect
        // A video wider than 16:9 opens cropped, everything else plays at its own ratio.
        isCropped = supportsCrop(aspect = videoAspect)
        val params = createLayoutParams(
            videoWidth = player.videoSize.width,
            videoHeight = player.videoSize.height,
        )
        val root = buildRootView()
        if (runCatching { windowManager.addView(root, params) }.isFailure) return

        rootView = root
        layoutParams = params
        isShowing = true
        player.addListener(playerListener)
        updatePlayPauseIcon(isPlaying = player.isPlaying)
        updateCropButton()
        updateProgress()
        applyKeepScreenOn(keepScreenOn = player.isPlaying)
        applyVideoScalingMode()
        // Subtitles are already selected in the full screen player, they just need to be drawn here.
        subtitleView?.setCues(player.currentCues?.cues.orEmpty())
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
        persistWindowPosition()
        handler.removeCallbacksAndMessages(null)
        player.removeListener(playerListener)
        // The full screen player can be narrower than the crop, so the video goes back uncropped.
        setVideoScalingMode(cropped = false)
        // The surface is left alone on purpose: whoever hides this window either already owns the
        // surface (the full screen player) or stops the whole session right after.
        rootView?.let { view -> runCatching { windowManager.removeView(view) } }
        rootView = null
        videoView = null
        subtitleView = null
        controlsView = null
        playPauseButton = null
        progressView = null
        cropButton = null
        layoutParams = null
    }

    private fun attachSurface() {
        if (!isShowing) return
        val view = videoView ?: return
        if (!view.holder.surface.isValid) return
        runCatching { player.setVideoSurfaceView(view) }
    }

    private fun buildRootView(): FrameLayout {
        val root = FrameLayout(context).apply {
            setBackgroundColor(Color.BLACK)
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
        // The window carries the aspect ratio of the video, so the surface fills it edge to edge.
        root.addView(
            video,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        // Subtitles sit right above the video and are driven by the same cues the player emits, so
        // whatever track is selected in the full screen player shows up here unchanged. The view
        // stops above the seek bar, which keeps the text from landing on top of it.
        val subtitles = SubtitleView(context).apply {
            setStyle(createCaptionStyle())
            setApplyEmbeddedStyles(preferences.applyEmbeddedStyles)
            // The window is much smaller than the screen, so the text is sized as a fraction of the
            // window instead of the absolute size that was picked for the full screen player.
            setFractionalTextSize(subtitleTextSizeFraction())
            // The subtitles sit over the whole video, so the touches have to reach the window and
            // keep dragging it instead of being eaten by this layer.
            isClickable = false
            isFocusable = false
        }
        root.addView(
            subtitles,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ).apply {
                bottomMargin = ((PROGRESS_BOTTOM_MARGIN_DP + PROGRESS_TOUCH_HEIGHT_DP) * density)
                    .toInt()
            },
        )

        val controls = buildControlsView()
        root.addView(
            controls,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        // A surface view is its own layer, so it would cover any border painted by the window
        // background. Drawing the frame as a view on top keeps it visible on the window edge.
        val border = buildBorderView()
        root.addView(
            border,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        videoView = video
        subtitleView = subtitles
        controlsView = controls
        return root
    }

    /**
     * Mirrors the caption style of the full screen player, so the subtitles look the same in both.
     * The window keeps the fractional sizing of the subtitle view, which rescales the text to the
     * window instead of using the absolute size picked for the full screen player.
     */
    private fun createCaptionStyle(): CaptionStyleCompat {
        val captioningManager = context.getSystemService(CaptioningManager::class.java)
        if (preferences.useSystemCaptionStyle && captioningManager != null) {
            return CaptionStyleCompat.createFromCaptionStyle(captioningManager.userStyle)
        }
        return CaptionStyleCompat(
            Color.WHITE,
            Color.BLACK.takeIf { preferences.subtitleBackground } ?: Color.TRANSPARENT,
            Color.TRANSPARENT,
            CaptionStyleCompat.EDGE_TYPE_DROP_SHADOW,
            Color.BLACK,
            Typeface.create(
                preferences.subtitleFont.toTypeface(),
                Typeface.BOLD.takeIf { preferences.subtitleTextBold } ?: Typeface.NORMAL,
            ),
        )
    }

    /**
     * The subtitle view sizes its text as a fraction of its own height, so the text shrinks with
     * the window instead of keeping the absolute size that was picked for the full screen player.
     * The user setting is applied as a multiplier over the default fraction, which keeps a larger
     * setting visibly larger here too.
     */
    private fun subtitleTextSizeFraction(): Float {
        val relativeSize = preferences.subtitleTextSize.toFloat() /
            PlayerPreferences.DEFAULT_SUBTITLE_TEXT_SIZE
        return (SubtitleView.DEFAULT_TEXT_SIZE_FRACTION * relativeSize)
            .coerceIn(MIN_TEXT_SIZE_FRACTION, MAX_TEXT_SIZE_FRACTION)
    }

    private fun buildBorderView(): View = View(context).apply {
        background = GradientDrawable().apply {
            setColor(Color.TRANSPARENT)
            setStroke(WINDOW_BORDER_WIDTH_PX, WINDOW_BORDER_COLOR)
        }
        isClickable = false
        isFocusable = false
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
                    // A landscape video already spans the screen width, so it snaps back to the
                    // horizontal center (5dp on each side) and the drag becomes a vertical move.
                    windowX = if (isLandscapeWindow()) {
                        0
                    } else {
                        clampX(
                            value = (dragStartX + deltaX).toInt(),
                            windowWidth = params.width,
                        )
                    }
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
                    persistWindowPosition()
                } else {
                    toggleControls()
                }
            }
        }
        return true
    }

    /**
     * Builds an empty full size container that hosts the buttons and the seek bar, so the icons sit
     * straight on the video without a scrim behind them. Everything lives in the same container on
     * purpose: the bar and the buttons appear and disappear as one set. The container itself is not
     * clickable, which lets a touch that misses a control fall through to the window and start a
     * drag.
     */
    private fun buildControlsView(): FrameLayout {
        val container = FrameLayout(context)

        val progress = SeekProgressView().apply {
            setFraction(currentFraction())
        }
        container.addView(
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
        cropButton = createButton(
            iconRes = coreUiR.drawable.ic_crop_landscape,
            sizeDp = TOP_BUTTON_SIZE_DP,
            paddingDp = TOP_BUTTON_PADDING_DP,
            onClick = { toggleCrop() },
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
            fullScreenButton,
            FrameLayout.LayoutParams(
                (TOP_BUTTON_SIZE_DP * density).toInt(),
                (TOP_BUTTON_SIZE_DP * density).toInt(),
                Gravity.TOP or Gravity.START,
            ).apply {
                marginStart = margin
                topMargin = margin
            },
        )
        // Sits right next to the full screen button, still in the top start corner. It is hidden
        // unless the video is wider than 16:9, which is the only case where cropping applies.
        container.addView(
            cropButton,
            FrameLayout.LayoutParams(
                (TOP_BUTTON_SIZE_DP * density).toInt(),
                (TOP_BUTTON_SIZE_DP * density).toInt(),
                Gravity.TOP or Gravity.START,
            ).apply {
                marginStart = margin + (TOP_BUTTON_SIZE_DP * density).toInt()
                topMargin = margin
            },
        )
        container.addView(
            closeButton,
            FrameLayout.LayoutParams(
                (TOP_BUTTON_SIZE_DP * density).toInt(),
                (TOP_BUTTON_SIZE_DP * density).toInt(),
                Gravity.TOP or Gravity.END,
            ).apply {
                marginEnd = margin
                topMargin = margin
            },
        )
        progressView = progress
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

    /**
     * Switches between the original ratio of the video and 16:9. The window is rebuilt for the new
     * ratio at the same time: with cropping on, the video is cut at the sides and the window takes
     * the 16:9 shape it now shows, so the picture still fills the window edge to edge.
     */
    private fun toggleCrop() {
        if (!supportsCrop(aspect = aspectRatio())) return
        isCropped = !isCropped
        applyVideoScalingMode()
        updateCropButton()
        resizeWindow(
            videoWidth = player.videoSize.width,
            videoHeight = player.videoSize.height,
        )
        showControls()
        handler.removeCallbacks(hideControlsRunnable)
        handler.postDelayed(hideControlsRunnable, CONTROLS_AUTO_HIDE_DELAY_MS)
    }

    /**
     * Cropping is done by the video renderer, not by the window: with the scaling mode set to crop,
     * the video is scaled until it fills the surface and the parts that do not fit are cut off on
     * both sides, which turns a wider than 16:9 video into a 16:9 picture.
     */
    private fun applyVideoScalingMode() {
        setVideoScalingMode(cropped = isCropped && supportsCrop(aspect = aspectRatio()))
    }

    private fun setVideoScalingMode(cropped: Boolean) {
        val exoPlayer = player as? ExoPlayer ?: return
        val mode = if (cropped) {
            C.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING
        } else {
            C.VIDEO_SCALING_MODE_SCALE_TO_FIT
        }
        runCatching { exoPlayer.setVideoScalingMode(mode) }
    }

    /** The crop button only makes sense for a video that is wider than the 16:9 target. */
    private fun supportsCrop(aspect: Float): Boolean =
        aspect > CROP_TARGET_ASPECT_RATIO + 0.01f

    private fun updateCropButton() {
        cropButton?.visibility =
            if (supportsCrop(aspect = aspectRatio())) View.VISIBLE else View.GONE
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
        val params = createLayoutParams(videoWidth = videoWidth, videoHeight = videoHeight)
        // The video fills the window, which already carries the new aspect ratio.
        layoutParams = params
        runCatching { windowManager.updateViewLayout(root, params) }
    }

    /**
     * The ratio the window is built for: the original ratio of the video, or 16:9 while a video
     * wider than that is being shown cropped.
     */
    private fun layoutAspectRatio(
        videoWidth: Int = player.videoSize.width,
        videoHeight: Int = player.videoSize.height,
    ): Float {
        val aspect = aspectRatio(videoWidth = videoWidth, videoHeight = videoHeight)
        return if (isCropped && supportsCrop(aspect = aspect)) {
            CROP_TARGET_ASPECT_RATIO
        } else {
            aspect
        }
    }

    private fun createLayoutParams(
        videoWidth: Int,
        videoHeight: Int,
    ): WindowManager.LayoutParams {
        val screenWidth = screenSize().first
        val screenHeight = screenSize().second
        // A video wider than 16:9 shrinks to the 16:9 target while it is shown cropped.
        val aspect = layoutAspectRatio(videoWidth = videoWidth, videoHeight = videoHeight)
        // The widest window the screen allows, and the tallest a window is allowed to get.
        val maxWidth = (screenWidth - WINDOW_HORIZONTAL_MARGIN_DP * density)
            .toInt()
            .coerceAtLeast(1)
        val halfHeight = (screenHeight / 2).coerceAtLeast(1)
        val minHeight = (WINDOW_MIN_HEIGHT_DP * density).toInt()

        // A landscape or square video always takes the full available width, a portrait video
        // always takes half of the screen height; the other dimension follows the aspect ratio, so
        // the video fills the window edge to edge without being stretched.
        var width: Int
        var height: Int
        if (aspect >= 1f) {
            width = maxWidth
            height = (width / aspect).toInt()
        } else {
            height = halfHeight
            width = (height * aspect).toInt()
        }
        // Keep the window usable and inside the screen; both dimensions are recomputed together so
        // the window never drifts away from the aspect ratio of the video.
        if (height < minHeight) {
            height = minHeight
            width = (height * aspect).toInt()
        }
        if (height > screenHeight) {
            height = screenHeight
            width = (height * aspect).toInt()
        }
        if (width > maxWidth) {
            width = maxWidth
            height = (width / aspect).toInt()
        }
        width = width.coerceAtLeast(1)
        height = height.coerceAtLeast(1)

        return WindowManager.LayoutParams(
            width,
            height,
            windowType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            x = if (isLandscapeWindow()) 0 else clampX(value = windowX, windowWidth = width)
            y = clampY(value = windowY, windowHeight = height)
            if (player.isPlaying) flags = flags or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        }
    }

    /** Adds or removes the keep screen on flag without rebuilding the window. */
    private fun applyKeepScreenOn(keepScreenOn: Boolean) {
        val params = layoutParams ?: return
        val root = rootView ?: return
        val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        val flags = if (keepScreenOn) params.flags or flag else params.flags and flag.inv()
        if (flags == params.flags) return
        params.flags = flags
        runCatching { windowManager.updateViewLayout(root, params) }
    }

    private fun restoreWindowPosition() {
        windowX = positionPreferences.getInt(KEY_WINDOW_X, 0)
        windowY = positionPreferences.getInt(
            KEY_WINDOW_Y,
            (WINDOW_BOTTOM_MARGIN_DP * density).toInt(),
        )
    }

    private fun persistWindowPosition() {
        positionPreferences.edit()
            .putInt(KEY_WINDOW_X, windowX)
            .putInt(KEY_WINDOW_Y, windowY)
            .apply()
    }

    private fun clampX(value: Int, windowWidth: Int): Int {
        val limit = ((screenSize().first - windowWidth) / 2).coerceAtLeast(0)
        return value.coerceIn(-limit, limit)
    }

    private fun clampY(value: Int, windowHeight: Int): Int {
        val limit = (screenSize().second - windowHeight).coerceAtLeast(0)
        return value.coerceIn(0, limit)
    }

    private fun aspectRatio(
        videoWidth: Int = player.videoSize.width,
        videoHeight: Int = player.videoSize.height,
    ): Float = if (videoWidth > 0 && videoHeight > 0) {
        videoWidth.toFloat() / videoHeight
    } else {
        DEFAULT_ASPECT_RATIO
    }

    /**
     * A landscape (or square) window already spans the available width, so it cannot slide
     * sideways. This follows the window ratio, not the video ratio: a wide video shown uncropped is
     * full width too, while the same video cropped to 16:9 is a little shorter.
     */
    private fun isLandscapeWindow(): Boolean = layoutAspectRatio() >= 1f

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
     * dragging the bar scrubs the video while the rest of the window keeps moving the window. It is
     * part of the controls container, so it fades out together with the buttons.
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
