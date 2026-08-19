# Что нужно установить (Windows 11)

**Visual Studio (IDE) НЕ нужен.** Обходимся командной строкой и Android Studio.

## Для Фазы 1 и 2 (картинка на планшете + тач) — только это:

### 1. .NET 8 SDK  (командная строка, не IDE)
- Маленький, не страшный. Даёт команду `dotnet` (`dotnet build`, `dotnet run`).
- Код редактируется обычными файлами — IDE открывать не нужно.
- Скачать: https://dotnet.microsoft.com/download/dotnet/8.0  → «SDK x64» для Windows.
- Проверка: `dotnet --list-sdks`  (должна появиться строка 8.x.x)

### 2. Android Studio  (это НЕ Visual Studio — другой продукт, от Google)
- Даёт Android SDK и **adb**.
- adb окажется в `%LOCALAPPDATA%\Android\Sdk\platform-tools` — добавить в PATH.
- Скачать: https://developer.android.com/studio
- Проверка: `adb version`

### 3. На планшете OPPO Pad 3 Pro
- Настройки → О планшете → тапнуть «Номер сборки» 7 раз → включатся «Параметры разработчика».
- В параметрах разработчика → включить «Отладка по USB».
- Подключить к ноуту (через хаб), подтвердить отпечаток ключа ПК.
- Проверка на ПК: `adb devices`  (должно показать устройство).

---

## Для Фазы 3 (драйвер виртуального дисплея) — ПОТОМ, и тоже без Visual Studio:

### EWDK (Enterprise WDK) — самодостаточный, командная строка
- ISO-образ: монтируешь, запускаешь `LaunchBuildEnv.cmd`, собираешь `msbuild`-ом.
- НЕ требует установки Visual Studio.
- **Прямая ссылка (Win11 26H1 EWDK, май 2026, VS BuildTools 18.3.0):**
  https://go.microsoft.com/fwlink/?LinkId=2362109
- Страница-источник: https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk
- Установленный отдельно Windows SDK 10.0.26100 не обязателен — EWDK самодостаточен.
- Использование: смонтировать ISO → `LaunchBuildEnv.cmd` → `msbuild` драйвера.

### Тестовый режим Windows (на время разработки драйвера)
Неподписанный IDD-драйвер грузится только так:
```
bcdedit /set testsigning on      # нужна перезагрузка
bcdedit /set testsigning off      # выключить обратно
```
Для релиза — аттестационная подпись через Microsoft Partner Center.

---

## Итог: для старта (Фаза 1) ставим ТОЛЬКО
1. .NET 8 SDK
2. Android Studio
3. Включаем USB-отладку на планшете

Никакого Visual Studio.
