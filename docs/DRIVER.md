# Драйвер виртуального дисплея

> ⚠️ **ИСТОРИЧЕСКОЕ / УСТАРЕЛО.** Этот документ — про НАШИ драйверы (оба оказались тупиками).
> Актуальное решение — **готовый драйвер MttVDD** (см. `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`),
> а полная хронология и выводы по своему драйверу — `docs/DRIVER_JOURNEY.md`. Ниже — для истории;
> вывод «IddCx вырезан» ОШИБОЧЕН (IddCx исправен, падали из-за тулчейна EWDK 28000).

Цель — дать Windows второй (виртуальный) монитор, чтобы рабочий стол **расширялся** на планшет.
Здесь два подхода: первый (IddCx) и второй (WDDM/KMDOD) — **оба тупики**, см. баннер выше.

Сборка обоих — через **EWDK** (без Visual Studio). Общая команда:
```powershell
# в одном cmd: vswhere в PATH → среда EWDK → msbuild
cmd /c "set ""PATH=C:\Program Files (x86)\Microsoft Visual Studio\Installer;%PATH%"" && call D:\BuildEnv\SetupBuildEnv.cmd amd64 && msbuild ""<vcxproj>"" /p:Configuration=Release /p:Platform=x64"
```
Важно: EWDK ставит `VSCMD_ARG_winsdk=none` → SDK/WDK-пути не попадают в `INCLUDE`/`LIB`
автоматически, поэтому в vcxproj прописаны явные пути к киту (`D:\Program Files\Windows Kits\10`,
версия `10.0.28000.0`). Детали и точные пути — в `memory` проекта и комментариях vcxproj.

---

## 1. `SecondDisplayIdd/` — IddCx (UMDF) драйвер — ❌ ЗАБЛОКИРОВАН на этой машине

Современный «лёгкий» путь: user-mode IddCx-драйвер регистрирует виртуальный монитор.
Собран, тест-подписан, **ставится и опознаётся** (Class=Display), НО **не грузится**:

```
UMDF host: 0xC000007B STATUS_INVALID_IMAGE_FORMAT
```

Причина: в этой **обрезанной сборке Windows вырезан рантайм `IddCx.sys`** (нет ни в System32,
ни в drivers, ни в WinSxS — проверено). Остался только осиротевший ключ реестра
`Wdf\Umdf\IddCx\Versions\1\2`. Поэтому **никакой** IddCx-драйвер (наш, готовый VDD, spacedesk
в IddCx-режиме) тут не запустится, пока IddCx не восстановить (DISM из официального ISO).

Что отлажено и переиспользуемо (если IddCx вернут): тестовый режим, тест-сертификат,
`pnputil /add-driver`, `devgen /add /bus ROOT`, важная мелочь — `UmdfLibraryVersion = 2.23`
в INF (иначе коинсталлер падает с Error 87). Подробная хронология — `docs/DRIVER_JOURNEY.md`.
Установочные шаги (исторические) — `docs/DRIVER_INSTALL.md`.

## 2. `wds-tmp/video/KMDOD/` — свой WDDM display-only драйвер — 🚧 ТЕКУЩИЙ

Не зависит от IddCx: реализуем уровень ниже (WDDM display-only miniport), на базе официального
Microsoft **KMDOD** sample. Это драйвер **режима ядра** (краш = BSOD/чёрный экран → тестируем
в VM).

**Сделано (компилируется → `SampleDisplay.sys`):**
- `StartDevice` (`bdd.cxx`): вместо `DxgkCbAcquirePostDisplayOwnership` синтезирует свой режим
  `1920×1200 X8R8G8B8` (не зависит от реального POST-устройства).
- Фреймбуфер (`bdd_util.cxx`): `ExAllocatePool2` (системная RAM) вместо `MmMapIoSpace` железа.
- Список режимов (`bdd_dmm.cxx`): таблица уже содержит `1920×1200`.
- INF: root-enumerated `Root\SecondDisplayDod`.

**Главный неизвестный риск (проверяем в VM):** запустит ли `dxgkrnl` WDDM-минипорт,
не привязанный к PCI-видеокарте. Именно поэтому Microsoft и сделал IddCx; но spacedesk
делает свой WDDM-драйвер, значит обходимо.

**Дальше:**
- Тест в VirtualBox: установить, посмотреть, появляется ли 2-й монитор и расширяется ли стол.
- Если да — захватываем этот монитор (сначала внешне нашим `ScreenCapture`, потом интегрированно
  из драйвера через shared memory) → в готовый HEVC-тракт.

## Запасной путь без драйвера
Карта захвата UGREEN **CM489** (HDMI-выход ноута → CM489 отдаёт EDID → реальный 2-й монитор)
или дешёвая **HDMI-заглушка**. Тогда драйвер не нужен вообще, сверху — наш HEVC-тракт.
