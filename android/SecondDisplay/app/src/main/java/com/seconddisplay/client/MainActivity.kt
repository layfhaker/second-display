package com.seconddisplay.client

import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Bundle
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.appcompat.app.AppCompatActivity
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : AppCompatActivity() {

    private lateinit var root: FrameLayout
    private var videoView: AspectRatioSurfaceView? = null
    private var cursorView: CursorOverlayView? = null
    private var client: StreamClient? = null

    private var codec: MediaCodec? = null
    private val decoding = AtomicBoolean(false)
    private val frameQueue = ArrayBlockingQueue<VideoFrame>(2)
    private var decodeThread: Thread? = null

    private var serverWidth = 0
    private var serverHeight = 0
    private var requestedRefreshRate = 60f

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        requestedRefreshRate = requestBestDisplayMode()

        root = FrameLayout(this)
        root.setBackgroundColor(Color.BLACK)
        root.isFocusable = true
        root.isFocusableInTouchMode = true
        setContentView(root)
        root.requestFocus()

        startClient()
    }

    override fun onResume() {
        super.onResume()
        KeyForwarder.setActivityActive(true)
    }

    override fun onPause() {
        KeyForwarder.setActivityActive(false)
        super.onPause()
    }

    private fun startClient() {
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        windowManager.defaultDisplay.getRealMetrics(metrics)
        val refreshRate = requestedRefreshRate.toInt().coerceAtLeast(60)

        client = StreamClient(
            onReady = { ready ->
                serverWidth = ready.width
                serverHeight = ready.height
                runOnUiThread { setupVideoView(ready.width, ready.height) }
            },
            onFrame = { frame ->
                if (frame.keyframe) frameQueue.clear()
                if (!frameQueue.offer(frame)) {
                    frameQueue.poll()
                    frameQueue.offer(frame)
                }
            },
            onCursor = { cursor ->
                runOnUiThread { cursorView?.updateCursor(cursor) }
            },
            onDisconnect = {
                runOnUiThread { teardownCodec() }
                Thread.sleep(2000)
                runOnUiThread { startClient() }
            }
        )
        KeyForwarder.attach(client!!)
        client?.start(metrics.widthPixels, metrics.heightPixels, metrics.densityDpi, refreshRate)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (forwardKeyEvent(event)) return true
        return super.dispatchKeyEvent(event)
    }

    override fun onKeyShortcut(keyCode: Int, event: KeyEvent): Boolean {
        if (!isForwardedKey(keyCode)) return super.onKeyShortcut(keyCode, event)

        val metaState = event.metaState
        forwardSyntheticKey(KeyEvent.ACTION_DOWN, keyCode, metaState, event.scanCode)
        forwardSyntheticKey(KeyEvent.ACTION_UP, keyCode, metaState, event.scanCode)
        return true
    }

    override fun onBackPressed() {
        forwardSyntheticKey(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ESCAPE, 0)
        forwardSyntheticKey(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ESCAPE, 0)
    }

    private fun forwardKeyEvent(event: KeyEvent): Boolean {
        if (!isForwardedKey(event.keyCode)) return false

        val action = when (event.action) {
            KeyEvent.ACTION_DOWN,
            KeyEvent.ACTION_UP -> event.action
            else -> return true
        }
        forwardSyntheticKey(action, event.keyCode, event.metaState, event.scanCode)
        return true
    }

    private fun forwardSyntheticKey(action: Int, keyCode: Int, metaState: Int, scanCode: Int = 0) {
        val forwardedKeyCode = if (keyCode == KeyEvent.KEYCODE_APP_SWITCH) KeyEvent.KEYCODE_TAB else keyCode
        val forwardedMetaState = if (keyCode == KeyEvent.KEYCODE_APP_SWITCH) {
            metaState or KeyEvent.META_ALT_ON
        } else {
            metaState
        }
        val wireAction: Byte = when (action) {
            KeyEvent.ACTION_DOWN -> 0
            KeyEvent.ACTION_UP -> 1
            else -> return
        }
        client?.sendKey(wireAction, forwardedKeyCode, forwardedMetaState, scanCode)
    }

    private fun isForwardedKey(keyCode: Int): Boolean = KeyForwarder.isForwardedKey(keyCode)

    private fun setupVideoView(w: Int, h: Int) {
        teardownCodec()
        frameQueue.clear()

        val view = AspectRatioSurfaceView(this)
        val cursor = CursorOverlayView(this)
        view.setAspectRatio(w, h)
        cursor.setAspectRatio(w, h)
        val lp = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
            Gravity.CENTER
        )
        root.removeAllViews()
        root.addView(view, lp)
        root.addView(cursor, lp)
        cursor.bringToFront()
        videoView = view
        cursorView = cursor

        view.setOnTouchListener { v, event ->
            if (v.width == 0 || v.height == 0) return@setOnTouchListener true
            val action: Byte = when (event.actionMasked) {
                MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> 0
                MotionEvent.ACTION_MOVE -> 1
                MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> 2
                else -> return@setOnTouchListener true
            }
            val x = (event.x / v.width).coerceIn(0f, 1f)
            val y = (event.y / v.height).coerceIn(0f, 1f)
            client?.sendTouch(action, 0, x, y)
            true
        }

        view.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                startCodec(holder)
            }
            override fun surfaceChanged(holder: SurfaceHolder, f: Int, w2: Int, h2: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                teardownCodec()
            }
        })
    }

    private fun startCodec(holder: SurfaceHolder) {
        if (decoding.get()) return
        try {
            if (android.os.Build.VERSION.SDK_INT >= 30)
                holder.surface.setFrameRate(requestedRefreshRate, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
            val mime = MediaFormat.MIMETYPE_VIDEO_HEVC
            val format = MediaFormat.createVideoFormat(mime, serverWidth, serverHeight)
            // Low-latency: stop the decoder from buffering several frames before display.
            if (android.os.Build.VERSION.SDK_INT >= 30)
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            // Qualcomm vendor low-latency hint (c2.qti.hevc.decoder on this tablet).
            try { format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1) } catch (_: Exception) {}
            // Hint the codec to run flat-out at realtime priority.
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, 480)
            val mc = MediaCodec.createDecoderByType(mime)
            mc.configure(format, holder.surface, null, 0)
            mc.start()
            codec = mc
            decoding.set(true)
            decodeThread = Thread { decodeLoop(mc) }.apply { start() }
            Log.i(TAG, "MediaCodec HEVC started ${serverWidth}x$serverHeight")
        } catch (e: Exception) {
            Log.e(TAG, "Codec start failed", e)
        }
    }

    private fun requestBestDisplayMode(): Float {
        @Suppress("DEPRECATION")
        val display = windowManager.defaultDisplay
        val modes = display.supportedModes
        val best = modes
            .filter { it.physicalWidth > 0 && it.physicalHeight > 0 }
            .maxByOrNull { it.refreshRate }
        val refresh = best?.refreshRate ?: display.refreshRate

        val attrs = window.attributes
        if (best != null) {
            attrs.preferredDisplayModeId = best.modeId
            attrs.preferredRefreshRate = best.refreshRate
        } else {
            attrs.preferredRefreshRate = refresh
        }
        window.attributes = attrs

        Log.i(TAG, "Requested display mode: ${best?.modeId ?: -1} @ ${refresh}Hz")
        return refresh
    }

    private fun decodeLoop(mc: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (decoding.get()) {
                val frame = frameQueue.poll(50, TimeUnit.MILLISECONDS)
                if (frame == null) {
                    drainOutputs(mc, info)
                    continue
                }
                // Wait for a free input buffer so we never drop an access unit (params live here).
                var inIdx = -1
                while (decoding.get()) {
                    inIdx = mc.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) break
                    drainOutputs(mc, info)
                }
                if (inIdx < 0) break

                val buf = mc.getInputBuffer(inIdx)!!
                buf.clear()
                buf.put(frame.data)
                mc.queueInputBuffer(inIdx, 0, frame.data.size, frame.ptsMicros, 0)

                drainOutputs(mc, info)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Decode loop error", e)
        }
    }

    private fun drainOutputs(mc: MediaCodec, info: MediaCodec.BufferInfo) {
        var outIdx = mc.dequeueOutputBuffer(info, 0)
        while (outIdx >= 0) {
            mc.releaseOutputBuffer(outIdx, true) // render to surface
            outIdx = mc.dequeueOutputBuffer(info, 0)
        }
    }

    private fun teardownCodec() {
        decoding.set(false)
        decodeThread?.join(300)
        decodeThread = null
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
    }

    override fun onDestroy() {
        decoding.set(false)
        KeyForwarder.setActivityActive(false)
        KeyForwarder.detach(client)
        client?.stop()
        teardownCodec()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "SecondDisplay"
    }
}
