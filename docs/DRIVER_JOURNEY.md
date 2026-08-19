# Фаза 3: драйвер виртуального дисплея — полная хронология и находки

> **РЕШЕНО (2026-06-25):** свой драйвер из EWDK 28000 — тупик (см. ниже), поэтому взяли **готовый
> подписанный драйвер VirtualDrivers/Virtual-Display-Driver (MttVDD)** — встал на хост, виртуальный
> дисплей работает, поток на планшет идёт (нативное 4К @ ~50 fps). Этот документ — история СВОЕГО
> драйвера: ценен выводом «IddCx исправен, тулчейн EWDK 28000 несовместим с IddCx 1.2 этой ОС» и
> рецептом на будущее (старый WDK). Детали решения — `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`.

Документ фиксирует весь путь по драйверу (он был длинным и извилистым), чтобы можно было
продолжить с любого места и не повторять тупики. Состояние на 2026-06-24 (сага своего драйвера).

## TL;DR текущего состояния
- **IddCx в системе ЕСТЬ** (ранняя ошибка: искали `IddCx.sys`, а это `IddCx.dll` в
  `C:\Windows\System32\drivers\UMDF\IddCx.dll`, версия 10.0.26100.4202).
- **Наш IddCx-драйвер собирается и ЗАГРУЖАЕТСЯ** (на родной версии кита UMDF 2.35).
- **ТУПИК EWDK 28000 (окончательно, 2026-06-25):** проверены все комбинации. 2.35+IddCx1.2 на
  чистой VM крашится `ReportDdiFunctionCountMismatch` — так же, как 1.11. Сборки 2.15–2.33 не
  грузятся (`0xD000000D`). EWDK 28000 объявляет иное число IddCx-DDI, чем рантайм 1.2 этой ОС.
  **Нужен старый WDK** (≈10.0.16299/17134, эпоха IddCx 1.2). См. матрицу версий ниже.
- **Рабочий продукт уже есть:** HEVC-зеркало по USB (фазы 1/2). Расширение — за драйвером.

## Хронология подходов

### Подход 1 — свой IddCx-драйвер (UMDF)
`driver/SecondDisplayIdd/`. Собран, подписан, ставится. Долго не грузился:
- Сначала думали «IddCx вырезан из обрезанной Windows» — **это была ошибка диагностики**
  (искали `IddCx.sys` вместо `IddCx.dll`). IddCx на месте.
- `0xC000007B (INVALID_IMAGE_FORMAT)` был из-за **версионных костылей** (форсили IddCx 1.11 на
  UMDF 2.23 поддельным `typedef WDF_STRUCT_INFO`). После чистой сборки без костылей — грузится.

### Подход 2 — свой WDDM display-only драйвер (KMDOD) — ТУПИК
`driver/wds-tmp/video/KMDOD/`. Делали, пока ошибочно считали, что IddCx нет.
- Собрали (на базе Microsoft KMDOD sample), виртуализировали (свой режим + RAM-фреймбуфер +
  root INF). Нашли и починили реальный баг образца KMDOD: `operator new` в `memory.cxx`
  передавал `POOL_TYPE` в `ExAllocatePool2` (который ждёт `POOL_FLAGS`) → NULL → NO_MEMORY.
- **Уперлись в `STATUS_NOT_SUPPORTED` от dxgkrnl** до вызова StartDevice: dxgkrnl не запускает
  display-only минипорт на root-устройстве без аппаратных ресурсов. Это и есть причина, по
  которой Microsoft сделал IddCx. → KMDOD-путь закрыт.

## Точные технические находки (важно!)

### IddCx / UMDF версии этой ОС (Win11 26200, host И чистый ISO одинаково)
- Реестр: `HKLM\SYSTEM\CCS\Control\Wdf\Umdf\2` → `Version 2.15`;
  `...\Wdf\Umdf\IddCx\Versions\1\2` → `Service IddCx0102` (= IddCx 1.2).
- Это **минимальные/базовые** регистрации; рантайм (`IddCx.dll`, `WUDFx02000.dll`) — свежий 26100.

### Эталон Microsoft — как должен выглядеть IddCx-драйвер на этой ОС
`C:\Windows\INF\rdpidd.inf` (RDP Indirect Display) и `miradisp.inf` (Miracast):
```
UmdfService = RdpIdd,RdpIdd_Install
UmdfServiceOrder = RdpIdd
UmdfLibraryVersion = 2.15.0        ; miradisp: 2.0.0
UmdfExtensions = IddCx0102         ; <- КРИТИЧНО, у нас этого не было
```
`UmdfExtensions = IddCx0102` — директива, грузящая class extension IddCx 1.2. Добавлена в наш INF.

### `WDF_STRUCT_INFO`
Реальное определение (`wdf/umdf/2.33/wdftypes.h:80`): `typedef size_t* WDF_STRUCT_INFO;`.
В заголовках UMDF < 2.25 его нет. «Подделка» агента была КОРРЕКТНОЙ (= реальному определению),
не она ломала бинарник.

### Матрица версий (что пробовали в VM)
| UMDF | IddCx | UmdfExtensions | Результат |
|------|-------|----------------|-----------|
| 2.35 | 1.11  | нет            | грузится, рантайм-краш `ReportDdiFunctionCountMismatch` (IddCx 1.11≠1.2) |
| 2.33 | 1.10  | нет            | НЕ грузится, WUDF 2007 `0xD000000D` |
| 2.25 | 1.2   | IddCx0102      | НЕ грузится, `0xD000000D` |
| 2.15 | 1.2   | IddCx0102      | НЕ грузится, `0xD000000D` |
| 2.35 | 1.2   | IddCx0102      | **грузится, рантайм-краш `ReportDdiFunctionCountMismatch`** (то же, что 2.35/1.11) |

