# Releases

Собранные артефакты проекта. **Бинарники в git не хранятся** (см. `.gitignore`) — они
публикуются через [GitHub Releases](https://github.com/layfhaker/second-display/releases).
Эта папка — только локальная площадка для сборки перед публикацией.

## Что здесь лежит

| Путь | Что это |
|------|---------|
| `host/` | Хост для Windows (.NET 8): `SecondDisplay.Host.exe` + зависимости |
| `android/app-debug.apk` | Android-клиент (debug APK) |

## Как собрать

```powershell
# Хост
dotnet publish "host\SecondDisplay.Host\SecondDisplay.Host.csproj" -c Release -o "releases\host"

# Android-клиент (нужны JDK 17 + Android SDK; путь к SDK — в android\SecondDisplay\local.properties)
# Проект без gradle-wrapper, поэтому собираем установленным Gradle или через Android Studio:
gradle -p android\SecondDisplay :app:assembleDebug
copy android\SecondDisplay\app\build\outputs\apk\debug\app-debug.apk releases\android\
```

## Как собрать установщик (Windows)

Одна команда собирает хост, APK, кладёт `adb` и компилирует установщик в `releases/`:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-release.ps1 -Version 1.0.0
# -> releases\SecondDisplay-Setup-1.0.0.exe       (мультиязычный: ru+en)
# -> releases\SecondDisplay-Setup-1.0.0-ru.exe     (только русский)
# -> releases\SecondDisplay-Setup-1.0.0-en.exe     (только английский)
```

Сборщик компилирует **по установщику на каждый язык** (Inno подстановки `/DLangRu` / `/DLangEn`;
без них — один мультиязычный), все кладутся в `releases/`.

Что делает `scripts\build-release.ps1`:
1. `dotnet publish` хоста (self-contained win-x64 по умолчанию) → `build\staging\host`;
2. собирает Android-клиент (Gradle `:app:assembleDebug`) → `build\staging\android\app-debug.apk`;
3. кладёт `adb.exe` + 2 DLL в `build\staging\platform-tools`;
4. компилирует Inno Setup-скрипт `installer\SecondDisplay.iss` → `releases\SecondDisplay-Setup-<ver>.exe`.

Требования: .NET SDK, JDK 17 + Android SDK + Gradle, Inno Setup 6
(`winget install JRSoftware.InnoSetup`). Пути ищутся автоматически; можно задать
`-SdkDir`, `-JavaHome`, `-GradleExe`, `-Iscc`, `-SelfContained:$false`.

Что делает установщик (`installer\SecondDisplay.iss` + `installer\seconddisplay-setup.ps1`):
- ставит хост в **`%ProgramFiles%\SecondDisplay`** (x64);
- кладёт рядом **`platform-tools\adb.exe`** (хост предпочитает его adb из PATH);
- регистрирует автозапуск — задачу `SecondDisplayHost` (`--auto`, при входе, `Highest`);
- **обязательно** ставит клиент на подключённый планшет: `adb install -r app-debug.apk`
  (если планшета нет — установщик предупредит и покажет команду для повторного запуска);
- хост пишет рантайм-лог в **`%LOCALAPPDATA%\SecondDisplay\host.log`**, установщик — в
  `%LOCALAPPDATA%\SecondDisplay\install.log`.

## Как выложить релиз на GitHub

```powershell
git tag -a v0.1 -m "v0.1"
git push origin v0.1

gh release create v0.1 `
  "releases\host\SecondDisplay.Host.exe" `
  "releases\android\app-debug.apk" `
  --title "v0.1" `
  --notes-file releases\README.md
```

## Журнал релизов

### v0.1 — 2026-09-19

Планшет как второй монитор по USB: виртуальный дисплей **MttVDD** → capture **DXGI Desktop
Duplication** → аппаратный **HEVC (Intel QuickSync)** → `adb reverse` → декод **MediaCodec** в
Surface. Тач/клавиатура планшета идут обратно и инъектятся как мышь/клавиши.

Что вошло:

- **Хост**
  - Гейт готовности больше **не требует MTP/PTP**: планшет в режиме «только adb» запускает стрим
    сразу (раньше хост ждал бесконечно).
  - **Heartbeat `PING`** каждые 2 с, пока нет видео — клиент переживает столл/пересоздание
    энкодера без реконнект-шторма.
  - Порог watchdog энкодера **6 → 12 с** (не убиваем «просто медленный» iGPU-энкодер).
  - Короткие таймауты `adb` (devices 3 с, shell 6 с, `reverse --remove` 3 с) и более быстрый
    рестарт adb-сервера.
- **Клиент**
  - Самовосстановление при зависании декодера (кадры идут, рендера нет) и при тихой смерти
    потока декодирования.
  - Устранён цикл реконнектов, который пересоздавал SurfaceView/кодек и давал мигание чёрным.

Артефакты: `releases/host/*` и `releases/android/app-debug.apk`.
