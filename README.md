# SecondDisplay — Android-планшет как второй монитор по USB

Превращает Android-планшет (OPPO Pad 3 Pro) во **второй монитор** для Windows 11 через USB
(туннель ADB). Рабочий стол **расширяется** на планшет, тач работает как мышь. Видео —
аппаратный **HEVC** (Intel QuickSync) → аппаратный декод на планшете.

## English Summary

SecondDisplay turns an Android tablet into a USB second monitor for Windows 11. The host
uses a virtual display, DXGI Desktop Duplication, hardware HEVC encoding (Intel QuickSync),
and an ADB reverse tunnel to stream frames to the Android client, where MediaCodec decodes
them directly to a Surface.

### Key Features

- Extend the Windows desktop to an Android tablet, or mirror the main display.
- Hardware HEVC encode/decode for a low-latency video path.
- Touch input is sent back to Windows and injected as mouse input.
- Automatic `--auto` mode detects the tablet, enables the virtual display, and starts the stream.
- Windows host in C#/.NET 8 and Android client in Kotlin.

Download the latest Android client from [GitHub Releases](https://github.com/layfhaker/second-display/releases/latest).
The current artifact is a debug APK intended for testing.

```
┌──────────────────────── Windows PC ─────────────────────────┐      ┌──── Android планшет ────┐
│  вирт.дисплей (MttVDD) ─► [Host C#] ─ HEVC(AnnexB)/TCP ─►     │ USB  │  [Client Kotlin]         │
│   захват DXGI + курсор     MediaFoundation→QuickSync         │◄────►│  MediaCodec → Surface    │
│   SendInput (мышь) ◄──── TOUCH-пакеты по TCP ───────────────┼──────┼── норм. координаты 0..1  │
└──────────────────────────────────────────────────────────────┘      └──────────────────────────┘
```

## Статус (2026-06-25)

| Что | Статус |
|-----|--------|
| **Расширение рабочего стола на планшет** (вирт. дисплей, нативное 4К, курсор, тач) | ✅ **работает** (~50 fps) |
| Зеркало основного экрана (HEVC + тач + курсор) | ✅ работает |
| Латентность / 60→144 fps (GPU zero-copy) | 🚧 следующая большая задача — `docs/ROADMAP.md` |
| Стилус с нажатием (OPPO Pen) | ⏳ отложено («фаза 2.5») |

Расширение работает через **готовый драйвер виртуального дисплея MttVDD** на хосте; его монитор
захватывается через **DXGI Desktop Duplication** и идёт в наш HEVC-тракт на планшет.

## Компоненты

| Папка       | Что это                                     | Язык          | Статус |
|-------------|---------------------------------------------|---------------|--------|
| `host/`     | Хост: захват (DXGI/GDI), HEVC, TCP, тач     | C# (.NET 8)   | ✅ работает |
| `android/`  | Клиент: MediaCodec-декод, отрисовка, тач    | Kotlin        | ✅ работает |
| `driver/`   | Код своих драйверов (тупики) + `vdd-readymade/` (готовый MttVDD) | C++ / — | ист. + готовый |
| `docs/`     | **Вся документация** (см. ниже)             | —             | — |

## Быстрый старт

```powershell
# 1. host: захват виртуального дисплея (печатает список мониторов; выбери индекс VDD)
dotnet run --project "host\SecondDisplay.Host" -- --display 2

# 2. туннель + клиент
adb reverse tcp:27315 tcp:27315
adb install -r android\SecondDisplay\app\build\outputs\apk\debug\app-debug.apk
adb shell am start -n com.seconddisplay.client/.MainActivity
```

Виртуальный дисплей даёт драйвер **MttVDD** (`driver/vdd-readymade/` — официальный setup +
`apply_vdd_resolution.cmd` для разрешения 3392×2400). Сборка из CLI — `docs/PREREQUISITES.md`.

## Автоматический режим (--auto) и автозапуск

Хост умеет работать **пассивно в фоне**, без ручного выбора монитора и ручного `adb reverse`:

- Планшет **не подключён** → виртуальный дисплей (VDD) выключен, никакого фантомного монитора
  в «Параметры → Дисплей» нет, порт 27315 не слушается. Хост просто ждёт.
- Планшет **подключён** (появилось ADB-устройство со статусом `device`, на котором установлен
  `com.seconddisplay.client`) → хост включает VDD, находит его монитор, поднимает
  `adb reverse tcp:27315 tcp:27315`, запускает стрим и только затем запускает клиент на планшете
  (`am start`) — так гарантируется, что сервер уже слушает порт к моменту подключения клиента.
- Планшет **отключён** (пропал из `adb devices`, с дебаунсом на пару опросов, чтобы не реагировать
  на мигание ADB) → стрим останавливается, `adb reverse` снимается, VDD выключается обратно.

Реализация — `Orchestrator.cs` (конечный автомат `Passive → Connecting → Streaming → Passive`),
вызывается из `Program.cs` веткой `--auto`.

### Установка автозапуска

```powershell
scripts\install-autostart.ps1
```

Скрипт один раз запросит права администратора (UAC), собирает хост в Release и регистрирует
задачу планировщика `SecondDisplayHost`: запуск при входе в систему, с наивысшими правами, без
видимого окна. Права администратора нужны, потому что `Enable-PnpDevice`/`Disable-PnpDevice` для
VDD требуют повышения; работать это должно именно в **интерактивной сессии пользователя**
(DXGI-захват экрана и инъекция ввода `SendInput` не работают из службы Windows / сессии 0).

Проверить не дожидаясь перезагрузки:

```powershell
Start-ScheduledTask -TaskName SecondDisplayHost
```

### Удаление автозапуска

```powershell
scripts\uninstall-autostart.ps1
```

Снимает задачу планировщика и по возможности выключает VDD, чтобы не остался фантомный монитор.

### Лог и ручная проверка

Лог пассивного режима: `%LOCALAPPDATA%\SecondDisplay\host.log` (усекается при каждом старте).

Запустить вручную (для отладки) — из **элевейтед** консоли (иначе `Enable/Disable-PnpDevice`
упадёт с «Access is denied»):

```powershell
host\SecondDisplay.Host\bin\Release\net8.0-windows\SecondDisplay.Host.exe --auto
```

## Документация (всё в `docs/`)

| Файл | О чём |
|------|-------|
| [`docs/STATUS.md`](docs/STATUS.md) | Что работает, что в работе, журнал решений |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Дорожная карта + планы (GPU zero-copy, GUI, уборка) |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Реализация: видеотракт, захват, живучесть, латентность |
| [`docs/DRIVER_JOURNEY.md`](docs/DRIVER_JOURNEY.md) | Полная сага со своим драйвером и её решение (готовый MttVDD) |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | Сетевой протокол (HELLO/READY/VIDEO/TOUCH) |
| [`docs/PREREQUISITES.md`](docs/PREREQUISITES.md) | Тулчейн и команды сборки (без Visual Studio / Android Studio GUI) |
| [`docs/HARDWARE.md`](docs/HARDWARE.md) | Целевое железо |
| [`docs/DRIVER.md`](docs/DRIVER.md), [`docs/DRIVER_INSTALL.md`](docs/DRIVER_INSTALL.md) | ⚠️ исторические (свой драйвер-тупик) |

## Целевое железо

ASUS Zenbook (Intel Iris Xe → QuickSync) + OPPO Pad 3 Pro (HW HEVC-декод) + хаб UGREEN Revodok.
См. `docs/HARDWARE.md`.
