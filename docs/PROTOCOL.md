# Wire-протокол SecondDisplay (v0)

Бинарный, little-endian. Один TCP-поток, кадры с префиксом длины.
Реализация — `host/Protocol.cs` (C#) и `android/.../Protocol.kt` (Kotlin), зеркальны.

**Статус реализации:** HELLO / READY / VIDEO / TOUCH / KEY — ✅ реализованы.
SCROLL (0x21), CONFIG (0x30), REQUEST_IDR — пока не реализованы (на будущее).
Текущий кодек в строю — **H265 (codec=2)**, Annex-B, VPS/SPS/PPS в потоке.

## Общий заголовок пакета
```
offset  size  field
0       1     type      (uint8)   тип пакета
1       4     length    (uint32)  длина payload в байтах
5       ...   payload
```

## Типы пакетов

### 0x01 HELLO (client → host)  — рукопожатие
```
4   width        uint32   px
4   height       uint32   px
4   density      uint32   dpi
4   refreshRate  uint32   Hz
```
Host отвечает 0x02 READY (или закрывает соединение при несовместимости).

### 0x02 READY (host → client)
```
4   chosenWidth   uint32
4   chosenHeight  uint32
4   refreshRate   uint32
1   codec         uint8    0=JPEG, 1=H264, 2=H265
```

### 0x10 VIDEO (host → client)  — видеоданные
```
8   ptsMicros    uint64   presentation timestamp, мкс
1   flags        uint8    bit0 = keyframe
...              payload  один NAL/AU или JPEG-кадр
```

### 0x20 TOUCH (client → host)  — событие касания
```
1   action       uint8    0=down 1=move 2=up
1   pointerId    uint8
4   x            float32  нормировано 0..1
4   y            float32  нормировано 0..1
```

### 0x21 SCROLL (client → host)
```
4   deltaX  float32
4   deltaY  float32
```

### 0x22 KEY (client → host) — событие клавиатуры
```
1   action     uint8    0=down 1=up
2   keyCode    uint16   Android KeyEvent.KEYCODE_*
4   metaState  uint32   Android KeyEvent metaState
2   scanCode   uint16   Android KeyEvent.getScanCode() (evdev), 0 если неизвестен
```
Поле `scanCode` опционально: payload из 7 байт (старый клиент) тоже принимается — тогда scanCode=0.
Host маплит основные Android keycode в Windows virtual-key + PS/2 set-1 скан-код и инъектит через
`SendInput` с `KEYEVENTF_SCANCODE` (и `KEYEVENTF_EXTENDEDKEY` для extended-клавиш), чтобы клавиши
видели игры (DirectInput / Raw Input). Для клавиш вне таблицы используется scanCode из пакета.
Поддержаны буквы/цифры, Enter/Backspace/Tab/Esc, стрелки, Home/End/Page, Insert/Delete,
F1-F12, модификаторы Ctrl/Alt/Shift/Meta (раздельно левые/правые) и базовая пунктуация.

### 0x30 CONFIG (любая сторона) — смена битрейта/разрешения на лету (фаза 2)

## Заметки
- v0: достаточно HELLO/READY/VIDEO/TOUCH/KEY для рабочего MVP.
- Keyframe запрашивается при старте и после потери (фаза 2 — пакет 0x31 REQUEST_IDR).
