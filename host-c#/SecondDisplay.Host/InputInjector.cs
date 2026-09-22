using System.Runtime.InteropServices;

namespace SecondDisplay.Host;

/// <summary>
/// Phase 2: injects touch events as mouse input via SendInput.
/// Keyboard events are injected with PS/2 set-1 scancodes (KEYEVENTF_SCANCODE) so that
/// games reading input via DirectInput / Raw Input see them.
/// </summary>
public static class InputInjector
{
    readonly record struct KeyMapping(ushort Vk, ushort Scan, bool Extended);

    // Android keycode -> (VK, PS/2 set-1 scancode, isExtended). Primary source, also fixes L/R modifiers.
    static readonly Dictionary<ushort, KeyMapping> KeyMap = BuildKeyMap();

    // Fallback for keys outside KeyMap: evdev scancode (from the client) -> set-1 extended scancode.
    // Evdev codes <= 0x58 coincide with set-1 for the main keyboard block and are used directly.
    static readonly Dictionary<ushort, (ushort scan, bool ext)> EvdevExtended = new()
    {
        [96] = (0x1C, true),   // KEY_KPENTER
        [97] = (0x1D, true),   // KEY_RIGHTCTRL
        [98] = (0x35, true),   // KEY_KPSLASH
        [100] = (0x38, true),  // KEY_RIGHTALT
        [102] = (0x47, true),  // KEY_HOME
        [103] = (0x48, true),  // KEY_UP
        [104] = (0x49, true),  // KEY_PAGEUP
        [105] = (0x4B, true),  // KEY_LEFT
        [106] = (0x4D, true),  // KEY_RIGHT
        [107] = (0x4F, true),  // KEY_END
        [108] = (0x50, true),  // KEY_DOWN
        [109] = (0x51, true),  // KEY_PAGEDOWN
        [110] = (0x52, true),  // KEY_INSERT
        [111] = (0x53, true),  // KEY_DELETE
        [125] = (0x5B, true),  // KEY_LEFTMETA
        [126] = (0x5C, true),  // KEY_RIGHTMETA
    };

    // Pressed keys, keyed by Android keycode (stable per physical key, avoids VK collisions).
    static readonly Dictionary<ushort, KeyMapping> DownKeys = [];
    // Synthetic modifiers (from metaState) pressed on behalf of a key; released on that key's key-up.
    static readonly Dictionary<ushort, List<KeyMapping>> SyntheticMods = [];
    // Guards DownKeys/SyntheticMods: InjectKey runs on the input pump thread, ReleaseAllKeys on the main one.
    static readonly object Sync = new();

    /// <summary>Total key events injected (for stats; read/reset by the streaming loop).</summary>
    public static long InjectedKeys;
    /// <summary>Total touch events injected (for stats; read/reset by the streaming loop).</summary>
    public static long InjectedTouches;

    /// <summary>
    /// Per-event tracing (--verbose-input). Off by default: this runs on the InputPump thread,
    /// which exists specifically so key/touch latency doesn't depend on anything else — per-event
    /// logging belongs behind an opt-in flag, not on every keystroke. Aggregate throughput is
    /// always available via InjectedKeys/InjectedTouches (see StreamingSession's periodic stats).
    /// </summary>
    public static bool Verbose;

    public static void InjectTouch(TouchPacket touch, int monitorX, int monitorY, int monitorW, int monitorH)
    {
        Interlocked.Increment(ref InjectedTouches);
        if (Verbose && touch.Action != 1) // log down/up only, moves are too chatty
            Console.WriteLine($"[input] touch {(touch.Action == 0 ? "down" : "up")} x={touch.X:F3} y={touch.Y:F3}");
        int screenX = monitorX + (int)(touch.X * monitorW);
        int screenY = monitorY + (int)(touch.Y * monitorH);

        int vScreenWidth = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        int vScreenHeight = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        int vScreenX = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int vScreenY = GetSystemMetrics(SM_YVIRTUALSCREEN);

        int absX = (int)(((screenX - vScreenX) * 65535.0) / vScreenWidth);
        int absY = (int)(((screenY - vScreenY) * 65535.0) / vScreenHeight);

        uint flags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_MOVE;
        if (touch.Action == 0) flags |= MOUSEEVENTF_LEFTDOWN;
        else if (touch.Action == 2) flags |= MOUSEEVENTF_LEFTUP;

        var input = new INPUT
        {
            type = INPUT_MOUSE,
            u = new INPUTUNION { mi = new MOUSEINPUT { dx = absX, dy = absY, dwFlags = flags } }
        };
        SendInput(1, [input], Marshal.SizeOf<INPUT>());
    }

