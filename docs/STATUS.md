# Статус и журнал решений

Снимок на **2026-09-19**. Тут — что работает, что заблокировано, и почему приняты решения
(чтобы можно было продолжить с любого места).

## Что работает прямо сейчас
- **РАСШИРЕНИЕ рабочего стола на планшет — РАБОТАЕТ** (главная цель проекта достигнута).
  Готовый драйвер виртуального дисплея **MttVDD** на хосте → реальный 2-й монитор; захват его
  через **DXGI Desktop Duplication** → NV12 → QuickSync HEVC → TCP(`adb reverse`) → Android
  `MediaCodec`. **Нативное 3392×2400 (4К) @ ~50 fps, 0 discard.** Запуск:
  `SecondDisplay.Host.exe --display <idx>` (печатает список мониторов; `--fps N`, `--gdi`,
  `--region x,y,w,h`).
- **Курсор виден на планшете** (подтверждено): DXGI не кладёт курсор в кадр → декодируем
  `PointerShape` (моно/цветной/masked) и накладываем на каждый кадр.
- **Тракт самовосстанавливается** (стресс-тест «теребить окно»): пул NV12-буферов (без GC-мусора),
  неблокирующая подача, watchdog пересоздаёт энкодер при сбое/остановке (>5с), DXGI
  переинициализируется при потере доступа (backoff 2с), глобальный логгер краша. Раньше намертво
  зависал. Исправлено: event loop MFT теперь **обязательно** ждёт кадр при `TransformNeedInput`
  (раньше пропускал → пайплайн стопорился каждые ~25с → пересоздание → фриз на клиенте).
- **Низкая задержка:** очередь энкодера сокращена с вытеснением старого кадра (берётся свежий);
  на планшете включены `KEY_LOW_LATENCY` + Qualcomm vendor low-latency + realtime-приоритет.
- **Клавиатура с планшета → ПК** (код готов): Android перехватывает `KeyEvent`, шлёт пакет `KEY`,
  host маплит основные клавиши в Windows virtual-key и инъектит через `SendInput`.
- **Зеркало основного экрана** (фазы 1/2) тоже работает — захват, HEVC, тач→мышь.
- Подробности драйверной саги и её решения — `docs/DRIVER_JOURNEY.md`; план дальше — `docs/ROADMAP.md`.

## Что в работе / проверить
- **Тач при 200% DPI — работает**: маппинг на координаты VDD проверен, сдвига нет.
- **Лаги / задержка (2026-07-27) — частично исправлено, хост перезапущен:**
  - **Причина #1:** adaptive fps брал 144 Гц с планшета → энкодер в rate control на 144 fps,
    per-frame budget ~10 KB, output ~8–15 fps / ~100 KB/s. **Фикс:** `--max-fps` default **60**.
  - **Причина #2:** ввод (key/touch) крутился в video-loop → latеncy при столле энкодера.
    **Фикс:** dedicated `InputPump` thread (poll ~1 ms) + lock в `InputInjector`.
  - **Причина #3:** VDD поднимался как 800×600; пропал `C:\VirtualDisplayDriver\vdd_settings.xml`.
    **Фикс:** конфиг восстановлен; после Enable — `DisplayConfig.TrySetMode(1920×1280@60)`.
  - **Причина #4:** DXGI не отдавал первый Present после Enable VDD → capture 0 + encoder recreate.
    **Фикс:** blank-frame bootstrap в `UpdateGpu`.
  - **Разрешение кодирования:** по умолчанию HEVC в полном размере монитора (1920×1280). Снизить
    можно через `--encode-width <n>` (VPP-скейл; координаты **и битмап курсора** масштабируются
    согласованно).
  - **Текущие цифры (2026-09-19):** capture ~60 fps, **encoded+sent 30 fps @ 1920×1280, ~1.4–1.5
    МБ/с, enc-lat ~20–30 мс**, 0 discard.
  - **Intel GPU driver обновлён.** Изолированный GPU-тест (`SecondDisplay.Host.exe --selftest-gpu -1
    6 out.h265 30`: DXGI → VPP → zero-copy HEVC, без планшета) проходит — 110/110 кадров,
    «GPU pipeline OK». То есть zero-copy тракт на новом драйвере рабочий.
  - Лог: `%LOCALAPPDATA%\SecondDisplay\host.log`. Спам `adb devices` убран из лога.
