package com.seconddisplay.client

import android.util.Log
import java.io.OutputStream
import java.net.Socket
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

class StreamClient(
    private val host: String = "127.0.0.1",
    private val port: Int = 27315,
    private val onReady: (ReadyPacket) -> Unit,
    private val onFrame: (VideoFrame) -> Unit,
    private val onCursor: (CursorPacket) -> Unit,
    private val onDisconnect: () -> Unit
) {
    private val running = AtomicBoolean(false)
    private var socket: Socket? = null
    private var outputStream: OutputStream? = null
    private val outboundQueue = ArrayBlockingQueue<OutboundEvent>(128)

    fun start(screenWidth: Int, screenHeight: Int, density: Int, refreshRate: Int) {
        if (running.getAndSet(true)) return

        Thread {
            try {
                connect(screenWidth, screenHeight, density, refreshRate)
            } catch (e: Exception) {
                Log.e(TAG, "Connection failed", e)
            } finally {
                running.set(false)
                onDisconnect()
            }
        }.start()
    }

    fun stop() {
        running.set(false)
        try { socket?.close() } catch (_: Exception) {}
    }

    fun sendTouch(action: Byte, pointerId: Byte, x: Float, y: Float) {
        outboundQueue.offer(OutboundEvent.Touch(action, pointerId, x, y))
    }

    fun sendKey(action: Byte, keyCode: Int, metaState: Int, scanCode: Int = 0) {
        outboundQueue.offer(OutboundEvent.Key(action, keyCode, metaState, scanCode))
    }

    private fun connect(screenWidth: Int, screenHeight: Int, density: Int, refreshRate: Int) {
        val sock = Socket(host, port).apply { tcpNoDelay = true }
        socket = sock
        val input = sock.getInputStream()
        val output = sock.getOutputStream().buffered()
        outputStream = output

        Protocol.writeHello(output, screenWidth, screenHeight, density, refreshRate)

        val (type, payload) = Protocol.readPacket(input)
        if (type != PacketType.READY) throw IllegalStateException("Expected READY, got $type")
        val ready = Protocol.parseReady(payload)
        Log.i(TAG, "Server ready: ${ready.width}x${ready.height} codec=${ready.codec}")
        onReady(ready)

        Thread { outboundSendLoop(output) }.start()

        while (running.get()) {
            val (pktType, pktPayload) = Protocol.readPacket(input)
            if (pktType == PacketType.VIDEO) {
                onFrame(Protocol.parseVideoFrame(pktPayload))
            } else if (pktType == PacketType.CURSOR) {
                onCursor(Protocol.parseCursor(pktPayload))
            }
        }
    }

    private fun outboundSendLoop(output: OutputStream) {
        try {
            while (running.get()) {
                val event = outboundQueue.poll(100, java.util.concurrent.TimeUnit.MILLISECONDS)
                    ?: continue
                when (event) {
                    is OutboundEvent.Touch ->
                        Protocol.writeTouch(output, event.action, event.pointerId, event.x, event.y)
                    is OutboundEvent.Key ->
                        Protocol.writeKey(output, event.action, event.keyCode, event.metaState, event.scanCode)
                }
            }
        } catch (_: Exception) {}
    }

    private sealed class OutboundEvent {
        data class Touch(val action: Byte, val pointerId: Byte, val x: Float, val y: Float) : OutboundEvent()
        data class Key(val action: Byte, val keyCode: Int, val metaState: Int, val scanCode: Int) : OutboundEvent()
    }

    companion object {
        private const val TAG = "StreamClient"
    }
}
