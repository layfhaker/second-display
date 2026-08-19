# Архитектура

Документ описывает **фактическую** реализацию (что в коде), а не первоначальный план.

## Видеотракт (что реально работает — зеркало)

1. **Захват экрана** — выбор монитора + два бэкенда.
   - Процесс делается **per-monitor DPI-aware** (`SetProcessDpiAwarenessContext`), иначе
     Windows отдаёт виртуализированное разрешение и захватывается только угол экрана.
   - **Выбор монитора:** `ScreenCapture.GetMonitors()` (Win32 `EnumDisplayMonitors`, физические
     координаты) печатает список; `Program.cs` берёт `--display <idx>` или `--region x,y,w,h`.
     Так наводимся на **виртуальный дисплей** (расширение), а не на основной экран.
   - **Основной бэкенд — `host/DxgiCapture.cs`: DXGI Desktop Duplication (GPU).** Тянет 4К на
     полной частоте; быстрая ровная подача критична — медленный захват вешает async-энкодер
     (см. DRIVER_JOURNEY/историю). Desktop Duplication **не** кладёт курсор в кадр → держим
     «чистый» буфер и **накладываем курсор сами** из `GetFramePointerShape`
     (моно/цветной/masked форматы), композит на каждый кадр, чтобы курсор двигался и на статике.
   - **Fallback — `host/ScreenCapture.cs`: GDI `CopyFromScreen`** (флаг `--gdi` или если DXGI
     недоступен). Медленный (на 4К ~7 fps), курсор дорисовывает через `DrawIconEx`. Оставлен как
     запасной; рабочий путь — DXGI.
2. **BGRA → NV12** — `host/ColorConvert.cs` (unsafe, `Parallel.For`). Энкодеру нужен NV12.
3. **HEVC-кодирование** — `host/HevcEncoder.cs`. Встроенный **Media Foundation** HEVC encoder
   MFT, который на этом железе маппится на **Intel QuickSync**. Доступ из C# через
   `Vortice.MediaFoundation` (типизированный COM-биндинг, **не** ffmpeg — внешний процесс
   пользователь отверг осознанно). Асинхронный MFT гоняется на фоновом потоке (event loop
   `METransformNeedInput`/`METransformHaveOutput`).
   - Выход: сырой **HEVC Annex-B** (start codes), VPS/SPS/PPS **в потоке** на первом кадре.
   - Энкодер создаётся **лениво при подключении клиента** и убивается при отключении — так
     первый кадр каждого подключения несёт VPS/SPS/PPS + IDR (важно для переподключений).
   - Проверено host-side через `ffprobe` (self-test: `SecondDisplay.Host.exe --selftest-hevc`).
4. **Транспорт** — `host/Server.cs` + `Protocol.cs`. TCP на `127.0.0.1:27315`, пакеты с
   префиксом длины (см. `docs/PROTOCOL.md`). Каждый access unit → пакет `VIDEO`.
5. **Декод на планшете** — `android/.../MainActivity.kt`. `MediaCodec` (`c2.qti.hevc.decoder`)
   рендерит **прямо в Surface** (`AspectRatioSurfaceView`), без промежуточного Bitmap.

## Тач/ввод (работает)

1. Клиент шлёт нормированные координаты `0..1` относительно области картинки (с учётом
   letterbox — `AspectRatioSurfaceView`).
2. Host (`InputInjector.cs`) пересчитывает в абсолютные координаты монитора и зовёт
   `SendInput` с `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`. action: 0=down/1=move/2=up.
3. Стилус с нажатием/наклоном — отдельная «фаза 2.5»: на Android снимать `getPressure()`/tilt,
   на ПК инъектить через `CreateSyntheticPointerDevice`/`InjectSyntheticPointerInput` (перо).

## Пропорции / разрешение

- Клиент при `HELLO` сообщает `width × height × density × refreshRate`.
- Host кодирует в **разрешении выбранного монитора** (динамически из DXGI/EnumDisplayMonitors,
  чётные размеры для NV12). Для виртуального дисплея это **нативные 3392×2400** (3:2 под планшет).
- Виртуальный дисплей задан под аспект планшета → letterbox ≈ 0, fullscreen, тач ~1:1.

## Расширение рабочего стола (виртуальный дисплей)