- **GPU zero-copy (Фаза 4) — рабочий режим по умолчанию.** VPP BGRA→NV12 + подача NV12-текстуры в
  MFT напрямую (zero-copy). CPU-input путь (`--cpu`) остаётся запасным (DXGI-захват + `BgraToNv12`).
- **Приоритет процесса — High** (`Program.cs`): энкодер MFT и цикл захвата не должны голодать при
  загрузке системы. См. раздел ниже про внешний фактор нагрузки.

## Фиксы зависаний и чёрного экрана (2026-09-19)

Разбор `%LOCALAPPDATA%\SecondDisplay\host.log` + изолированные тесты. Вывод: **баг не в драйвере**
(новый Intel-драйвер проходит `--selftest-gpu`), а в нескольких местах нашего кода плюс голодание
ресурсов.

1. **Гейт готовности требовал MTP/PTP.** На ColorOS планшет часто остаётся в режиме «только adb»,
   и хост ждал бесконечно (в логе — 55 минут `USB mode is not data transfer`). Теперь
   `GetDeviceReadiness` проверяет только `Awake` + `unlocked`.
2. **Реконнект-шторм.** Во время столла/пересоздания энкодера клиент ловил 20-секундный таймаут
   чтения и переподключался, каждый реконнект пересоздавал codec/Surface → мигание чёрным. Хост
   теперь шлёт `PING` (пустой пакет) каждые 2 с, пока нет видео (`Server.cs`, `Protocol.Ping`).
   На клиенте `StreamClient.stop()` помечает остановку намеренной и **не** вызывает `onDisconnect`
   (иначе — бесконечный цикл реконнектов).
3. **Watchdog энкодера: 6 с.** Наблюдаемые столлы «жёсткие» (0 вывода 13–14 с, сами не проходят) —
   пересоздаём через 6 с, а не 12.
4. **Рестарт adb-сервера запрещён во время стрима** (`AdbController.AutoRestartEnabled`): `kill-server`
   рвёт туннель `adb reverse` и убивает клиента — из-за этого мелкий сбой adb превращался в чёрный
   экран. Таймауты adb: `devices` 3 с / shell 6 с / `reverse --remove` 3 с.
5. **Курсор (двоился/«атомы»).** Координаты курсора отправлялись в encode-разрешении, а пиксели — в
   исходном; при encode < capture клиент строил битмап из несовпадающих данных. Теперь хост
   пересчитывает и **битмап** (`StreamingSession.ScaleBgra`).
6. **Устойчивость энкодера к нагрузке:** High priority процесса; защита от NRE в event loop MFT
   (null-event / sample без буфера) с полным стектрейсом при фолте.
7. **Оркестратор терпимее к блипам adb:** «пропажа» из `adb devices` при живом стриме игнорируется;
   таймаут `adb shell` не считается «не готов»; отвал клиента — до ~12 с переприменяем `adb reverse`
   и перезапускаем клиент, и только потом teardown.

**Важно (внешний фактор):** при 100% загрузке CPU (например, параллельная Rust-сборка) MFT-энкодер
блокируется (`ProcessOutput` ~1.7 с), `adb` таймаутит → фриз/чёрный экран. Не гонять тяжёлые сборки
одновременно с работой планшета вторым монитором; High priority снижает эффект.

Ещё не сделано: force keyframe вместо пересоздания энкодера при подключении клиента; убрать мёртвый
UDP/RNDIS-код из `Server.cs`.

## Сессия 2026-09-19 (вечер): мигающие окна, чёрный экран, падение хоста, adb

Хронология: 22:16 хост перезапущен с `CREATE_NO_WINDOW` → 22:26 чёрный экран (фолт энкодера) →
23:05 падение хоста → 23:07 перезапуск → 23:23 перезапуск уже с новыми D3D11-флагами.

