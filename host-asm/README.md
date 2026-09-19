# SecondDisplay Host — реализация на ассемблере (`host-asm/`)

Третья, **экспериментальная** реализация хоста — на **MASM** (`ml64` + `link`, x64). Пишется для
исследования: насколько далеко можно уйти без C#/Rust, вызывая Win32/COM/DXGI/Media Foundation
напрямую. **Боевой хост — Rust** (`host-rs/`, задача `SecondDisplayHost`), эталон — C# (`host/`).

Логика та же, что в C#/Rust: поднять виртуальный дисплей → захватить его через DXGI Desktop
Duplication → сконвертировать BGRA→NV12 → закодировать в HEVC аппаратным MFT → отдать по TCP
планшету; плюс adb-контроль.

## Сборка и запуск

Требуется только VS Build Tools (MASM + Windows SDK), никаких сторонних библиотек.

```powershell
powershell -ExecutionPolicy Bypass -File host-asm\build.ps1
# -> build\host-asm\SecondDisplay.Host.Asm.exe
.\build\host-asm\SecondDisplay.Host.Asm.exe
```

Сборка внутри: `vcvars64.bat` → `ml64 /c` → `link` с `kernel32.lib ws2_32.lib ole32.lib dxgi.lib
d3d11.lib mfplat.lib`. Путь к `vcvars64.bat` зашит в `build.ps1` (VS Build Tools 18).

Лог: `%LOCALAPPDATA%\SecondDisplay\host-asm.log` (пишется и в stdout).
Сейчас запуск выполняет цепочку самотестов: лог + `adb devices` → TCP-handshake → DXGI-обзор →
захват кадра → GPU-конвертация → настройка MF-энкодера. Сам TCP-листенер самотеста слушает
**27316** (боевой хост занимает 27315), чтобы пробы не мешали живому стриму.

## Милестоуны

| | Что сделано | Коммит |
|---|---|---|
| M1 | Своя точка входа `mainCRTStartup`, прямые вызовы `GetStdHandle`/`WriteFile`/`ExitProcess` | `9eaf3ed` |
| M2 | Лог в `%LOCALAPPDATA%\SecondDisplay\host-asm.log`, локальное время вручную (`GetLocalTime` + свой itoa) | `9eaf3ed` |
| M3 | `adb devices` через `CreateProcessA` + `CreatePipe` + `CREATE_NO_WINDOW`, разбор `ERROR_BROKEN_PIPE` как EOF | `cd96e64` |
| M4 | **TCP на `ws2_32`**: `WSAStartup` → `socket` → `setsockopt(SO_REUSEADDR)` → `bind` → `listen` → `select` → `accept` → `recv`/`send`; разбор заголовка пакета и полей `HELLO`, ответ `READY` | `1d47332` |
| M5 | **COM с нуля**: `CoInitializeEx` → `CreateDXGIFactory1` → `EnumAdapters1`/`GetDesc`/`EnumOutputs` **ручными вызовами через vtables** | `6b878ee` |
| M6 | **Захват Desktop Duplication**: `D3D11CreateDevice` → QI `IDXGIOutput1` → `DuplicateOutput` → `AcquireNextFrame` → QI `ID3D11Texture2D` → staging `CreateTexture2D` → `CopyResource` → `Map` → контрольная сумма кадра | `a227b41` |
| M7a | **GPU BGRA→NV12** через `ID3D11VideoProcessor`: enumerator → processor → NV12 RT-текстура + output view → input view на кадре → `VideoProcessorBlt` → чтение назад по Y/UV | `50b152d` |
| M7b-1 | **Media Foundation + аппаратный HEVC-энкодер**: `MFStartup` → `MFTEnumEx` → `ActivateObject` → async unlock + low latency → HEVC-выход + NV12-вход → `GetOutputStreamInfo` → `ProcessMessage(BEGIN_STREAMING/START_OF_STREAM)` | `989d594` |

Живые подтверждения из лога:

```
adb devices:            d73f5cf6   device
TCP client connected;   hello width=3000 height=2120 density=420 refresh=144
READY sent (1920x1280 refresh=60 codec=2)
adapter: Intel(R) Iris(R) Xe Graphics  vendor=32902 device=39497
capture source: \\.\DISPLAY1 ; capture width=1920 height=1080 rowpitch=7680
VPP: BGRA->NV12 blt ok ; Y checksum=143194976 ; UV checksum=133314356
MF: hardware HEVC encoder MFTs found=2 ; provides_samples=256
MF: encoder configured (HEVC <- NV12)
```

## Следующее (M7b-2 и дальше)

