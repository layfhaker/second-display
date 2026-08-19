package com.seconddisplay.client

import android.accessibilityservice.AccessibilityService
import android.util.Log
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

/**
 * Global key capture (runs before apps see the keys). While the client is connected and the
 * activity is in the foreground, forwards modifier keys and ANY key pressed with a modifier
 * (Win/Ctrl/Alt/Shift) to the host — so arbitrary Windows hotkeys work without hardcoding
 * individual combinations. The host synthesizes held modifiers from the metaState.
 */
class ShortcutAccessibilityService : AccessibilityService() {
    private val heldModifierKeys = mutableSetOf<Int>()

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onKeyEvent(event: KeyEvent): Boolean {
        if (!KeyForwarder.canCaptureGlobalShortcuts()) return false

        updateHeldModifierKeys(event)

        // Modifier keys themselves. Search/Sym/Function act as Win on some keyboards.
        if (isModifierKey(event.keyCode) || isWinAliasKey(event.keyCode)) {
            val keyCode = if (isWinAliasKey(event.keyCode)) KeyEvent.KEYCODE_META_LEFT else event.keyCode
            KeyForwarder.sendKey(event.action, keyCode, event.metaState, event.scanCode)
            return true
        }

        // Synthetic combos Android doesn't deliver as ordinary modified keys.
        if (event.keyCode == KeyEvent.KEYCODE_APP_SWITCH) {
            if (event.action == KeyEvent.ACTION_DOWN) KeyForwarder.sendAltTabTap()
            return true
        }
        if (event.keyCode == KeyEvent.KEYCODE_LANGUAGE_SWITCH || event.keyCode == KeyEvent.KEYCODE_SWITCH_CHARSET) {
            if (event.action == KeyEvent.ACTION_DOWN) KeyForwarder.sendWinSpaceTap()
            return true
        }

        // Generic: any known key pressed while a modifier is held -> forward as a host hotkey
        // (covers Win+R, Win+Shift+Arrows, Ctrl+Alt+..., Shift+W+Space in games, etc.).
        if (KeyForwarder.isForwardedKey(event.keyCode) && isAnyModifierHeld(event)) {
            if (event.action == KeyEvent.ACTION_DOWN) {
                Log.d(TAG, "hotkey ${KeyEvent.keyCodeToString(event.keyCode)} meta=${event.metaState}")
            }
            KeyForwarder.sendKey(event.action, event.keyCode, event.metaState, event.scanCode)
            return true
        }

        return false
    }

    private fun updateHeldModifierKeys(event: KeyEvent) {
        if (!isModifierKey(event.keyCode) && !isWinAliasKey(event.keyCode)) return
        when (event.action) {
            KeyEvent.ACTION_DOWN -> heldModifierKeys.add(event.keyCode)
            KeyEvent.ACTION_UP -> heldModifierKeys.remove(event.keyCode)
        }
    }

    private fun isAnyModifierHeld(event: KeyEvent): Boolean {
        if (event.isMetaPressed || event.isCtrlPressed || event.isAltPressed || event.isShiftPressed) return true
        return heldModifierKeys.isNotEmpty()
    }

    private fun isModifierKey(keyCode: Int): Boolean {
        return keyCode == KeyEvent.KEYCODE_META_LEFT ||
            keyCode == KeyEvent.KEYCODE_META_RIGHT ||
            keyCode == KeyEvent.KEYCODE_CTRL_LEFT ||
            keyCode == KeyEvent.KEYCODE_CTRL_RIGHT ||
            keyCode == KeyEvent.KEYCODE_ALT_LEFT ||
            keyCode == KeyEvent.KEYCODE_ALT_RIGHT ||
            keyCode == KeyEvent.KEYCODE_SHIFT_LEFT ||
            keyCode == KeyEvent.KEYCODE_SHIFT_RIGHT
    }

    private fun isWinAliasKey(keyCode: Int): Boolean {
        return keyCode == KeyEvent.KEYCODE_SEARCH ||
            keyCode == KeyEvent.KEYCODE_SYM ||
            keyCode == KeyEvent.KEYCODE_FUNCTION
    }

    companion object {
        private const val TAG = "SecondDisplayKeys"
    }
}
