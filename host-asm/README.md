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
| M7b-2 | **Асинхронный цикл энкодера**: `GetEvent` (`MF_EVENT_FLAG_NO_WAIT`) → `601 METransformNeedInput` → подача NV12-сэмпла → `602 METransformHaveOutput` → `ProcessOutput` → `ConvertToContiguousBuffer`/`Lock` → готовый Annex-B поток | `6a78053` |
| M7c | **Тракт сомкнут**: кадр из захвата (M6) → GPU BGRA→NV12 (M7a) → копия реального NV12-кадра в буфер → энкодер (M7b) кодирует **этот самый кадр**. Доказано суммой яркости: `VPP: Y checksum` = `enc: input luma sum` = 33177600 | `f219746` |
| M8a | **Готовое видео уходит в TCP**: закодированный кадр упаковывается в VIDEO-пакет (`[0x10][u32 len]` + `i64 pts_mks` + `u8 keyframe` + Annex-B) и уходит клиенту, который остался подключён после `HELLO`/`READY`. `keyframe` считается по NAL-типам (19/20/32/33/34), как в Rust-эталоне | этот коммит |

Живые подтверждения из лога:

```
adb devices:            d73f5cf6   device
TCP client connected;   hello width=3000 height=2120 density=420 refresh=144
READY sent (1920x1280 refresh=60 codec=2)
adapter: Intel(R) Iris(R) Xe Graphics  vendor=32902 device=39497
capture source: \\.\DISPLAY1 ; capture width=1920 height=1080 rowpitch=7680 ; capture frame ok
VPP: BGRA->NV12 blt ok ; VPP: NV12 frame captured
VPP: Y checksum=33177600 ; VPP: UV checksum=132710400
MF: hardware HEVC encoder MFTs found=2 ; provides_samples=256
MF: encoder configured (HEVC <- NV12)
  enc: input luma sum=33177600        <- тот же кадр, что захватили (не синтетика)
MF: encoded frames=3 ; total HEVC bytes=1090 ; first frame bytes=823
MF: first frame checksum=93186 ; MF: HEVC encode OK
```

Клиент при этом видит (M8a):

```
READY: 1920x1280 refresh=60 codec=2
VIDEO #1: payload=177089 pts_us=33333 keyframe=1 startcode=True
          первые байты: 00 00 00 01 40 01 0C 01     <- start-code, NAL 32 (VPS), SEI
```

## Следующее

1. Превратить пробу в живой кадровый цикл: `AcquireNextFrame` → VPP → энкодер → `send` — непрерывно,
   с темпом под refresh клиента (сейчас отправка уже работает, но кадров ровно три: проба конечна).
2. Zero-copy вход для энкодера: `MFCreateDXGISurfaceBuffer` + `IMFDXGIDeviceManager` (сейчас кадр едет
   через память: `Map` → копия строк в свой буфер → `Lock` входного буфера MFT).
3. Курсор (`CURSOR`), ввод (`TOUCH`/`KEY` через `SendInput` с нормировкой по виртуальному десктопу),
   `PING`-heartbeat, single-instance (named mutex), CLI (`--auto`/`--display`), High priority.

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
- **Асинхронный MFT кормить только по запросу.** `ProcessInput` до первого `METransformNeedInput`
  даёт `0xC00D36B5` (`MF_E_NOTACCEPTING`) — это нормальный код, а не ошибка (в пробе он не считается
  сбоем). Если MFT отвечает `E_FAIL` на каждую подачу, он болен (у нас — из-за нездорового
  GPU/QuickSync): проба считает такие отказы и после 5 подряд прекращает цикл, иначе копится память
  (`E_OUTOFMEMORY` на `MFCreateMemoryBuffer`).
- **`provides_samples` (`MFT_OUTPUT_STREAM_PROVIDES_SAMPLES = 0x100`) — владение сэмплом у MFT.**
  `ProcessOutput` возвращает **его** сэмпл; освобождать его нельзя (это снимает ссылку самого MFT →
  AV внутри `d3d11`/MF). Рабочий Rust-хост делает `clone()` + drop (AddRef/Release пары) и не
  трогает ссылку MFT — в асме освобождение пропускается, когда `provides_samples != 0`.
- **Строку-лимит цикла копирования считать арифметикой, а не «на глаз».** Копируя NV12 построчно, я
  написал `mov edx,capH / add edx,edx / shr edx,1 / add edx,capH` — это `2*capH` (2160), а нужно
  `3*capH/2` (1620). Цикл писал на мегабайт **за** буфер и падал на `rep movsb`, из-за чего я долго
  искал причину в `rep`/DF/регистрах, пока не оказалось, что виновата арифметика. Правильно:
  `mov eax,edx / shr eax,1 / add edx,eax`.
- **Как ловить такие падения:** событие `Application/1000` даёт **смещение ошибки внутри нашего exe**,
  а `dumpbin /disasm` по этому адресу называет точную инструкцию. Дальше — маркер в логе перед
  подозрительным блоком и пробы «только запись» / «только чтение»: последние сразу показали, что обе
  стороны диапазона валидны, то есть виноват не доступ к памяти, а её размер.
- **Свои же `emit_*` — обычные функции и затирают волатильные регистры.** Если цикл держит указатель в
  `r9`/`r10`/`r11`, а перед ним стоит отладочный вывод, регистры надо перечитать **после** вывода.
- **MASM:** адрес метки берётся через `lea rdi, label` (`mov rdi, label` даёт A2022 — у метки `db`
  размер байтовый), а `mov byte ptr [rdi], 0` неоднозначен — писать через регистр (`mov [rdi], al`).

## Структура `src\main.asm`

Один файл: секции `.data` (строки, GUID-константы, `SECURITY_ATTRIBUTES`), `.data?` (буферы,
хендлы, COM-указатели, структуры) и `.code` с процедурами:

- хелперы вывода: `emit` (лог + stdout), `emit_z`, `emit_num`, `u32_dec`, `u2`, `write_stdout`;
- утилиты: `copy_z`, `copy16` (копия GUID), `wc2a` (UTF-16→ANSI для имён устройств), `rel_if`
  (безопасный `Release`);
- пробы: `run_adb_devices`, `run_tcp_selftest`, `run_dxgi_probe`, `run_capture_probe` (включая
  VPP-часть), `run_encoder_probe`; точка входа `mainCRTStartup`.