1. **M7b-2**: асинхронный цикл событий MFT — `GetEvent` с `MF_EVENT_FLAG_NO_WAIT` (блокирующий
   `GetEvent` вешает цикл), `METransformNeedInput = 601` → подать кадр (`MFCreateSample` +
   `MFCreateMemoryBuffer`), `METransformHaveOutput = 602` → `ProcessOutput` и вычитать Annex-B.
   `provides_samples = 0x100`, поэтому в `MFT_OUTPUT_DATA_BUFFER` надо класть `pSample = NULL` и
   забирать тот сэмпл, который вернёт MFT.
2. Zero-copy вход для энкодера: `MFCreateDXGISurfaceBuffer` + `IMFDXGIDeviceManager` (сейчас в
   пробе путь через память).
3. Сессии/оркестратор: сессии TCP, курсор (`CURSOR`), ввод (`TOUCH`/`KEY` через `SendInput`),
   `PING`-heartbeat, single-instance, CLI (`--auto`/`--display`).

## Правила работы с COM в этом проекте

**Смещения vtable не берутся по памяти.** На M6 я посчитал `IDXGIOutput1::DuplicateOutput` слотом 17
(offset 136), а он — **слот 22 (offset 176)**: у `IDXGIOutput` двенадцать собственных методов
(`GetDesc`, `GetDisplayModeList`, `FindClosestMatchingMode`, `WaitForVBlank`, `TakeOwnership`,
`ReleaseOwnership`, `GetGammaControlCapabilities`, `SetGammaControl`, `GetGammaControl`,
`SetDisplaySurface`, `GetDisplaySurfaceData`, `GetFrameStatistics`), а у `IDXGIOutput1` перед
`DuplicateOutput` есть ещё `GetDisplaySurfaceData1`. Слот 17 — это `GetDisplaySurfaceData`: он
пытался QI'ить переданный ему D3D11-девайс в `IDXGISurface` и возвращал **`E_NOINTERFACE`** —
выглядело ровно как «DXGI отказывается дублировать этот выход», и я долго искал причину не там.

Источники истины:

- `tools\print_layouts.cpp` и `tools\print_mf.cpp` — печатают через компилятор MSVC **точные байты
  IID (`__uuidof`), `offsetof`-раскладки структур и значения enum**:
  ```
  cl /nologo /EHsc tools\print_layouts.cpp
  cl /nologo /EHsc tools\print_mf.cpp mfplat.lib mfuuid.lib ole32.lib
  ```
  Оба печатают hex в MASM-безопасном виде (см. ниже).
- Порядок методов vtable — из заголовков SDK (`dxgi.h`, `dxgi1_2.h`, `d3d11.h`, `mftransform.h`,
  `mfobjects.h` в `Windows Kits\10\Include\...\{um,shared}`), а не из документации и не из памяти.

### Мелочи, которые стоят билдов и сессий

- **MASM: hex-литерал, начинающийся с A–F, требует ведущего нуля.** `C1h` читается как
  идентификатор — надо `0C1h`. Именно поэтому инструменты печатают с ведущим нулём.
- **x64 ABI**: 4 регистра + `this`, дальше аргументы на стеке начиная с `[rsp+20h]` (shadow space
  `[rsp+0..0x1F]`); стек перед `call` выровнен на 16. Классический баг — 5-й аргумент вместо 4-го:
  у `ID3D11DeviceContext::Map` **пять** параметров, `MapFlags` идёт в `[rsp+20h]`, а
  `pMappedResource` в `[rsp+28h]`; перепутав, получаешь запись структуры по дикому адресу (AV внутри
  `d3d11.dll`).
- **`CreatePipe`** требует `SECURITY_ATTRIBUTES { bInheritHandle = TRUE }`, иначе дочерний процесс
  не получит write-end.
- **`ReadFile`**: запрашивать не больше `sizeof` буфера (иначе `ERROR_NOACCESS` 998).
- **MF**: `METransformNeedInput = 601`, `METransformHaveOutput = 602` (не 1/2);
  `MF_E_NO_EVENTS_AVAILABLE = 0xC00D3E80`; `GetEvent` — только с `MF_EVENT_FLAG_NO_WAIT`; MF и
  нитку лучше поднимать один раз на процесс (`MFStartup`/`MFShutdown` — не на каждый энкодер).

## Структура `src\main.asm`

Один файл: секции `.data` (строки, GUID-константы, `SECURITY_ATTRIBUTES`), `.data?` (буферы,
хендлы, COM-указатели, структуры) и `.code` с процедурами:

- хелперы вывода: `emit` (лог + stdout), `emit_z`, `emit_num`, `u32_dec`, `u2`, `write_stdout`;
- утилиты: `copy_z`, `copy16` (копия GUID), `wc2a` (UTF-16→ANSI для имён устройств), `rel_if`
  (безопасный `Release`);
- пробы: `run_adb_devices`, `run_tcp_selftest`, `run_dxgi_probe`, `run_capture_probe` (включая
  VPP-часть), `run_encoder_probe`; точка входа `mainCRTStartup`.
