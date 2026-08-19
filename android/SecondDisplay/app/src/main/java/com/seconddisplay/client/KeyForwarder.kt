package com.seconddisplay.client

import android.view.KeyEvent

object KeyForwarder {
    @Volatile
    private var client: StreamClient? = null
    @Volatile
    private var activityActive = false

    fun attach(streamClient: StreamClient) {
        client = streamClient
    }

    fun detach(streamClient: StreamClient?) {
        if (client === streamClient) client = null
    }

    fun hasClient(): Boolean = client != null

    fun setActivityActive(active: Boolean) {
        activityActive = active
    }

    fun canCaptureGlobalShortcuts(): Boolean = client != null && activityActive

    /** Keys that have a mapping on the host (see InputInjector key table). */
    fun isForwardedKey(keyCode: Int): Boolean {
        if (keyCode in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z) return true
        if (keyCode in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9) return true
        if (keyCode in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12) return true
        if (keyCode in KeyEvent.KEYCODE_NUMPAD_0..KeyEvent.KEYCODE_NUMPAD_9) return true

        return when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP,
            KeyEvent.KEYCODE_DPAD_DOWN,
            KeyEvent.KEYCODE_DPAD_LEFT,
            KeyEvent.KEYCODE_DPAD_RIGHT,
            KeyEvent.KEYCODE_COMMA,
            KeyEvent.KEYCODE_PERIOD,
            KeyEvent.KEYCODE_ALT_LEFT,
            KeyEvent.KEYCODE_ALT_RIGHT,
            KeyEvent.KEYCODE_SHIFT_LEFT,
            KeyEvent.KEYCODE_SHIFT_RIGHT,
            KeyEvent.KEYCODE_TAB,
            KeyEvent.KEYCODE_SPACE,
            KeyEvent.KEYCODE_ENTER,
            KeyEvent.KEYCODE_DEL,
            KeyEvent.KEYCODE_GRAVE,
            KeyEvent.KEYCODE_MINUS,
            KeyEvent.KEYCODE_EQUALS,
            KeyEvent.KEYCODE_LEFT_BRACKET,
            KeyEvent.KEYCODE_RIGHT_BRACKET,
            KeyEvent.KEYCODE_BACKSLASH,
            KeyEvent.KEYCODE_SEMICOLON,
            KeyEvent.KEYCODE_APOSTROPHE,
            KeyEvent.KEYCODE_SLASH,
            KeyEvent.KEYCODE_PAGE_UP,
            KeyEvent.KEYCODE_PAGE_DOWN,
            KeyEvent.KEYCODE_APP_SWITCH,
            KeyEvent.KEYCODE_BACK,
            KeyEvent.KEYCODE_ESCAPE,
            KeyEvent.KEYCODE_FORWARD_DEL,
            KeyEvent.KEYCODE_CTRL_LEFT,
            KeyEvent.KEYCODE_CTRL_RIGHT,
            KeyEvent.KEYCODE_CAPS_LOCK,
            KeyEvent.KEYCODE_META_LEFT,
            KeyEvent.KEYCODE_META_RIGHT,
            KeyEvent.KEYCODE_MOVE_HOME,
            KeyEvent.KEYCODE_MOVE_END,
            KeyEvent.KEYCODE_INSERT,
            KeyEvent.KEYCODE_NUMPAD_DIVIDE,
            KeyEvent.KEYCODE_NUMPAD_MULTIPLY,
            KeyEvent.KEYCODE_NUMPAD_SUBTRACT,
            KeyEvent.KEYCODE_NUMPAD_ADD,
            KeyEvent.KEYCODE_NUMPAD_DOT,
            KeyEvent.KEYCODE_NUMPAD_ENTER,
            KeyEvent.KEYCODE_NUMPAD_EQUALS -> true
            else -> false
        }
    }

    fun sendKey(action: Int, keyCode: Int, metaState: Int, scanCode: Int = 0) {
        val wireAction: Byte = when (action) {
            KeyEvent.ACTION_DOWN -> 0
            KeyEvent.ACTION_UP -> 1
            else -> return
        }
        client?.sendKey(wireAction, keyCode, metaState, scanCode)
    }

    fun sendAltTabTap() {
        sendKey(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ALT_LEFT, 0)
        sendKey(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB, KeyEvent.META_ALT_ON)
        sendKey(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_TAB, KeyEvent.META_ALT_ON)
        sendKey(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ALT_LEFT, 0)
    }

    fun sendWinSpaceTap() {
        sendKey(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_META_LEFT, 0)
        sendKey(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_SPACE, KeyEvent.META_META_ON)
        sendKey(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_SPACE, KeyEvent.META_META_ON)
        sendKey(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_META_LEFT, 0)
    }
}