1. **Мигающие консольные окна (`13d6177`).** Rust-хост запускал `adb`/`pnputil`/`powershell` без
   `CREATE_NO_WINDOW` (в C# было `CreateNoWindow=true`), поэтому каждый опрос adb (~1/с) мигал
   консольным окном. Фикс: флаг выставлен всем дочерним процессам (`adb.rs::run_process`,
   `AdbLauncher` в `orchestrator.rs`).
2. **Чёрный экран 22:26 — энкодер фолтнул, а его пересоздание зависло навсегда.**
   Лог: `Encoder ProcessInput failed: E_POINTER` → `flagging for restart` → `Encoder unhealthy …
   recreating`, и дальше полная тишина: ни пересозданного энкодера, ни fps. Клиент подключён,
   видео нет. Причина: `HevcEncoder::drop → dispose()` вызывал **`MFShutdown()` на каждое**
   пересоздание (пока живые MF-объекты) и делал **неограниченный `join()`** — поток стрима
   вставал именно здесь. Фикс (`c97c633`): MF-платформа поднимается один раз на процесс
   (`OnceLock`), `MFShutdown` из drop убран; `dispose()` ждёт поток 1.5 с и при неудаче
   отсоединяет его (с записью в лог); логи добавлены по краям обоих `Drop`, чтобы будущий залипон
   называл свой шаг, а не молчал.
3. **Падение хоста 23:05:58 — наш баг, не драйвер.** WER (event 1000): сбойный модуль — **сам
   `SecondDisplay.Host.exe`**, код `0xC0000409` (подкод 7 = `FAST_FAIL_FATAL_APP_EXIT`), то есть
   `abort()`/fail-fast внутри процесса. По списку модулей WER (mfplat, RTWorkQ, Windows.Media,
   `mfx_mft_h265ve_64`, `libmfx64-gen`, `igd11dxva64`) он умер в пути **захват→VPP→энкодер**, а не
   на старте. Событий TDR GPU (`4101`/`igfx`/`igdkmd`) в тот день **нет**.
   Наиболее правдоподобная причина: Rust создавал D3D11-девайс не так, как рабочий C#-эталон —
   только `BGRA_SUPPORT` (без `VIDEO_SUPPORT`), один feature level `11_0` и без
   `SetMultithreadProtected(true)`; при этом этот же девайс отдаётся MF-энкодеру и используется из
   двух потоков одновременно. Фикс (`1db5f58`): `BGRA_SUPPORT | VIDEO_SUPPORT`, уровни
   `11_1/11_0/10_1` и multithread-защита — ровно как в `DxgiCapture.cs`.
4. **Лог больше не уничтожает улики.** `log.rs::init` затирал `host.log` на старте
   (`.truncate(true)`) — из-за этого контекст падения 23:05 восстановить не удалось. Теперь прошлый
   запуск уезжает в `host.log.prev`.
5. **adb: файлы исчезают из-за Defender.** `Get-MpThreat`: `Trojan:Win32/Bearfoos.B!ml` — известный
   ложный ML-детект на Android platform-tools; события 1116/1117, изымались
   `_devhome\...\platform-tools\adb.exe` и `build\staging\...\adb.exe` (триггер — наш хост и ISCC).
   При этом все три копии adb **идентичны по хэшу, подписаны Google и не повреждены**, а сам adb
   падает с той же сигнатурой `abort` (в `ucrtbase.dll`) — то есть «битый бинарь» был неверной
   гипотезой. Попутно: в `bin\rust` **нет** папки `platform-tools`, поэтому ветка «предпочесть adb
   рядом с exe» (её ждёт и установщик) не срабатывает и хост уходит на PATH; в `adb.rs` есть
   мёртвый fallback-путь (`C:\Users\admin\android-build\...` — без `_devhome`).
   **Требует админских прав:** исключение Defender для нашего adb и вынос `platform-tools` в
   `bin\rust`.
6. **Не долбить GPU/дисплейный стек во время стрима (урок).** Серии проб с `DuplicateOutput` и
   `--selftest-gpu` подряд десятками создают D3D11-девайсы и дубликации; вечером это совпало с
   общей нестабильностью (пачки падений adb, «DLL init failed», дальнейшее зависание системы).
   Отладку таких проб делать по одному прогону и, где можно, при остановленном хосте.

**Найдено, но не исправлено (Rust-хост):** порядок `Drop` в `DxgiCapture` (`device` объявлен
раньше `dup`/`staging`/`output1` и освобождается первым, тогда как C# освобождает в обратном
порядке); утечки `ManuallyDrop` (per-frame входная view в `gpu_convert.rs:180`, `pSample`/`pEvents`
в `hevc.rs` — рефкаунты растут каждый кадр); гонка при повторном дублировании
(`reinit_duplication` роняет дубликацию при живом кадре); отсутствие `catch_unwind` вокруг
COM-колбэка (паника через FFI = `abort()` вместо ошибки). Плюс **VDD-драйвер нестабилен**:
`MttVDD.dll` runtime-failures (DriverFrameworks 10111/10121) и 14× не загрузился `WUDFRd` для
`ROOT\DISPLAY\0000` — вероятный триггер падений в этом тракте.

## Хост на ассемблере (`host-asm/`) — 2026-09-19

Полная переписка хоста на **MASM** (`ml64` + `link` из VS BuildTools; NASM в системе нет) — рядом с
C# и Rust, третья реализация. Сборка: `host-asm\build.ps1` → `build\host-asm\SecondDisplay.Host.Asm.exe`
(линкуются `kernel32`, `ws2_32`, `ole32`, `dxgi`, `d3d11`, `mfplat`). Подробности, грабли и
следующие шаги — в **`host-asm/README.md`**.

Сделано (каждый милестоун собран и проверен живым прогоном):
- **M1–M2**: своя точка входа `mainCRTStartup`, прямые вызовы Win32, лог в
  `%LOCALAPPDATA%\SecondDisplay\host-asm.log` с локальным временем.
- **M3** (`cd96e64`): запуск `adb devices` через `CreateProcessA` + `CreatePipe` + `CREATE_NO_WINDOW`.
- **M4** (`1d47332`): **TCP на `ws2_32`** — `WSAStartup`/`socket`/`SO_REUSEADDR`/`bind`/`listen`/
  `select`/`accept`/`recv`/`send`, разбор 5-байтного заголовка, поля `HELLO`, ответ `READY`.
- **M5** (`6b878ee`): **COM с нуля** — `CoInitializeEx` → `CreateDXGIFactory1` → перечисление
  адаптеров и выходов **ручными вызовами через vtables**.
- **M6** (`a227b41`): **захват через Desktop Duplication** — `D3D11CreateDevice` → QI `IDXGIOutput1`
  → `DuplicateOutput` → `AcquireNextFrame` → QI `ID3D11Texture2D` → staging `CreateTexture2D` →
  `CopyResource` → `Map` → контрольная сумма кадра.
- **M7a** (`50b152d`): **GPU BGRA→NV12** через `ID3D11VideoProcessor` (`VideoProcessorBlt`) с
  проверкой по Y/UV-плоскостям.
- **M7b-1** (`989d594`): **Media Foundation и аппаратный HEVC-энкодер** — `MFStartup` →
  `MFTEnumEx(HARDWARE|SORTANDFILTER)` (найдено 2 MFT) → `ActivateObject` → снятие async-лока и
  low latency → HEVC-выход + NV12-вход → `GetOutputStreamInfo` (`provides_samples=0x100`) →
  `ProcessMessage(BEGIN_STREAMING/START_OF_STREAM)`.

**Главный урок M6 (стоил почти целой сессии):** смещения vtable нельзя брать по памяти. Я взял
`IDXGIOutput1::DuplicateOutput` за слот 17 (offset 136), а это **слот 22 (offset 176)**: у
`IDXGIOutput` двенадцать собственных методов (включая `WaitForVBlank`, иной порядок
`TakeOwnership`/`ReleaseOwnership` и три `GetGammaControl*`), а у `IDXGIOutput1` перед
`DuplicateOutput` есть ещё `GetDisplaySurfaceData1`. Слот 17 — это `GetDisplaySurfaceData`, который
QI'ил переданный девайс в `IDXGISurface` и возвращал `E_NOINTERFACE`: выглядело как «DXGI отказывает
в дублировании». Второй баг там же: у `ID3D11DeviceContext::Map` пять параметров — `MapFlags` идёт в
`[rsp+20h]`, а `pMappedResource` в `[rsp+28h]`; я положил указатель в `[rsp+20h]`, и D3D11 записал
структуру по дикому адресу (AV в `d3d11.dll`).

Поэтому теперь всё берётся из источников истины: `host-asm\tools\print_layouts.cpp` и
`print_mf.cpp` печатают через компилятор MSVC **точные байты IID (`__uuidof`), `offsetof`-раскладки
структур и значения enum**, а порядок методов vtable извлекается из заголовков SDK
(`dxgi.h`/`dxgi1_2.h`/`d3d11.h`/`mftransform.h`/`mfobjects.h`). Отдельная мелочь, стоившая билда:
hex-литерал MASM, начинающийся с A–F, обязан иметь ведущий ноль (`0C1h`, а не `C1h`).

Дальше: **M7b-2** — асинхронный цикл событий MFT (`GetEvent` с `MF_EVENT_FLAG_NO_WAIT` →
`METransformNeedInput=601` / `METransformHaveOutput=602`), подача кадра и вычитывание HEVC-потока;
затем сессии/оркестратор и CLI.

## Rust-переписка хоста (`host-rs/`) — 2026-09-19

Параллельно с C#-хостом (`host/`) начата переписка на Rust; **обе версии сосуществуют**, C#
остаётся боевой/референсной. Отдельный крейт `host-rs/` (бин `seconddisplay-host`), биндинги —
`windows` crate (windows-rs) вместо Vortice.

Портировано и проверено на этой машине (`cargo build --release` + self-тесты):
opencards/логирование, протокол, single-instance, adb-контроллер (с теми же фиксами живучести),
readiness, VDD-контроль, enum мониторов + детект VDD, input (SendInput), TCP-сервер с сессиями и
heartbeat, **DXGI Desktop Duplication**, CPU-конверт BGRA→NV12 и **Media Foundation HEVC (QuickSync)**.

Проверки:
- `--selftest-hevc` → 117 кадров, ~4.35 МБ, «HEVC encoder OK».
- `--selftest-gpu -1 --selftest-seconds 5` (GPU zero-copy) → captured 131 / encoded 131 @ 1920×1080, «pipeline OK»; на `--cpu` — 117/117.
- `--probe` → 3 монитора (вкл. VDD) + планшет в `adb devices`.

**GPU zero-copy портирован**: DXGI-текстура → D3D11 VideoProcessor (BGRA→NV12) → NV12-текстура
напрямую в MFT (IMFDXGIDeviceManager) — режим по умолчанию; `--cpu` — запасной путь.
Ещё не портировано: GDI-захват (fallback), мёртвый UDP/RNDIS-транспорт, force-keyframe вместо
пересоздания энкодера. Подробности и грабли MF (601/602, `MF_E_NO_EVENTS_AVAILABLE`,
`MF_EVENT_FLAG_NO_WAIT`) — в `host-rs/README.md`.

## История: своя реализация драйвера (тупик, для справки)
Полностью в **`docs/DRIVER_JOURNEY.md`**. Кратко: свой IddCx-драйвер собирается и грузится, но
крашится `ReportDdiFunctionCountMismatch` — EWDK 28000 даёт несовместимую с IddCx 1.2 этой ОС
DDI-таблицу; нужен старый WDK. Свой KMDOD — тоже тупик (`STATUS_NOT_SUPPORTED`). Поэтому взяли
**готовый** подписанный драйвер (см. выше) — это доказало, что IddCx исправен, проблема была в тулчейне.

## Ключевые технические находки (чтобы не повторять)

### Host / HEVC
- `Vortice` для DXGI/Direct3D11/MediaFoundation: версии 3.8.x требуют .NET 9/10; на .NET 8
  встаёт **3.5.0**. От DXGI-захвата отказались (API отличался) → GDI `CopyFromScreen` для MVP.
- Процесс ОБЯЗАН быть DPI-aware (`SetProcessDpiAwarenessContext(-4)`), иначе захват — только угол.
- GDI не включает курсор → дорисовываем (`GetCursorInfo`/`DrawIconEx`).
- HEVC-энкодер: ленивое создание на подключение → первый кадр всегда с VPS/SPS/PPS+IDR.
- Валидация энкодера без планшета: `SecondDisplay.Host.exe --selftest-hevc out.h265` + `ffprobe`.

### Android
- Сборка из CLI без открытия Android Studio. JDK 21 встроена в Android Studio (`jbr`),
  Gradle нужен JVM 17+ → задавать `JAVA_HOME` на `jbr`. Был мусорный модуль `:seconddisplay`
  (шаблон Fullscreen Activity) — убран; реальный клиент — `:app` / `com.seconddisplay.client`.

### Драйвер — сага с IddCx (важно!)
**Полная хронология и матрица версий — в `docs/DRIVER_JOURNEY.md`.** Кратко:
- **IddCx в системе ЕСТЬ:** `C:\Windows\System32\drivers\UMDF\IddCx.dll` (10.0.26100.4202).
  Ранний вывод «IddCx вырезан» был **ошибкой диагностики** — искали `IddCx.sys`, а это
  `IddCx.dll` (UMDF class extension, user-mode). Из-за этой ошибки был зря весь WDDM/KMDOD-детур.
- Чистый официальный ISO (build 26200) в этой части **совпадает** с хостом — образ НЕ обрезан.
- Свой IddCx-драйвер собран/подписан/ставится (`pnputil` + `devgen /add /bus ROOT`).
  `0xC000007B` был не из-за «нет IddCx», а из-за версионных костылей при сборке;
  после чистой сборки на родной версии кита (UMDF 2.35) **драйвер грузится**.
- **Не решено — версионная привязка.** ОС работает с IddCx **1.2** (как inbox `rdpidd`/`miradisp`),
  а EWDK 28000 даёт грузящийся бинарник только на 2.35/IddCx 1.11 (рантайм-краш
  `ReportDdiFunctionCountMismatch`); сборки 2.15–2.33 не грузятся (`0xD000000D`). См. матрицу версий.
- Эталон MS (`rdpidd.inf`): `UmdfLibraryVersion=2.15.0` + `UmdfExtensions=IddCx0102` (этой строки
  у нас не было — добавлена). Мелочь: `devgen` без `/bus ROOT` создаёт временное SWD-устройство.

## Решения и развилки
1. **Кодек HEVC в нашем коде, без ffmpeg** — пользователь осознанно отверг внешний процесс;
   взяли встроенный Media Foundation через Vortice. (ffmpeg остаётся только для валидации.)
2. **Тестовый режим Windows** — для неподписанного драйвера нужен `testsigning on`, а он требует
   **выключенного Secure Boot** (BIOS). Сделано на ноуте (разово).
3. **WDDM/KMDOD-путь закрыт** — делали, пока ошибочно считали, что IddCx нет. dxgkrnl даёт
   `STATUS_NOT_SUPPORTED` для display-only минипорта на root-устройстве без ресурсов. Возврат к
   IddCx — правильный путь (он для этого и сделан Microsoft).
4. **Тестируем драйвер в VirtualBox** (Win11 Home → нет Hyper-V), т.к. краш драйвера может
   оставить ноут с чёрным экраном. Тестовый стенд автоматизирован (см. DRIVER_JOURNEY).
5. **Мёртвый `SecondDisplayIdd` удалён** (2026-06-26): устройство `ROOT\DEVGEN\SECONDDISP` и
   пакет `oem3.inf` убраны. Рабочий MttVDD (`oem142.inf`) не трогали.

## Следующие шаги
1. **Старый WDK** (≈10.0.16299, эпоха UMDF 2.15 / IddCx 1.2) → собрать IddCx-драйвер ровно по
   рецепту `rdpidd` (UMDF 2.15 + IddCx 1.2 + `UmdfExtensions=IddCx0102`), нативно, без костылей.
2. Или **kernel/UMDF-отладчик** (kd есть в EWDK) → точно декодировать `0xD000000D`.
3. Перед тестом — **свежая VM/снапшот** (текущая замусорена циклами установки, ловит `0xE0000207`).
4. Когда драйвер заведётся — навести `ScreenCapture` на новый монитор → готовый HEVC-тракт.
5. Позже — интегрированный захват из драйвера (shared memory), стилус, упаковка.

## Запасные планы
- **Железо**: UGREEN CM489 (HDMI-выход ноута → карта отдаёт EDID → реальный 2-й монитор) или
  HDMI-заглушка (~$5). Сверху — наш HEVC-тракт. Без драйвера и тестрежима — расширение сегодня.
- **Чистая переустановка** официальной Windows → IddCx-драйвер на родной версии может просто
  заработать (кит-версии этой ОС странные).
