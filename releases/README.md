# Releases

Собранные артефакты проекта. **Бинарники в git не хранятся** (см. `.gitignore`) — они
публикуются через [GitHub Releases](https://github.com/layfhaker/second-display/releases).
Эта папка — только локальная площадка для сборки перед публикацией.

## Что здесь лежит

| Файл / Папка | Что это |
|---|---|
| `SecondDisplay-CSharp-Setup-1.0.0.exe` | Единый мультиязычный установщик хоста на **C# (.NET 8)** |
| `SecondDisplay-HolyC-Setup-1.0.0.exe`  | Единый мультиязычный установщик хоста на **HolyC** |
| `SecondDisplay-Asm-Setup-1.0.0.exe`    | Единый мультиязычный установщик хоста на **чистом Assembly (x64)** |
| `SecondDisplay-Rust-Setup-1.0.0.exe`   | Единый мультиязычный установщик хоста на **Rust** |
| `android/app-debug.apk`                | Android-клиент (debug APK) |

## Как собрать установщики (Windows)

Сборка всех 4 установщиков (или конкретного):

```powershell
# Собрать все 4 установщика:
powershell -ExecutionPolicy Bypass -File scripts\build-installers.ps1

# Либо собрать конкретный движок хоста:
powershell -ExecutionPolicy Bypass -File scripts\build-installers.ps1 -Target CSharp
powershell -ExecutionPolicy Bypass -File scripts\build-installers.ps1 -Target HolyC
powershell -ExecutionPolicy Bypass -File scripts\build-installers.ps1 -Target Asm
powershell -ExecutionPolicy Bypass -File scripts\build-installers.ps1 -Target Rust
```

Каждый установщик является **мультиязычным** (автоматически определяет системный язык Windows и предлагает выбор Русский / English), содержит встроенный сертификат драйвера VDD, Android APK и инструменты ADB.

Требования: Rust toolchain, JDK 17 + Android SDK + Gradle, Inno Setup 6
(`winget install JRSoftware.InnoSetup`). Пути ищутся автоматически; можно задать
`-SdkDir`, `-JavaHome`, `-GradleExe`, `-Iscc`.

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
