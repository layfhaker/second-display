package com.seconddisplay.client

import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

object PacketType {
    const val HELLO: Byte = 0x01
    const val READY: Byte = 0x02
    const val VIDEO: Byte = 0x10
    const val CURSOR: Byte = 0x11
    const val TOUCH: Byte = 0x20
    const val SCROLL: Byte = 0x21
    const val KEY: Byte = 0x22
}

data class ReadyPacket(
    val width: Int,
    val height: Int,
    val refreshRate: Int,
    val codec: Byte
)

data class VideoFrame(
    val ptsMicros: Long,
    val keyframe: Boolean,
    val data: ByteArray
)

data class CursorPacket(
    val visible: Boolean,
    val x: Int,
    val y: Int,
    val width: Int,
    val height: Int,
    val bgra: ByteArray
)

object Protocol {
    private const val HEADER_SIZE = 5
    private const val MAX_PACKET_SIZE = 16 * 1024 * 1024

    fun writeHello(out: OutputStream, width: Int, height: Int, density: Int, refreshRate: Int) {
        val payload = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(width)
            .putInt(height)
            .putInt(density)
            .putInt(refreshRate)
            .array()
        writePacket(out, PacketType.HELLO, payload)
    }

    fun writeTouch(out: OutputStream, action: Byte, pointerId: Byte, x: Float, y: Float) {
        val payload = ByteBuffer.allocate(10).order(ByteOrder.LITTLE_ENDIAN)
            .put(action)
            .put(pointerId)
            .putFloat(x)
            .putFloat(y)
            .array()
        writePacket(out, PacketType.TOUCH, payload)
    }

    fun writeKey(out: OutputStream, action: Byte, keyCode: Int, metaState: Int, scanCode: Int = 0) {
        val payload = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN)
            .put(action)
            .putShort(keyCode.toShort())
            .putInt(metaState)
            .putShort(scanCode.toShort())
            .array()
        writePacket(out, PacketType.KEY, payload)
    }

    fun readPacket(input: InputStream): Pair<Byte, ByteArray> {
        val header = readExact(input, HEADER_SIZE)
        val buf = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
        val type = buf.get()
        val length = buf.getInt()
        if (length < 0 || length > MAX_PACKET_SIZE)
            throw IllegalStateException("Packet too large: $length")
        val payload = readExact(input, length)
        return Pair(type, payload)
    }

    fun parseReady(payload: ByteArray): ReadyPacket {
        val buf = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
        return ReadyPacket(
            width = buf.getInt(),
            height = buf.getInt(),
            refreshRate = buf.getInt(),
            codec = buf.get()
        )
    }

    fun parseVideoFrame(payload: ByteArray): VideoFrame {
        val buf = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
        val pts = buf.getLong()
        val flags = buf.get()
        val data = ByteArray(payload.size - 9)
        buf.get(data)
        return VideoFrame(pts, flags.toInt() and 1 != 0, data)
    }

    fun parseCursor(payload: ByteArray): CursorPacket {
        val buf = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
        val visible = buf.get().toInt() != 0
        val x = buf.getInt()
        val y = buf.getInt()
        val width = buf.getInt()
        val height = buf.getInt()
        val data = ByteArray(payload.size - 17)
        buf.get(data)
        return CursorPacket(visible, x, y, width, height, data)
    }

    private fun writePacket(out: OutputStream, type: Byte, payload: ByteArray) {
        val header = ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN)
            .put(type)
            .putInt(payload.size)
            .array()
        out.write(header)
        out.write(payload)
        out.flush()
    }

    private fun readExact(input: InputStream, size: Int): ByteArray {
        val buf = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val read = input.read(buf, offset, size - offset)
            if (read < 0) throw IllegalStateException("Connection closed")
            offset += read
        }
        return buf
    }
}
