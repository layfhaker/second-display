# Установка SecondDisplay-драйвера (режим разработки)

> ⚠️ **ИСТОРИЧЕСКОЕ / УСТАРЕЛО.** Это шаги установки НАШЕГО драйвера (тупик, EWDK 28000). Сейчас
> используется готовый **MttVDD** — ставится официальным `vdd-readymade/VDD-setup-x64.exe`,
> разрешение — `vdd-readymade/apply_vdd_resolution.cmd`. См. `docs/ARCHITECTURE.md` / `docs/ROADMAP.md`.

Пакет: `driver/dist/` — подписаны тест-сертификатом `SecondDisplayIdd.dll` + `seconddisplayidd.cat`,
проштампован `SecondDisplayIdd.inf`, сертификат `SecondDisplayTest.cer`, `devgen.exe`.

> Все шаги ниже — от **администратора**. Текущая сессия Claude НЕ админская, поэтому
> их выполняешь ты вручную (открой PowerShell от имени администратора).

## ⚠️ Перед началом: Secure Boot
Тестовый режим (`testsigning`) **игнорируется при включённом Secure Boot**. Нужно выключить
Secure Boot в BIOS. Если включён **BitLocker** — сначала приостанови его, иначе при смене
Secure Boot система запросит ключ восстановления:
```
manage-bde -protectors -disable C: -RebootCount 2
```
(если BitLocker не включён — пропусти этот шаг).

Затем: перезагрузка → BIOS/UEFI (на Zenbook обычно F2 при старте) → Security/Boot →
**Secure Boot = Disabled** → сохранить и выйти.

## Шаг 1. Включить тестовый режим
В админском PowerShell:
```
bcdedit /set testsigning on
```
Перезагрузиться. После этого в правом нижнем углу появится водяной знак «Test Mode» — это норма.

## Шаг 2. Доверить тест-сертификат
```
$cer = "C:\Users\admin\Documents\second display\driver\dist\SecondDisplayTest.cer"
certutil -addstore -f root "$cer"
certutil -addstore -f trustedpublisher "$cer"
```

## Шаг 3. Установить драйвер
```
pnputil /add-driver "C:\Users\admin\Documents\second display\driver\dist\SecondDisplayIdd.inf" /install
```

## Шаг 4. Создать виртуальное устройство
```
& "C:\Users\admin\Documents\second display\driver\dist\devgen.exe" /add /instanceid SECONDDISP /hardwareid Root\SecondDisplayIdd
```
После этого в «Параметры → Система → Дисплей» должен появиться **второй монитор**
(SecondDisplay Virtual Monitor). Выбери «Расширить эти экраны».

## Проверка
- `Get-PnpDevice -FriendlyName "*SecondDisplay*"` — статус OK.
- В диспетчере устройств → Display adapters/Мониторы появится наше устройство.

## Откат
```
& "...\devgen.exe" /remove /instanceid SECONDDISP   # либо через диспетчер устройств
pnputil /delete-driver SecondDisplayIdd.inf /uninstall /force
bcdedit /set testsigning off
```
(и при желании вернуть Secure Boot в BIOS).

## Если устройство с ошибкой (Code 10/43/52)
- Code 52 → сертификат/тестовый режим не подхватились (проверь Secure Boot off + testsigning on + cert в root/trustedpublisher).
- Иное → смотрим журнал: `Get-WinEvent -LogName "Microsoft-Windows-DriverFrameworks-UserMode/Operational"` — и я правлю драйвер.
