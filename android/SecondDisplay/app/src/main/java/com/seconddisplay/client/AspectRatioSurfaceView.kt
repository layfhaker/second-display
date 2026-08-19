package com.seconddisplay.client

import android.content.Context
import android.view.SurfaceView

/** SurfaceView that measures itself to fit a given aspect ratio (letterboxed) inside its parent. */
class AspectRatioSurfaceView(context: Context) : SurfaceView(context) {
    private var aspectW = 0
    private var aspectH = 0

    fun setAspectRatio(w: Int, h: Int) {
        aspectW = w
        aspectH = h
        requestLayout()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val availW = MeasureSpec.getSize(widthMeasureSpec)
        val availH = MeasureSpec.getSize(heightMeasureSpec)
        if (aspectW <= 0 || aspectH <= 0 || availW == 0 || availH == 0) {
            setMeasuredDimension(availW, availH)
            return
        }
        // Fit-center: scale to the largest size that fits while keeping aspect.
        val scale = minOf(availW.toFloat() / aspectW, availH.toFloat() / aspectH)
        setMeasuredDimension((aspectW * scale).toInt(), (aspectH * scale).toInt())
    }
}
