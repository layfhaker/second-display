package com.seconddisplay.client

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View

class CursorOverlayView(context: Context) : View(context) {
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private var aspectW = 0
    private var aspectH = 0
    private var cursorBitmap: Bitmap? = null
    private var cursorVisible = false
    private var cursorX = 0
    private var cursorY = 0
    private var cursorW = 0
    private var cursorH = 0

    init {
        isClickable = false
        isFocusable = false
        elevation = 1000f
        translationZ = 1000f
    }

    fun setAspectRatio(w: Int, h: Int) {
        aspectW = w
        aspectH = h
        requestLayout()
    }

    fun updateCursor(packet: CursorPacket) {
        cursorVisible = packet.visible
        cursorX = packet.x
        cursorY = packet.y
        cursorW = packet.width
        cursorH = packet.height
        if (packet.bgra.isNotEmpty() && packet.width > 0 && packet.height > 0) {
            cursorBitmap?.recycle()
            cursorBitmap = bgraToBitmap(packet.bgra, packet.width, packet.height)
        }
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val availW = MeasureSpec.getSize(widthMeasureSpec)
        val availH = MeasureSpec.getSize(heightMeasureSpec)
        if (aspectW <= 0 || aspectH <= 0 || availW == 0 || availH == 0) {
            setMeasuredDimension(availW, availH)
            return
        }
        val scale = minOf(availW.toFloat() / aspectW, availH.toFloat() / aspectH)
        setMeasuredDimension((aspectW * scale).toInt(), (aspectH * scale).toInt())
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val bitmap = cursorBitmap ?: return
        if (!cursorVisible || aspectW <= 0 || aspectH <= 0 || cursorW <= 0 || cursorH <= 0) return

        val scaleX = width.toFloat() / aspectW
        val scaleY = height.toFloat() / aspectH
        val left = cursorX * scaleX
        val top = cursorY * scaleY
        val right = left + cursorW * scaleX
        val bottom = top + cursorH * scaleY
        canvas.drawBitmap(bitmap, null, android.graphics.RectF(left, top, right, bottom), paint)
    }

    override fun onDetachedFromWindow() {
        cursorBitmap?.recycle()
        cursorBitmap = null
        super.onDetachedFromWindow()
    }

    private fun bgraToBitmap(bgra: ByteArray, w: Int, h: Int): Bitmap {
        val pixels = IntArray(w * h)
        var si = 0
        for (i in pixels.indices) {
            val b = bgra[si].toInt() and 0xff
            val g = bgra[si + 1].toInt() and 0xff
            val r = bgra[si + 2].toInt() and 0xff
            val a = bgra[si + 3].toInt() and 0xff
            pixels[i] = (a shl 24) or (r shl 16) or (g shl 8) or b
            si += 4
        }
        return Bitmap.createBitmap(pixels, w, h, Bitmap.Config.ARGB_8888)
    }
}