### ОКОНЧАТЕЛЬНО проверено на чистой VM (2026-06-25)
После обновления VM до build 26200 UBR 8037, с корректным elevated-доступом (`EnableLUA=0`,
testsigning on, сертификат доверен) комбинация **2.35 + IddCx 1.2** была установлена начисто
(oem5.inf, devgen-устройство, привязка через повторный `pnputil /install` уже на présent-устройстве)
и **однозначно падает**: устройство `CM_PROB_FAILED_ADD`, `ProblemStatus=0xC0000701` (хост убит).
WUDF: `2010`(загружен)→`2004`/`2005`→`4000`(Laufzeitfehler)→`1009 Problem 8`. WER:
`VerifierFailure / fxlibrarycommon.cpp:261(ReportDdiFunctionCountMismatch)`, `Driver=SecondDisplayIdd.dll`,
`UMDFVersion=2.35.0`. **Тот же краш, что у 1.11** — несмотря на `IDDCX_VERSION 1.2` + `iddcx\1.2` stub.

**ВЫВОД (не гипотеза):** заголовки/стабы IddCx в **EWDK 28000 объявляют иное число DDI-функций**,
чем рантайм IddCx 1.2 этой ОС, поэтому ЛЮБАЯ сборка из EWDK 28000 не годится: либо не грузится
(нижние UMDF → `0xD000000D`), либо грузится и крашится (`ReportDdiFunctionCountMismatch`).
**Единственный путь к рабочему IddCx-драйверу — старый WDK** эпохи IddCx 1.2 (≈WDK 10.0.16299/17134),
собрать ровно по рецепту `rdpidd` (UMDF 2.15 + IddCx 1.2 + `UmdfExtensions=IddCx0102`). Запасной
путь без драйвера — железо CM489.

### Заметки по тестовому стенду (важно для следующего раза)
- Обновление Windows в VM **сбрасывает** `EnableLUA` в 1 и testsigning в off → guestcontrol теряет
  админ-токен (`Device creation 0x5`, импорт cert `Zugriff verweigert`). Лечится elevated-запуском
  `idd_fixsec.ps1` (вернуть EnableLUA=0 + testsigning on + доверить cert + reboot).
- `keyboardputstring` НЕ годится для ввода команд: гость на немецкой раскладке, US-скан-коды
  искажают `-\:"` и Y/Z. Для elevated-действия нужен либо GUI-вход пользователя, либо EnableLUA=0.
- `devgen /add` создаёт устройство с GUID-instance (`ROOT\DEVGEN\{...}`), НЕ `ROOT\DEVGEN\SECONDIDD`.
  Привязка драйвера: `pnputil /add-driver inf /install` нужно запускать ПОСЛЕ создания устройства.
- После обновления/ребута UMDF execution service VBox guestcontrol поднимается только после полного
  `controlvm reset` (на runlevel 3 сам по себе «not ready»).

## Тестовый стенд (полностью автоматизирован)
- VM «SecondDisplayTest» в VirtualBox (Win11 26200, чистый официальный ISO).
- Управление с хоста через `VBoxManage guestcontrol` (юзер admin/admin).
- В госте: `EnableLUA=0` (чтобы guestcontrol получал админ-токен), `testsigning on`,
  тест-сертификат 473B... доверен, общий буфер обмена.
- Скрипты диагностики в `C:\idd-dist\` (idd_check.ps1, idd_diag.ps1, pcheck.ps1 и т.п.).
- Установка драйвера: `pnputil /add-driver ... /install` + `devgen /add /bus ROOT
  /hardwareid Root\SecondDisplayIdd`. ВНИМАНИЕ: многократные remove/add замусоривают PnP
  (дубли oem*.inf, слетающая привязка, `0xE0000207`) — для чистого теста нужна свежая VM/снапшот.

## Сборка драйвера (EWDK)
```
cmd /c "set ""PATH=C:\Program Files (x86)\Microsoft Visual Studio\Installer;%PATH%"" && ^
  call D:\BuildEnv\SetupBuildEnv.cmd amd64 && ^
  msbuild ""...\SecondDisplayIdd.vcxproj"" /p:Configuration=Release /p:Platform=x64"
```
EWDK ставит `VSCMD_ARG_winsdk=none` → пути к киту прописаны в vcxproj явно
(`D:\Program Files\Windows Kits\10`, версия 10.0.28000.0).

## Следующие шаги (по приоритету)
1. **Старый WDK** (≈10.0.16299) → собрать IddCx-драйвер ровно по рецепту `rdpidd`
   (UMDF 2.15 + IddCx 1.2 + UmdfExtensions=IddCx0102), нативно, без костылей → должен грузиться.
2. Или **kernel/UMDF-отладчик** (kd есть в EWDK) → декодировать `0xD000000D` точно.
3. Перед тестом — **свежая VM** (текущая замусорена циклами установки).
4. Запасной путь без драйвера: **железо CM489** (HDMI→карта захвата = реальный 2-й монитор) +
   наш HEVC-тракт. Даёт расширение сегодня.
5. Радикально-чистый: переустановка официальной Windows → IddCx-драйвер на родной версии.
