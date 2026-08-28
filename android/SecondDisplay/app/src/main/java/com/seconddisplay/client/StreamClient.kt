package com.seconddisplay.client

import android.util.Log
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * TCP client for the SecondDisplay stream (primary transport, works over `adb reverse`).
 *
 * The old version had two freeze-causing problems that are fixed here:
 *  1. onDisconnect() was invoked from the network thread and the activity chained
 *     startClient() from there — a reconnect storm that kept recreating views/codec.
 *     Now the network thread only tears down the codec; reconnect is scheduled on the
 *     UI thread (see MainActivity.onDisconnect).
 *  2. No read timeout: a stalled TCP link (adb/USB hiccup) blocked the read forever,
 *     so the app appeared "frozen" with no way to self-heal. Now we use a read
 *     timeout and drop back to onDisconnect() so the activity can reconnect.
 *
 * NOTE: UDP-over-adb is not possible (adb reverse only forwards TCP), so we stay on
 * TCP. The UDP code remains in the repo as a path for a future RNDIS (USB-Ethernet)
 * transport where UDP would be the better choice.
 */
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

    private companion object {
        private const val TAG = "StreamClient"
    }

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
        val sock = Socket()
        sock.tcpNoDelay = true
        sock.connect(InetSocketAddress(host, port), 5000)
        // Read timeout protects against a *fully dead* link (never self-heals), but it must
        // NOT fire on a brief encoder hiccup — otherwise the client enters an endless
        // reconnect loop whenever the host encoder stalls for a second (observed: 9
        // reconnects in 2 min when enc-lat spiked to 2.6s). 20s gives the encoder/host
        // watchdog time to recover and the stream to resume, while still dropping a truly
        // dead connection.
        sock.soTimeout = 20_000
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
            try {
                val (pktType, pktPayload) = Protocol.readPacket(input)
                if (pktType == PacketType.VIDEO) {
                    onFrame(Protocol.parseVideoFrame(pktPayload))
                } else if (pktType == PacketType.CURSOR) {
                    onCursor(Protocol.parseCursor(pktPayload))
                }
            } catch (e: SocketTimeoutException) {
                // A short encoder stall is not a disconnect. Only a *persistent* silence
                // (20s read timeout) breaks out; the loop will reconnect via onDisconnect.
                Log.w(TAG, "Read timeout (20s) — link may be dead, reconnecting")
                break
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
}