    public static void InjectKey(KeyPacket key)
    {
        lock (Sync)
        {
        if (!TryResolve(key, out KeyMapping m))
        {
            Console.WriteLine($"[input] key UNMAPPED android={key.KeyCode} scan={key.ScanCode}");
            return;
        }
        if (Verbose)
            Console.WriteLine($"[input] key {(key.Action == 1 ? "up  " : "down")} android={key.KeyCode} vk=0x{m.Vk:X2} scan=0x{m.Scan:X2}{(m.Extended ? " ext" : "")}");
        Interlocked.Increment(ref InjectedKeys);

        bool isKeyUp = key.Action == 1;
        if (isKeyUp)
        {
            if (!DownKeys.Remove(key.KeyCode, out KeyMapping down)) return; // stray key-up, ignore
            SendKey(down, true);
            if (SyntheticMods.Remove(key.KeyCode, out var mods))
                for (int i = mods.Count - 1; i >= 0; i--)
                    SendKey(mods[i], true);
            return;
        }

        bool alreadyDown = DownKeys.ContainsKey(key.KeyCode);

        // Press synthetic modifiers only on the first key-down; they stay held until key-up.
        List<KeyMapping>? newMods = null;
        if (!alreadyDown && !IsModifierKey(m.Vk))
        {
            newMods = GetMissingMetaModifiers(key.MetaState);
            foreach (KeyMapping mod in newMods)
                SendKey(mod, false);
        }

        SendKey(m, false);
        DownKeys[key.KeyCode] = m;
        if (newMods is { Count: > 0 })
            SyntheticMods[key.KeyCode] = newMods;
        }
    }

    /// <summary>Releases every pressed key (call on client disconnect / shutdown to avoid stuck keys).</summary>
    public static void ReleaseAllKeys()
    {
        lock (Sync)
        {
        foreach (KeyMapping m in DownKeys.Values)
            SendKey(m, true);
        DownKeys.Clear();
        SyntheticMods.Clear();
        }
    }

    private static bool TryResolve(KeyPacket key, out KeyMapping m)
    {
        if (KeyMap.TryGetValue(key.KeyCode, out m)) return true;

        // Fallback: use the hardware scancode reported by the client (evdev).
        if (key.ScanCode == 0) return false;
        if (key.ScanCode <= 0x58)
        {
            m = new KeyMapping(0, key.ScanCode, false); // wVk=0: Windows derives VK from the scancode
            return true;
        }
        if (EvdevExtended.TryGetValue(key.ScanCode, out (ushort scan, bool ext) e))
        {
            m = new KeyMapping(0, e.scan, e.ext);
            return true;
        }
        return false;
    }

    private static void SendKey(KeyMapping m, bool keyUp)
    {
        uint flags = KEYEVENTF_SCANCODE;
        if (m.Extended) flags |= KEYEVENTF_EXTENDEDKEY;
        if (keyUp) flags |= KEYEVENTF_KEYUP;
        var input = new INPUT
        {
            type = INPUT_KEYBOARD,
            u = new INPUTUNION { ki = new KEYBDINPUT { wVk = m.Vk, wScan = m.Scan, dwFlags = flags } }
        };
        SendInput(1, [input], Marshal.SizeOf<INPUT>());
    }

    private static List<KeyMapping> GetMissingMetaModifiers(uint metaState)
    {
        var modifiers = new List<KeyMapping>(4);
        if ((metaState & META_SHIFT_ON) != 0 && !IsDown(VK_LSHIFT) && !IsDown(VK_RSHIFT))
            modifiers.Add(new KeyMapping(VK_LSHIFT, 0x2A, false));
        if ((metaState & META_ALT_ON) != 0 && !IsDown(VK_LMENU) && !IsDown(VK_RMENU))
            modifiers.Add(new KeyMapping(VK_LMENU, 0x38, false));
        if ((metaState & META_CTRL_ON) != 0 && !IsDown(VK_LCONTROL) && !IsDown(VK_RCONTROL))
            modifiers.Add(new KeyMapping(VK_LCONTROL, 0x1D, false));
        if ((metaState & META_META_ON) != 0 && !IsDown(VK_LWIN) && !IsDown(VK_RWIN))
            modifiers.Add(new KeyMapping(VK_LWIN, 0x5B, true));
        return modifiers;
    }

