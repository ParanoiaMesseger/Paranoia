# Сборка libopus для мобильных платформ

VoIP-стек Paranoia требует `libopus`. Системного `libopus` на Android/iOS нет — нужно cross-скомпилировать и положить в `ParanoiaUiClient/deps/opus/<platform-tag>/`. CMake автоматически подхватит prebuilt и включит VoIP-блок (`PARANOIA_HAS_VOIP=1`).

Сборка автоматизирована скриптами:
- **Android**: `scripts/build_opus_android.sh`
- **iOS**:     `scripts/build_opus_ios.sh`

`build_android.sh` вызывает Android-скрипт сам. GitLab CI (`.gitlab-ci.yml`) вызывает оба и кеширует артефакты.

## Layout

```
ParanoiaUiClient/deps/opus/
    arm64-v8a/      ← Android arm64-v8a
    armeabi-v7a/    ← Android armeabi-v7a
    x86_64/         ← Android x86_64 (эмулятор)
    x86/            ← Android x86 (эмулятор)
    ios-arm64/      ← iOS device arm64
    iossim-arm64/   ← iOS simulator arm64 (Apple Silicon)
    iossim-x86_64/  ← iOS simulator x86_64 (Intel)
```

Каждая папка содержит `include/opus/*.h` + `lib/libopus.a`.

## Android — ручной запуск

```bash
ANDROID_NDK_ROOT=$HOME/.android/sdk/ndk/27.2.12479018 \
OPUS_ABIS="arm64-v8a armeabi-v7a x86_64 x86" \
  ./scripts/build_opus_android.sh
```

`OPUS_ABIS` через пробел; по умолчанию только `arm64-v8a` (то, что нужно для production-APK). Можно собрать инкрементально — скрипт пропускает уже собранные ABI (проверяет наличие `lib/libopus.a`). Чтобы пересобрать: `FORCE_REBUILD=1` или удалите целевую папку.

## iOS — ручной запуск (только на macOS)

```bash
# Для устройства:
./scripts/build_opus_ios.sh
# Для симулятора Apple Silicon:
OPUS_IOS_SDK=iphonesimulator OPUS_IOS_ARCHS=arm64 ./scripts/build_opus_ios.sh
# Для симулятора Intel:
OPUS_IOS_SDK=iphonesimulator OPUS_IOS_ARCHS=x86_64 ./scripts/build_opus_ios.sh
```

## Desktop

- **Linux**: `apt-get install libopus-dev` (Ubuntu 24.04 = opus 1.4) — CMake найдёт через pkg-config.
- **macOS**: `brew install opus` — `find_package(Opus)` или pkg-config подхватит.
- **Windows**: `vcpkg install opus`, затем сконфигурируйте проект с `-DCMAKE_TOOLCHAIN_FILE=<vcpkg>/scripts/buildsystems/vcpkg.cmake`. Без vcpkg/opus VoIP-блок просто не соберётся (CMake выдаст `Paranoia VoIP: disabled`).

## CI

В `.gitlab-ci.yml`:
- `build:client:linux` — apt установка `libopus-dev` в `before_script`.
- `build:client:android` — вызов `scripts/build_opus_android.sh` после установки NDK; кеш `ParanoiaUiClient/deps/opus/` под ключом `opus-android-1.5.2-<NDK>`.
- `build:client:macos` — `brew install opus` в общем `.apple_shell_setup`.
- `build:client:ios` — вызов `scripts/build_opus_ios.sh` перед cmake; кеш `opus-ios-1.5.2`.
- `build:client:windows` — опционально через переменную `VCPKG_ROOT`.

## Проверка

В выводе CMake configure ожидаем:
```
-- Paranoia VoIP: using prebuilt opus (android-arm64-v8a) at .../deps/opus/arm64-v8a
-- Paranoia VoIP: enabled (libopus + Qt Multimedia)
```
Если вместо этого:
```
-- Paranoia VoIP: no prebuilt opus (android-arm64-v8a) at ...
-- Paranoia VoIP: disabled (HAS_OPUS=0 HAS_MULTIMEDIA=1)
```
— значит скрипт не отработал или артефакты лежат не там, где ожидается. См. log сборки `build_opus_*.sh` и убедитесь, что `libopus.a` действительно создан.