### ✅ РЕШЕНИЕ: готовый драйвер MttVDD
Виртуальный дисплей даёт **готовый** драйвер **VirtualDrivers/Virtual-Display-Driver (MttVDD)** —
IddCx UMDF, `UmdfLibraryVersion=2.25.0 + UmdfExtensions=IddCx0102`, hwid `Root\MttVDD`. Поставлен
официальным `setup-x64.exe` на ХОСТ (драйвер подписан SignPath→GlobalSign; обёртка-инсталлятор без
подписи). Работает (`Status=OK`). Файлы в `C:\VirtualDisplayDriver\`; разрешение — через
`driver/vdd-readymade/apply_vdd_resolution.cmd`. **Захват его монитора** — обычным DXGI-трактом выше.

Вывод: проблема была **только в нашем тулчейне** (EWDK 28000), а сам IddCx исправен. Свои драйверы —
тупики (ниже), оставлены для истории.

### Путь A (свой IddCx-драйвер) — ❌ тупик на EWDK 28000
`driver/SecondDisplayIdd/` собирается, ставится, **грузится** (UMDF 2.35), но крашится
`ReportDdiFunctionCountMismatch`: EWDK 28000 объявляет иное число IddCx-DDI, чем рантайм IddCx 1.2
этой ОС. Все версии проверены. Нужен старый WDK (рецепт `rdpidd`). Хронология — `docs/DRIVER_JOURNEY.md`.

### Путь B (свой KMDOD) — ❌ тупик
WDDM display-only miniport на базе MS **KMDOD** (`driver/wds-tmp/video/KMDOD/`). dxgkrnl даёт
`STATUS_NOT_SUPPORTED` для display-only на root-устройстве без ресурсов — для этого и сделан IddCx.

## Путь данных и узкое место (важно для Фазы 4)
Кадр сейчас: **GPU (DXGI-захват) → CPU (staging-копия + наложение курсора + `BgraToNv12`, ~25мс на
8 МП) → GPU (QuickSync-энкодер)**. Этот крюк через CPU — потолок fps (~50 на 4К) и кусок задержки
(две пересылки GPU↔CPU). Цель Фазы 4 — убрать CPU из тракта (VideoProcessor + D3D11-вход энкодера,
zero-copy). См. `docs/ROADMAP.md`.

## Живучесть тракта (HevcEncoder/Program)
- **Пул NV12-буферов** вместо `Clone()` каждый кадр — иначе ~600 МБ/с GC-мусора → паузы → async-MFT
  виснет. Подача **неблокирующая** (дроп вместо ожидания) — иначе блокировка замедляет захват и
  душит энкодер (был вечный фриз).
- **Event loop: обязательное ожидание кадра.** Когда MFT шлёт `TransformNeedInput`, event loop
  **блокируется до появления кадра** (`TryTake` в цикле). Раньше при пустой очереди запрос
  игнорировался — MFT не повторяет `NeedInput`, пайплайн намертво зависал каждые ~25с, watchdog
  убивал энкодер, на клиенте — фриз+перезагрузка потока.
- **Watchdog:** энкодер помечается `Faulted` при сбое потока событий; главный цикл пересоздаёт его
  при сбое или простое вывода >5с. Глобальный логгер `UnhandledException`.
- **DXGI access lost** (`0x887A0026/0022`, смена режима/UAC/fullscreen) → `_dup` обнуляется,
  переинициализация с **2с backoff** (раньше спамил NRE ~30 раз/с при затяжной потере). Пока
  duplication не восстановлен, энкодер получает последний захваченный кадр (экран замирает, но
  не падает).

## Латентность — на что смотрим
- Кодек: low-latency MFT (`MF_LOW_LATENCY`), `bframes=0`, маленький GOP.
- Очередь энкодера маленькая, **вытеснение старого кадра** (берётся свежий) — минимум «догоняющей» лаги.
- Сеть: `TcpNoDelay`, отдельный поток на запись; локально через `adb reverse`.
- Клиент: `MediaCodec` → `Surface` напрямую; включены **`KEY_LOW_LATENCY`** (API 30+), вендорный
  Qualcomm `vendor.qti-ext-dec-low-latency.enable`, `KEY_PRIORITY=0`, высокий `KEY_OPERATING_RATE`.
- Остаточный «пол» — физика кодек+сеть+декодер + текущий GPU↔CPU-крюк (уберём в Фазе 4).