    private static bool IsDown(ushort vk)
    {
        foreach (KeyMapping m in DownKeys.Values)
            if (m.Vk == vk) return true;
        return false;
    }

    private static bool IsModifierKey(ushort vk) =>
        vk == VK_LSHIFT || vk == VK_RSHIFT ||
        vk == VK_LMENU || vk == VK_RMENU ||
        vk == VK_LCONTROL || vk == VK_RCONTROL ||
        vk == VK_LWIN || vk == VK_RWIN;

    private static Dictionary<ushort, KeyMapping> BuildKeyMap()
    {
        var map = new Dictionary<ushort, KeyMapping>();

        // A-Z (Android 29..54), set-1 scancodes in alphabetical order
        ushort[] letterScans =
        [
            0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32,
            0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C
        ];
        for (int i = 0; i < 26; i++)
            map[(ushort)(29 + i)] = new KeyMapping((ushort)('A' + i), letterScans[i], false);

        // 0-9 (Android 7..16): 1=0x02 .. 9=0x0A, 0=0x0B
        for (int d = 0; d <= 9; d++)
            map[(ushort)(7 + d)] = new KeyMapping((ushort)('0' + d), (ushort)(d == 0 ? 0x0B : 0x01 + d), false);

        // F1-F12 (Android 131..142)
        ushort[] fScans = [0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58];
        for (int i = 0; i < 12; i++)
            map[(ushort)(131 + i)] = new KeyMapping((ushort)(VK_F1 + i), fScans[i], false);

        // Numpad 0-9 (Android 144..153)
        ushort[] numScans = [0x52, 0x4F, 0x50, 0x51, 0x4B, 0x4C, 0x4D, 0x47, 0x48, 0x49];
        for (int i = 0; i < 10; i++)
            map[(ushort)(144 + i)] = new KeyMapping((ushort)(VK_NUMPAD0 + i), numScans[i], false);

        map[19] = new(VK_UP, 0x48, true);              // DPAD_UP
        map[20] = new(VK_DOWN, 0x50, true);            // DPAD_DOWN
        map[21] = new(VK_LEFT, 0x4B, true);            // DPAD_LEFT
        map[22] = new(VK_RIGHT, 0x4D, true);           // DPAD_RIGHT
        map[55] = new(VK_OEM_COMMA, 0x33, false);      // COMMA
        map[56] = new(VK_OEM_PERIOD, 0x34, false);     // PERIOD
        map[57] = new(VK_LMENU, 0x38, false);          // ALT_LEFT
        map[58] = new(VK_RMENU, 0x38, true);           // ALT_RIGHT
        map[59] = new(VK_LSHIFT, 0x2A, false);         // SHIFT_LEFT
        map[60] = new(VK_RSHIFT, 0x36, false);         // SHIFT_RIGHT
        map[61] = new(VK_TAB, 0x0F, false);            // TAB
        map[62] = new(VK_SPACE, 0x39, false);          // SPACE
        map[66] = new(VK_RETURN, 0x1C, false);         // ENTER
        map[67] = new(VK_BACK, 0x0E, false);           // DEL (backspace)
        map[68] = new(VK_OEM_3, 0x29, false);          // GRAVE
        map[69] = new(VK_OEM_MINUS, 0x0C, false);      // MINUS
        map[70] = new(VK_OEM_PLUS, 0x0D, false);       // EQUALS
        map[71] = new(VK_OEM_4, 0x1A, false);          // LEFT_BRACKET
        map[72] = new(VK_OEM_6, 0x1B, false);          // RIGHT_BRACKET
        map[73] = new(VK_OEM_5, 0x2B, false);          // BACKSLASH
        map[74] = new(VK_OEM_1, 0x27, false);          // SEMICOLON
        map[75] = new(VK_OEM_7, 0x28, false);          // APOSTROPHE
        map[76] = new(VK_OEM_2, 0x35, false);          // SLASH
        map[92] = new(VK_PRIOR, 0x49, true);           // PAGE_UP
        map[93] = new(VK_NEXT, 0x51, true);            // PAGE_DOWN
        map[4] = new(VK_ESCAPE, 0x01, false);          // BACK
        map[111] = new(VK_ESCAPE, 0x01, false);        // ESCAPE
        map[112] = new(VK_DELETE, 0x53, true);         // FORWARD_DEL
        map[113] = new(VK_LCONTROL, 0x1D, false);      // CTRL_LEFT
        map[114] = new(VK_RCONTROL, 0x1D, true);       // CTRL_RIGHT
        map[115] = new(VK_CAPITAL, 0x3A, false);       // CAPS_LOCK
        map[117] = new(VK_LWIN, 0x5B, true);           // META_LEFT
        map[118] = new(VK_RWIN, 0x5C, true);           // META_RIGHT
        map[122] = new(VK_HOME, 0x47, true);           // MOVE_HOME
        map[123] = new(VK_END, 0x4F, true);            // MOVE_END
        map[124] = new(VK_INSERT, 0x52, true);         // INSERT
        map[154] = new(VK_DIVIDE, 0x35, true);         // NUMPAD_DIVIDE
        map[155] = new(VK_MULTIPLY, 0x37, false);      // NUMPAD_MULTIPLY
        map[156] = new(VK_SUBTRACT, 0x4A, false);      // NUMPAD_SUBTRACT
        map[157] = new(VK_ADD, 0x4E, false);           // NUMPAD_ADD
        map[158] = new(VK_DECIMAL, 0x53, false);       // NUMPAD_DOT
        map[160] = new(VK_RETURN, 0x1C, true);         // NUMPAD_ENTER
        map[161] = new(VK_OEM_PLUS, 0x59, false);      // NUMPAD_EQUALS
        return map;
    }

    const uint INPUT_MOUSE = 0;
    const uint INPUT_KEYBOARD = 1;
    const uint MOUSEEVENTF_MOVE = 0x0001;
    const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    const uint MOUSEEVENTF_LEFTUP = 0x0004;
    const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
    const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint KEYEVENTF_SCANCODE = 0x0008;

    const ushort VK_BACK = 0x08;
    const ushort VK_TAB = 0x09;
    const ushort VK_RETURN = 0x0D;
    const ushort VK_CAPITAL = 0x14;
    const ushort VK_ESCAPE = 0x1B;
    const ushort VK_SPACE = 0x20;
    const ushort VK_PRIOR = 0x21;
    const ushort VK_NEXT = 0x22;
    const ushort VK_END = 0x23;
    const ushort VK_HOME = 0x24;
    const ushort VK_LEFT = 0x25;
    const ushort VK_UP = 0x26;
    const ushort VK_RIGHT = 0x27;
    const ushort VK_DOWN = 0x28;
    const ushort VK_INSERT = 0x2D;
    const ushort VK_DELETE = 0x2E;
    const ushort VK_LWIN = 0x5B;
    const ushort VK_RWIN = 0x5C;
    const ushort VK_NUMPAD0 = 0x60;
    const ushort VK_MULTIPLY = 0x6A;
    const ushort VK_ADD = 0x6B;
    const ushort VK_SUBTRACT = 0x6D;
    const ushort VK_DECIMAL = 0x6E;
    const ushort VK_DIVIDE = 0x6F;
    const ushort VK_F1 = 0x70;
    const ushort VK_LSHIFT = 0xA0;
    const ushort VK_RSHIFT = 0xA1;
    const ushort VK_LCONTROL = 0xA2;
    const ushort VK_RCONTROL = 0xA3;
    const ushort VK_LMENU = 0xA4;
    const ushort VK_RMENU = 0xA5;
    const ushort VK_OEM_1 = 0xBA;
    const ushort VK_OEM_PLUS = 0xBB;
    const ushort VK_OEM_COMMA = 0xBC;
    const ushort VK_OEM_MINUS = 0xBD;
    const ushort VK_OEM_PERIOD = 0xBE;
    const ushort VK_OEM_2 = 0xBF;
    const ushort VK_OEM_3 = 0xC0;
    const ushort VK_OEM_4 = 0xDB;
    const ushort VK_OEM_5 = 0xDC;
    const ushort VK_OEM_6 = 0xDD;
    const ushort VK_OEM_7 = 0xDE;
    const int SM_CXVIRTUALSCREEN = 78;
    const int SM_CYVIRTUALSCREEN = 79;
    const int SM_XVIRTUALSCREEN = 76;
    const int SM_YVIRTUALSCREEN = 77;
    const uint META_SHIFT_ON = 0x00000001;
    const uint META_ALT_ON = 0x00000002;
    const uint META_CTRL_ON = 0x00001000;
    const uint META_META_ON = 0x00010000;

    [DllImport("user32.dll")]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    static extern int GetSystemMetrics(int nIndex);

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT
    {
        public uint type;
        public INPUTUNION u;
    }

    [StructLayout(LayoutKind.Explicit)]
    struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT
    {
        public int dx, dy, mouseData;
        public uint dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public IntPtr dwExtraInfo;
    }
}
