cmake_minimum_required(VERSION 3.20)

project(ParanoiaUiClient VERSION 0.2.14 LANGUAGES C CXX)

set(PARANOIA_PLATFORM "")
set(PARANOIA_IS_MOBILE 0)
set(PARANOIA_IS_DESKTOP 0)

set(PARANOIA_IS_ANDROID 0)
set(PARANOIA_IS_IOS 0)
set(PARANOIA_IS_MAC 0)
set(PARANOIA_IS_LINUX 0)
set(PARANOIA_IS_WINDOWS 0)

# ── Platform detection ───────────────────────────────────────────────
if(ANDROID)
    set(PARANOIA_IS_MOBILE 1)
    set(PARANOIA_IS_ANDROID 1)
    set(PARANOIA_PLATFORM "ANDROID")
elseif(IOS OR CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(PARANOIA_IS_MOBILE 1)
    set(PARANOIA_IS_IOS 1)
    set(PARANOIA_PLATFORM "IOS")
elseif(WIN32)
    set(PARANOIA_IS_DESKTOP 1)
    set(PARANOIA_IS_WINDOWS 1)
    set(PARANOIA_PLATFORM "WINDOWS")
elseif(APPLE)
    set(PARANOIA_IS_DESKTOP 1)
    set(PARANOIA_IS_MAC 1)
    set(PARANOIA_PLATFORM "MAC")
elseif(UNIX)
    set(PARANOIA_IS_DESKTOP 1)
    set(PARANOIA_IS_LINUX 1)
    set(PARANOIA_PLATFORM "LINUX")
else()
    message(WARNING "Unknown target platform: ${CMAKE_SYSTEM_NAME}")
endif()

message(STATUS "Paranoia platform: (mobile=${PARANOIA_IS_MOBILE} desktop=${PARANOIA_IS_DESKTOP})")

set(PARANOIA_APP_VERSION "${PROJECT_VERSION}")
math(EXPR PARANOIA_ANDROID_VERSION_CODE
    "${PROJECT_VERSION_MAJOR} * 10000 + ${PROJECT_VERSION_MINOR} * 100 + ${PROJECT_VERSION_PATCH}"
)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(PARANOIA_BETA_LOGGING 0)
set(PARANOIA_ENABLE_HUNSPELL 1)
set(PARANOIA_DEFAULT_STUN_SERVER "" CACHE STRING "Default STUN server for VoIP media, e.g. host:port")
set(PARANOIA_QT_COMPONENTS Quick Concurrent QuickControls2 QuickDialogs2 QuickLayouts Svg Network LabsSettings LinguistTools)

if(PARANOIA_IS_DESKTOP)
    list(APPEND PARANOIA_QT_COMPONENTS Widgets)
endif()

find_package(Qt6 REQUIRED COMPONENTS ${PARANOIA_QT_COMPONENTS})
set(PARANOIA_HAS_QT_VIRTUAL_KEYBOARD 0)
set(PARANOIA_HAS_QT_MULTIMEDIA 0)
set(PARANOIA_HAS_HUNSPELL 0)
set(PARANOIA_HUNSPELL_TARGET "")
set(PARANOIA_OPTIONAL_QML_FILES)
set(PARANOIA_REQUIRES_QT_VIRTUAL_KEYBOARD OFF)

if(PARANOIA_IS_MOBILE)
    set(PARANOIA_REQUIRES_QT_VIRTUAL_KEYBOARD ON)
    list(APPEND PARANOIA_OPTIONAL_QML_FILES ui/Components/QrCameraPreview.qml)
endif()

find_package(Qt6 REQUIRED COMPONENTS Multimedia)
set(PARANOIA_HAS_QT_MULTIMEDIA 1)

# ── libopus (для VoIP) ───────────────────────────────────────────────
# На desktop (Linux/macOS/Windows) ищем через find_package(Opus) или
# pkg-config; на Linux/macOS можно поставить через системный пакетный
# менеджер (apt libopus-dev / brew install opus / vcpkg opus).
# На Android — prebuilt из deps/opus/<ANDROID_ABI>/{include,lib} (см.
# docs/build-android-opus.md и scripts/build_opus_android.sh).
# На iOS — prebuilt из deps/opus/ios-<arch>/ (scripts/build_opus_ios.sh).
# Если opus не найден И Qt::Multimedia доступен — voip-стек НЕ собирается;
# ядро (Rust-FFI) при этом всё равно доступно, но Qt-сторона звонка работать
# не будет.
set(PARANOIA_HAS_OPUS 0)
set(PARANOIA_OPUS_TARGET "")

function(_paranoia_try_prebuilt_opus root_dir tag)
    if(EXISTS "${root_dir}/include/opus/opus.h"
        AND EXISTS "${root_dir}/lib/libopus.a")
        add_library(paranoia_opus_prebuilt STATIC IMPORTED)
        set_target_properties(paranoia_opus_prebuilt PROPERTIES
            IMPORTED_LOCATION "${root_dir}/lib/libopus.a"
            INTERFACE_INCLUDE_DIRECTORIES "${root_dir}/include"
        )
        set(PARANOIA_HAS_OPUS 1 PARENT_SCOPE)
        set(PARANOIA_OPUS_TARGET paranoia_opus_prebuilt PARENT_SCOPE)
        message(STATUS "Paranoia VoIP: using prebuilt opus (${tag}) at ${root_dir}")
    else()
        message(STATUS "Paranoia VoIP: no prebuilt opus (${tag}) at ${root_dir}")
    endif()
endfunction()

function(_paranoia_resolve_ios_arch out_arch out_prefix)
    set(_arch "${CMAKE_OSX_ARCHITECTURES}")

    if(NOT _arch)
        set(_arch "arm64")
    endif()

    if("${CMAKE_OSX_SYSROOT}" MATCHES "iPhoneSimulator")
        set(${out_arch} "iossim-${_arch}" PARENT_SCOPE)
        set(${out_prefix} "iossim-${_arch}" PARENT_SCOPE)
    else()
        set(${out_arch} "ios-${_arch}" PARENT_SCOPE)
        set(${out_prefix} "ios-${_arch}" PARENT_SCOPE)
    endif()
endfunction()

if(PARANOIA_IS_ANDROID)
    _paranoia_try_prebuilt_opus(
        "${CMAKE_CURRENT_SOURCE_DIR}/deps/opus/${ANDROID_ABI}"
        "android-${ANDROID_ABI}")
elseif(PARANOIA_IS_IOS)
    _paranoia_resolve_ios_arch(_paranoia_ios_arch _paranoia_ios_prefix)
    _paranoia_try_prebuilt_opus(
        "${CMAKE_CURRENT_SOURCE_DIR}/deps/opus/${_paranoia_ios_arch}"
        "${_paranoia_ios_prefix}")
else()
    find_package(Opus QUIET)
    if(TARGET Opus::opus)
        set(PARANOIA_HAS_OPUS 1)
        set(PARANOIA_OPUS_TARGET Opus::opus)
    else()
        find_package(PkgConfig QUIET)
        if(PkgConfig_FOUND)
            pkg_check_modules(OPUS_PKG QUIET IMPORTED_TARGET opus)
            if(OPUS_PKG_FOUND)
                # opus.pc выдаёт -I.../include/opus, но код использует
                # #include <opus/opus.h> — нужен родительский каталог.
                get_filename_component(_opus_inc_fixed "${OPUS_PKG_INCLUDE_DIRS}" DIRECTORY)
                set_target_properties(PkgConfig::OPUS_PKG PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${_opus_inc_fixed}")
                set(PARANOIA_HAS_OPUS 1)
                set(PARANOIA_OPUS_TARGET PkgConfig::OPUS_PKG)
            endif()
        endif()
    endif()
endif()

set(PARANOIA_HAS_VOIP 0)

if(PARANOIA_HAS_OPUS AND PARANOIA_HAS_QT_MULTIMEDIA)
    set(PARANOIA_HAS_VOIP 1)
    message(STATUS "Paranoia VoIP: enabled (libopus + Qt Multimedia)")
else()
    message(STATUS "Paranoia VoIP: disabled (HAS_OPUS=${PARANOIA_HAS_OPUS} HAS_MULTIMEDIA=${PARANOIA_HAS_QT_MULTIMEDIA})")
endif()

# ── FFmpeg (для video-кодека) ─────────────────────────────────────────
# Нужны libavcodec (encoder/decoder), libavutil (общие типы), libswscale
# (конвертация YUV-форматов). libavformat НЕ нужен — мы работаем с raw NAL.
# Hardware-acceleration: libavcodec через свои hwaccel-имена кодеков
# (h264_videotoolbox/macOS, h264_mediacodec/Android, h264_vaapi/Linux,
# h264_nvenc/h264_qsv/Windows, h264_amf/AMD). Software fallback: libx264 (если
# собран в эту FFmpeg) или libavcodec native h264.
# На Linux/macOS: `apt install libavcodec-dev libavutil-dev libswscale-dev`
# или `brew install ffmpeg`.
# На Android/iOS: prebuilt из deps/ffmpeg/<target>/{include,lib} (см.
# scripts/build_ffmpeg_android.sh / build_ffmpeg_ios.sh).
# Если FFmpeg не найден — video отключается, голос работает.
set(PARANOIA_HAS_FFMPEG 0)
set(PARANOIA_FFMPEG_TARGETS "")

function(_paranoia_try_prebuilt_ffmpeg root_dir tag)
    # avfilter добавлен для нашего pipeline'а (transpose/scale/format/pad);
    # порядок важен для линковки: avfilter зависит от swscale/avutil/avcodec.
    set(_libs avfilter swscale avcodec avutil)
    set(_all_found TRUE)

    foreach(_lib ${_libs})
        if(NOT EXISTS "${root_dir}/lib/lib${_lib}.a")
            set(_all_found FALSE)
        endif()
    endforeach()

    if(NOT EXISTS "${root_dir}/include/libavcodec/avcodec.h")
        set(_all_found FALSE)
    endif()
    if(NOT EXISTS "${root_dir}/include/libavfilter/avfilter.h")
        set(_all_found FALSE)
    endif()

    if(_all_found)
        set(_targets)

        foreach(_lib ${_libs})
            set(_tgt "paranoia_ffmpeg_${_lib}_prebuilt")
            add_library(${_tgt} STATIC IMPORTED)
            set_target_properties(${_tgt} PROPERTIES
                IMPORTED_LOCATION "${root_dir}/lib/lib${_lib}.a"
                INTERFACE_INCLUDE_DIRECTORIES "${root_dir}/include"
            )
            list(APPEND _targets ${_tgt})
        endforeach()

        set(PARANOIA_HAS_FFMPEG 1 PARENT_SCOPE)
        set(PARANOIA_FFMPEG_TARGETS ${_targets} PARENT_SCOPE)
        message(STATUS "Paranoia video: using prebuilt FFmpeg (${tag}) at ${root_dir}")
    else()
        message(STATUS "Paranoia video: no prebuilt FFmpeg (${tag}) at ${root_dir}")
    endif()
endfunction()

if(PARANOIA_IS_ANDROID)
    _paranoia_try_prebuilt_ffmpeg(
        "${CMAKE_CURRENT_SOURCE_DIR}/deps/ffmpeg/${ANDROID_ABI}"
        "android-${ANDROID_ABI}")

    # OpenH264 (BSD) — обязательный software H.264 encoder для Android. FFmpeg
    # без него находит только декодер h264 (и иногда mediacodec), а encoder'а
    # нет — что и проявляется как «no usable H.264 encoder found» на устройстве.
    # libavcodec.a ссылается на символы WelsCreateSVCEncoder и т. п. — без
    # libopenh264.a линковка APK провалится с undefined reference.
    set(_paranoia_openh264_root "${CMAKE_CURRENT_SOURCE_DIR}/deps/openh264/${ANDROID_ABI}")

    if(PARANOIA_HAS_FFMPEG
        AND EXISTS "${_paranoia_openh264_root}/lib/libopenh264.a")
        add_library(paranoia_openh264_prebuilt STATIC IMPORTED)
        set_target_properties(paranoia_openh264_prebuilt PROPERTIES
            IMPORTED_LOCATION "${_paranoia_openh264_root}/lib/libopenh264.a"
            INTERFACE_INCLUDE_DIRECTORIES "${_paranoia_openh264_root}/include"

            # openh264 — C++; C++ runtime подбирается Android NDK toolchain'ом
            # (libc++_shared при ANDROID_STL=c++_shared). Здесь явно не
            # подтягиваем, чтобы не дублировать; финальный APK link это сделает.
        )
        list(APPEND PARANOIA_FFMPEG_TARGETS paranoia_openh264_prebuilt)
        message(STATUS "Paranoia video: linking OpenH264 from ${_paranoia_openh264_root}")
    elseif(PARANOIA_HAS_FFMPEG)
        message(WARNING "Paranoia video: OpenH264 prebuilt not found at ${_paranoia_openh264_root}; H.264 encoding will fail on this Android build. Run scripts/build_openh264_android.sh.")
    endif()
elseif(PARANOIA_IS_IOS)
    _paranoia_resolve_ios_arch(_paranoia_ios_arch _paranoia_ios_prefix)
    _paranoia_try_prebuilt_ffmpeg(
        "${CMAKE_CURRENT_SOURCE_DIR}/deps/ffmpeg/${_paranoia_ios_arch}"
        "${_paranoia_ios_prefix}")
else()
    # Desktop: сначала пробуем СВОЙ минимальный статический FFmpeg+OpenH264
    # (scripts/build_ffmpeg_linux.sh → deps/ffmpeg/linux-<arch>). Это делает
    # бинарь независимым от системного FFmpeg и переносимым между дистрибутивами
    # (на Ubuntu 22.04 системный FFmpeg 4.4, на 24.04 — 6.x). Если prebuilt'а
    # нет — откатываемся на системный FFmpeg через find_package/pkg-config ниже.
    if(PARANOIA_IS_LINUX)
        string(TOLOWER "linux-${CMAKE_SYSTEM_PROCESSOR}" _paranoia_linux_tag)
        _paranoia_try_prebuilt_ffmpeg(
            "${CMAKE_CURRENT_SOURCE_DIR}/deps/ffmpeg/${_paranoia_linux_tag}"
            "${_paranoia_linux_tag}")

        set(_paranoia_openh264_root "${CMAKE_CURRENT_SOURCE_DIR}/deps/openh264/${_paranoia_linux_tag}")
        if(PARANOIA_HAS_FFMPEG AND EXISTS "${_paranoia_openh264_root}/lib/libopenh264.a")
            # libavcodec.a ссылается на символы OpenH264 (WelsCreateSVCEncoder
            # и т. п.) — без libopenh264.a будет undefined reference при линковке.
            add_library(paranoia_openh264_prebuilt STATIC IMPORTED)
            set_target_properties(paranoia_openh264_prebuilt PROPERTIES
                IMPORTED_LOCATION "${_paranoia_openh264_root}/lib/libopenh264.a"
                INTERFACE_INCLUDE_DIRECTORIES "${_paranoia_openh264_root}/include"
                # Статический FFmpeg тянет libm; libstdc++ (нужен OpenH264)
                # подцепится автоматически — Paranoia линкуется через g++.
                # openh264 идёт последним в списке таргетов → m окажется в конце.
                INTERFACE_LINK_LIBRARIES "m"
            )
            list(APPEND PARANOIA_FFMPEG_TARGETS paranoia_openh264_prebuilt)
            message(STATUS "Paranoia video: linking OpenH264 (static) from ${_paranoia_openh264_root}")
        elseif(PARANOIA_HAS_FFMPEG)
            message(WARNING "Paranoia video: prebuilt FFmpeg found but OpenH264 missing at ${_paranoia_openh264_root}; H.264 encode будет недоступен. Run scripts/build_openh264_linux.sh.")
        endif()
    endif()

    if(NOT PARANOIA_HAS_FFMPEG)
    find_package(FFMPEG COMPONENTS avcodec avutil avfilter swscale QUIET)

    # FFMPEG_FOUND ещё не гарантирует, что созданы imported targets — в Qt6.10
    # /Homebrew окружении на macOS FindFFMPEG.cmake часто рапортует FOUND по
    # найденным .dylib, но FFMPEG::avcodec/avutil/swscale не регистрирует.
    # Без явного TARGET-чека дальше уйдём в target_link_libraries с несуществующим
    # таргетом и упадём (gitlab job 2951). Проверяем все четыре — иначе откатываемся
    # на pkg-config fallback ниже.
    if(FFMPEG_FOUND AND TARGET FFMPEG::avcodec AND TARGET FFMPEG::avutil
            AND TARGET FFMPEG::avfilter AND TARGET FFMPEG::swscale)
        set(PARANOIA_HAS_FFMPEG 1)
        set(PARANOIA_FFMPEG_TARGETS FFMPEG::avfilter FFMPEG::swscale FFMPEG::avcodec FFMPEG::avutil)
    endif()

    find_package(PkgConfig QUIET)

    if(NOT PARANOIA_HAS_FFMPEG AND PkgConfig_FOUND)
        pkg_check_modules(LIBAVCODEC QUIET IMPORTED_TARGET libavcodec)
        pkg_check_modules(LIBAVUTIL QUIET IMPORTED_TARGET libavutil)
        pkg_check_modules(LIBSWSCALE QUIET IMPORTED_TARGET libswscale)
        pkg_check_modules(LIBAVFILTER QUIET IMPORTED_TARGET libavfilter)

        if(LIBAVCODEC_FOUND AND LIBAVUTIL_FOUND AND LIBSWSCALE_FOUND AND LIBAVFILTER_FOUND)
            set(PARANOIA_HAS_FFMPEG 1)
            set(PARANOIA_FFMPEG_TARGETS
                PkgConfig::LIBAVFILTER PkgConfig::LIBSWSCALE PkgConfig::LIBAVCODEC PkgConfig::LIBAVUTIL)
        endif()
    endif()
    endif() # NOT PARANOIA_HAS_FFMPEG — системный FFmpeg как fallback
endif()

set(PARANOIA_HAS_VIDEO 0)

if(PARANOIA_HAS_VOIP AND PARANOIA_HAS_FFMPEG)
    set(PARANOIA_HAS_VIDEO 1)
    message(STATUS "Paranoia video: enabled (FFmpeg + Qt Multimedia)")
else()
    message(STATUS "Paranoia video: disabled (HAS_VOIP=${PARANOIA_HAS_VOIP} HAS_FFMPEG=${PARANOIA_HAS_FFMPEG})")
endif()

if(PARANOIA_IS_MOBILE)
    find_package(Qt6 REQUIRED COMPONENTS VirtualKeyboard)
    set(PARANOIA_HAS_QT_VIRTUAL_KEYBOARD 1)
    list(APPEND PARANOIA_OPTIONAL_QML_FILES ui/Components/VirtualKeyboardPanel.qml)
endif()

if(PARANOIA_IS_IOS)
    enable_language(OBJCXX)
endif()

if(PARANOIA_ENABLE_HUNSPELL)
    if(PARANOIA_IS_IOS)
        # На iOS: prebuilt из deps/hunspell/ios-<arch>/ (scripts/build_hunspell_ios.sh).
        # pkg_check_modules нельзя использовать при cross-compile — host pkg-config
        # находит macOS-версию hunspell и ложно помечает её как доступную для iOS.
        _paranoia_resolve_ios_arch(_paranoia_ios_arch _paranoia_ios_prefix)
        set(_hunspell_root "${CMAKE_CURRENT_SOURCE_DIR}/deps/hunspell/${_paranoia_ios_arch}")

        if(EXISTS "${_hunspell_root}/include/hunspell/hunspell.h"
            AND EXISTS "${_hunspell_root}/lib/libhunspell-1.7.a")
            add_library(paranoia_hunspell_prebuilt STATIC IMPORTED)
            set_target_properties(paranoia_hunspell_prebuilt PROPERTIES
                IMPORTED_LOCATION "${_hunspell_root}/lib/libhunspell-1.7.a"
                INTERFACE_INCLUDE_DIRECTORIES "${_hunspell_root}/include"
            )
            set(PARANOIA_HAS_HUNSPELL 1)
            set(PARANOIA_HUNSPELL_TARGET paranoia_hunspell_prebuilt)
            message(STATUS "Paranoia spellcheck: using prebuilt hunspell at ${_hunspell_root}")
        else()
            message(STATUS "Paranoia spellcheck: no prebuilt hunspell at ${_hunspell_root} — run scripts/build_hunspell_ios.sh")
        endif()
    else()
        find_package(PkgConfig QUIET)

        if(PkgConfig_FOUND)
            pkg_check_modules(HUNSPELL_PKG QUIET IMPORTED_TARGET hunspell)

            if(HUNSPELL_PKG_FOUND)
                # hunspell.pc выдаёт Cflags: -I.../include/hunspell, но код
                # использует #include <hunspell/hunspell.h> — нужен родитель.
                get_filename_component(_hunspell_inc_fixed "${HUNSPELL_PKG_INCLUDE_DIRS}" DIRECTORY)
                set_target_properties(PkgConfig::HUNSPELL_PKG PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${_hunspell_inc_fixed}")
                set(PARANOIA_HAS_HUNSPELL 1)
                set(PARANOIA_HUNSPELL_TARGET PkgConfig::HUNSPELL_PKG)
            endif()
        endif()

        # Fallback на голые find_path/find_library: на dev-машинах без
        # libhunspell-dev в системе бывает установлен только runtime пакет
        # (libhunspell-1.7-0). Если hunspell.h+libhunspell-1.7.so находятся
        # вручную — собираем спеллчекер без pkg-config метаданных.
        if(NOT PARANOIA_HAS_HUNSPELL)
            find_path(PARANOIA_HUNSPELL_INCLUDE_DIR
                NAMES hunspell/hunspell.h
                PATH_SUFFIXES include
            )
            find_library(PARANOIA_HUNSPELL_LIBRARY
                NAMES hunspell-1.7 hunspell hunspell-1.6
            )
            if(PARANOIA_HUNSPELL_INCLUDE_DIR AND PARANOIA_HUNSPELL_LIBRARY)
                add_library(paranoia_hunspell_fallback INTERFACE)
                target_include_directories(paranoia_hunspell_fallback INTERFACE
                    "${PARANOIA_HUNSPELL_INCLUDE_DIR}")
                target_link_libraries(paranoia_hunspell_fallback INTERFACE
                    "${PARANOIA_HUNSPELL_LIBRARY}")
                set(PARANOIA_HAS_HUNSPELL 1)
                set(PARANOIA_HUNSPELL_TARGET paranoia_hunspell_fallback)
                message(STATUS "Paranoia spellcheck: found via find_library at ${PARANOIA_HUNSPELL_LIBRARY}")
            endif()
        endif()

        # Runtime-only fallback: установлен ТОЛЬКО рантайм-пакет
        # (libhunspell-1.7.so.0, без dev-symlink .so и без системного заголовка).
        # Тогда линкуемся напрямую с версионированной .so.0 и берём завендоренный
        # минимальный заголовок (deps/hunspell-fallback). Это и есть случай
        # dev-машины с одним libhunspell-1.7-0 — спелчекер работает без apt install
        # libhunspell-dev.
        if(NOT PARANOIA_HAS_HUNSPELL)
            set(_paranoia_saved_suffixes "${CMAKE_FIND_LIBRARY_SUFFIXES}")
            list(APPEND CMAKE_FIND_LIBRARY_SUFFIXES ".so.0" ".so.1")
            find_library(PARANOIA_HUNSPELL_RUNTIME_LIB
                NAMES hunspell-1.7 hunspell-1.6 hunspell)
            set(CMAKE_FIND_LIBRARY_SUFFIXES "${_paranoia_saved_suffixes}")
            set(_paranoia_hunspell_vendored_inc
                "${CMAKE_CURRENT_SOURCE_DIR}/deps/hunspell-fallback")
            if(PARANOIA_HUNSPELL_RUNTIME_LIB
                    AND EXISTS "${_paranoia_hunspell_vendored_inc}/hunspell/hunspell.h")
                add_library(paranoia_hunspell_runtime INTERFACE)
                target_include_directories(paranoia_hunspell_runtime INTERFACE
                    "${_paranoia_hunspell_vendored_inc}")
                target_link_libraries(paranoia_hunspell_runtime INTERFACE
                    "${PARANOIA_HUNSPELL_RUNTIME_LIB}")
                set(PARANOIA_HAS_HUNSPELL 1)
                set(PARANOIA_HUNSPELL_TARGET paranoia_hunspell_runtime)
                message(STATUS "Paranoia spellcheck: runtime-only hunspell at "
                    "${PARANOIA_HUNSPELL_RUNTIME_LIB} (vendored header)")
            endif()
        endif()
    endif()
endif()

message(STATUS "Paranoia spellcheck: HAS_HUNSPELL=${PARANOIA_HAS_HUNSPELL}")
# Не даём спелчекеру «тихо» отключиться на десктоп-сборке: без hunspell поле
# ввода не подчёркивает опечатки (SpellChecker деградирует в no-op). На
# dev-машине обычно достаточно поставить dev-пакет, напр. `apt install
# libhunspell-dev` (Debian/Ubuntu) или `brew install hunspell` (macOS).
if(PARANOIA_ENABLE_HUNSPELL AND NOT PARANOIA_HAS_HUNSPELL
        AND NOT PARANOIA_IS_IOS AND NOT ANDROID)
    message(WARNING "Paranoia spellcheck: hunspell НЕ найден — подчёркивание "
        "опечаток в поле ввода будет ОТКЛЮЧЕНО. Установите dev-пакет hunspell "
        "(apt install libhunspell-dev / brew install hunspell) и пересоберите.")
endif()

set(CMAKE_AUTORCC ON)
qt_standard_project_setup()

qt_add_executable(Paranoia
    MANUAL_FINALIZATION
    resources/design/design.qrc
    resources/dictionaries/dictionaries.qrc
    resources/install_scripts/script.qrc
    src/main.cpp
)

if(PARANOIA_IS_WINDOWS)
    set(PARANOIA_WINDOWS_ICON "${CMAKE_CURRENT_SOURCE_DIR}/resources/design/paranoia.ico")
    configure_file(
        "${CMAKE_CURRENT_SOURCE_DIR}/resources/windows/paranoia.rc.in"
        "${CMAKE_CURRENT_BINARY_DIR}/paranoia.rc"
        @ONLY
    )
    target_sources(Paranoia PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/paranoia.rc")
endif()

target_include_directories(Paranoia
    PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/backend
    ${CMAKE_CURRENT_SOURCE_DIR}/src/session
    ${CMAKE_CURRENT_SOURCE_DIR}/src/platform
    ${CMAKE_CURRENT_SOURCE_DIR}/src/utils
    ${CMAKE_CURRENT_SOURCE_DIR}/src/spell
)

set_source_files_properties(ui/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
set_source_files_properties(ui/Reactions.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(Paranoia
    URI ParanoiaUiClient
    VERSION 1.0
    RESOURCE_PREFIX /qt/qml
    SOURCES
    src/backend/InstallServerBackend.hpp
    src/backend/InstallServerBackend.cpp
    src/backend/MainBackend.hpp
    src/backend/MainBackend.cpp
    src/backend/NotificationCoordinator.hpp
    src/backend/NotificationCoordinator.cpp
    src/backend/VersionInfoBackend.hpp
    src/backend/VersionInfoBackend.cpp
    src/backend/ChatBackend.hpp
    src/backend/ChatBackend.cpp
    src/backend/EncryptedImageProvider.hpp
    src/backend/EmojiImageProvider.hpp
    src/backend/EmojiImageProvider.cpp
    src/session/Dialog.hpp
    src/session/Dialog.cpp
    src/session/ServerSession.hpp
    src/session/ServerSession.cpp
    src/session/SessionStore.hpp
    src/session/SessionStore.cpp
    src/platform/PlatformNotifications.hpp
    src/platform/PlatformNotifications.cpp
    src/platform/DesktopTray.hpp
    src/platform/DesktopTray.cpp
    src/platform/LinuxNotifier.hpp
    src/platform/LinuxNotifier.cpp
    src/platform/OrientationLock.hpp
    src/platform/OrientationLock.cpp
    src/utils/adminStorage.hpp
    src/utils/adminStorage.cpp
    src/utils/ClientSSH.hpp
    src/utils/ClientSSH.cpp
    src/utils/QrCodeUtils.cpp
    src/utils/QrCodeUtils.hpp
    src/utils/QrCameraScanner.cpp
    src/utils/QrCameraScanner.hpp
    src/utils/Utils.cpp
    src/utils/Utils.hpp
    src/utils/Paths.cpp
    src/utils/Paths.hpp
    src/utils/Logging.cpp
    src/utils/Logging.hpp
    src/utils/KeyInjector.cpp
    src/utils/KeyInjector.hpp
    src/spell/SpellChecker.hpp
    src/spell/SpellChecker.cpp
    src/spell/SpellHighlighter.hpp
    src/spell/SpellHighlighter.cpp
    src/backend/NativeFileDialog.hpp
    src/backend/NativeFileDialog.cpp
    QML_FILES
    ui/Main.qml
    ui/Theme.qml
    ui/Reactions.qml
    ui/Components/AppIcon.qml
    ui/Components/EditKeyToolbar.qml
    ui/Components/MessageText.qml
    ui/Components/EmojiPanel.qml
    ui/Components/emojidata.js
    ui/Components/ShredderOverlay.qml
    ui/Components/CenteredPane.qml
    ui/Components/ParaFileDialog.qml
    ui/Components/EmojiPicker.qml
    ui/Components/CallButton.qml
    ui/Components/ParaButton.qml
    ui/Components/RefreshIconButton.qml
    ui/Components/CheckMark.qml
    ui/Components/CopyablePublicKeyBlock.qml
    ui/Components/ImportProfilePanel.qml
    ui/Components/DeliveryStatusIcon.qml
    ui/Components/ParaHeader.qml
    ui/Components/ParaInput.qml
    ui/Components/PhotoViewer.qml
    ui/Components/PhotoMosaic.qml
    ui/Components/ReplyPreview.qml
    ui/Components/Toggle.qml
    ${PARANOIA_OPTIONAL_QML_FILES}
    ui/Components/QrCodeBox.qml
    ui/Components/ProgressStep.qml
    ui/Pages/ClientRegistrationPage.qml
    ui/Pages/HelloPage.qml
    ui/Pages/ImportProfilePage.qml
    ui/Pages/InstallServerPage.qml
    ui/Pages/MainPage.qml
    ui/Pages/ChatPage.qml
    ui/Pages/ExportImportPage.qml
    ui/Pages/QrExchangePage.qml
    ui/Pages/QrScanPage.qml
    ui/Pages/AddDialogPage.qml
    ui/Pages/UpdateKeyPage.qml
    ui/Pages/RegisterUserPage.qml
    ui/Pages/AddReserveDomainPage.qml
    ui/Pages/MaskingPage.qml
    ui/Pages/VersionInfoPage.qml
    ui/Pages/SetPin.qml
    ui/Pages/UnlockPin.qml
    ui/Pages/ChangePin.qml
)

target_compile_definitions(Paranoia
    PRIVATE
    APP_VERSION="${PARANOIA_APP_VERSION}"
    PARANOIA_HAS_QT_VIRTUAL_KEYBOARD=${PARANOIA_HAS_QT_VIRTUAL_KEYBOARD}
    PARANOIA_HAS_QT_MULTIMEDIA=${PARANOIA_HAS_QT_MULTIMEDIA}
    PARANOIA_HAS_VOIP=${PARANOIA_HAS_VOIP}
    PARANOIA_HAS_FFMPEG=${PARANOIA_HAS_FFMPEG}
    PARANOIA_HAS_VIDEO=${PARANOIA_HAS_VIDEO}
    PARANOIA_HAS_HUNSPELL=${PARANOIA_HAS_HUNSPELL}
    PARANOIA_DEFAULT_STUN_SERVER="${PARANOIA_DEFAULT_STUN_SERVER}"
    PARANOIA_DESKTOP_TRAY=${PARANOIA_IS_DESKTOP}
    PARANOIA_BETA_LOGGING=${PARANOIA_BETA_LOGGING}
    "OS_${PARANOIA_PLATFORM}"
)

if(PARANOIA_IS_DESKTOP)
    target_compile_definitions(Paranoia PRIVATE DESKTOP_OS)
elseif(PARANOIA_IS_MOBILE)
    target_compile_definitions(Paranoia PRIVATE MOBILE_OS)
endif()

if(PARANOIA_HAS_VOIP)
    target_sources(Paranoia PRIVATE
        src/voip/OpusCodec.hpp
        src/voip/OpusCodec.cpp
        src/voip/AudioCapture.hpp
        src/voip/AudioCapture.cpp
        src/voip/AudioPlayback.hpp
        src/voip/AudioPlayback.cpp
        src/voip/CallEngine.hpp
        src/voip/CallEngine.cpp
        src/voip/CallSignalingClient.hpp
        src/voip/CallSignalingClient.cpp
        src/voip/CallController.hpp
        src/voip/CallController.cpp
        src/voip/VoipSystem.hpp
        src/voip/VoipSystem.cpp
        src/voip/NetUtil.hpp
        src/voip/NetUtil.cpp
    )
    target_include_directories(Paranoia PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src/voip
    )
    target_link_libraries(Paranoia PRIVATE ${PARANOIA_OPUS_TARGET})
    qt_target_qml_sources(Paranoia
        QML_FILES
            ui/Pages/CallPage.qml
            ui/Components/CallPathIndicator.qml
    )

    if(PARANOIA_IS_IOS)
        target_sources(Paranoia PRIVATE
            src/voip/IosAudioSession.hpp
            src/voip/IosAudioSession.mm
            src/platform/IosOrientationLock.mm
        )
        set_source_files_properties(src/voip/IosAudioSession.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
        set_source_files_properties(src/platform/IosOrientationLock.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
        target_link_libraries(Paranoia PRIVATE "-framework AVFAudio" "-framework UIKit")
    endif()

    if(PARANOIA_HAS_VIDEO)
        target_sources(Paranoia PRIVATE
            src/voip/H264Codec.hpp
            src/voip/H264Codec.cpp
            src/voip/VideoCapture.hpp
            src/voip/VideoCapture.cpp
            src/voip/VideoSink.hpp
            src/voip/VideoSink.cpp
        )
        target_link_libraries(Paranoia PRIVATE ${PARANOIA_FFMPEG_TARGETS})

        if(PARANOIA_IS_ANDROID)
            target_link_libraries(Paranoia PRIVATE android log mediandk z m dl)
        elseif(PARANOIA_IS_IOS)
            target_link_libraries(Paranoia PRIVATE
                "-framework VideoToolbox"
                "-framework CoreMedia"
                "-framework CoreVideo"
                "-framework CoreFoundation"
            )
        endif()
    endif()
endif()

include(GNUInstallDirs)

# Qt for iOS sets MACOSX_BUNDLE_GUI_IDENTIFIER automatically since Qt 6.1.
# If you are developing for iOS or macOS you should consider setting an
# explicit, fixed bundle identifier manually though.
set_target_properties(Paranoia PROPERTIES

    # MACOSX_BUNDLE_GUI_IDENTIFIER com.example.Paranoia
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

if(PARANOIA_IS_IOS)
    # iOS-специфичный compile-define (виден И компилятору, И AUTOMOC — в отличие
    # от Qt-шного Q_OS_IOS, которого moc не знает). Нужен для guard'ов классов с
    # Q_OBJECT, существующих только на iOS (IosFileExport), иначе moc их пропускает
    # → undefined vtable/metaobject при линковке.
    target_compile_definitions(Paranoia PRIVATE PARANOIA_IOS)
    target_sources(Paranoia PRIVATE
        src/platform/PlatformNotifications_ios.mm
        src/platform/ShareTarget_ios.mm
        src/platform/IosFileExport.mm
    )
    set_source_files_properties(
        src/platform/PlatformNotifications_ios.mm
        src/platform/ShareTarget_ios.mm
        src/platform/IosFileExport.mm
        PROPERTIES COMPILE_FLAGS "-fobjc-arc")
    set_target_properties(Paranoia PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/ios/Info.plist.in"
        XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/ios/Paranoia.entitlements"
        # Иконка приложения с вариантами light/dark/tinted (iOS 18) — Xcode
        # компилирует asset-catalog actool'ом и кладёт в бандл.
        XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon"
    )
    target_sources(Paranoia PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/ios/Assets.xcassets")
    set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/ios/Assets.xcassets"
        PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    # LaunchScreen НЕ добавляем вручную: Qt сам генерит launch storyboard
    # (build_ios/.qt/launch_screen_storyboards/Paranoia/LaunchScreen.storyboard),
    # которому и соответствует UILaunchStoryboardName=LaunchScreen в Info.plist.in.
    # Свой ios/LaunchScreen.storyboard давал второй продьюсер того же
    # LaunchScreen.storyboardc → «Multiple commands produce conflicting outputs».
    target_link_libraries(Paranoia PRIVATE
        "-framework BackgroundTasks"
        "-framework UserNotifications"
        "-framework UIKit"
    )

    # ── Share Extension (app extension bundle) ────────────────────────────
    # iOS требует отдельный bundle с CFBundlePackageType=XPC! для extension'ов.
    # Главное приложение получит его как PlugIns/ParanoiaShare.appex внутри
    # своего .app — это делает blockShareExtensionPostBuild ниже.
    add_executable(ParanoiaShareExtension MACOSX_BUNDLE
        ios/ShareExtension/ShareViewController.h
        ios/ShareExtension/ShareViewController.mm
    )
    set_source_files_properties(ios/ShareExtension/ShareViewController.mm
        PROPERTIES COMPILE_FLAGS "-fobjc-arc")
    set_target_properties(ParanoiaShareExtension PROPERTIES
        BUNDLE TRUE
        BUNDLE_EXTENSION "appex"
        OUTPUT_NAME "ParanoiaShare"
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/ios/ShareExtension/Info.plist.in"
        MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
        MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
        MACOSX_BUNDLE_GUI_IDENTIFIER "app.paranoia.client.share"
        XCODE_PRODUCT_TYPE "com.apple.product-type.app-extension"
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "app.paranoia.client.share"
        XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/ios/ShareExtension/Paranoia.entitlements"
        XCODE_ATTRIBUTE_SKIP_INSTALL "YES"
    )
    target_link_libraries(ParanoiaShareExtension PRIVATE
        "-framework UIKit"
        "-framework Foundation"
        "-framework MobileCoreServices"
        "-framework UniformTypeIdentifiers"
    )
    add_dependencies(Paranoia ParanoiaShareExtension)

    # Встроить .appex внутрь Paranoia.app/PlugIns/. Это требование iOS:
    # app extension'ы доставляются только как plug-in'ы главного app bundle'а.
    #
    # NB: ручной POST_BUILD copy через $<TARGET_BUNDLE_DIR:...> + VERBATIM
    # на Xcode-генераторе ломается: путь содержит $(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME),
    # VERBATIM эскейпит $, и shell получает литерал «Release${EFFECTIVE_PLATFORM_NAME}/...»
    # → «No such file or directory». XCODE_EMBED_APP_EXTENSIONS — штатный путь
    # (CMake ≥ 3.21), Xcode сам кладёт .appex в PlugIns/ и подписывает.
    set_target_properties(Paranoia PROPERTIES
        XCODE_EMBED_APP_EXTENSIONS "ParanoiaShareExtension"
    )
endif()

if(PARANOIA_IS_MAC)
    target_sources(Paranoia PRIVATE src/platform/PlatformNotifications_macos.mm)
    set_source_files_properties(src/platform/PlatformNotifications_macos.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
    set_target_properties(Paranoia PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/macos/Info.plist.in"
    )
    target_link_libraries(Paranoia PRIVATE "-framework UserNotifications")
endif()

# ── Нативная локализация Apple (iOS/macOS) ────────────────────────────────────
# NSLocalizedString в src/platform/PlatformNotifications_*.mm читает строки из
# <lang>.lproj/Localizable.strings; <lang>.lproj/InfoPlist.strings локализует
# usage-описания и имя из Info.plist. Базовый язык (исходные строки) — русский;
# en.lproj даёт английский. Кладём в Resources/<lang>.lproj бандла.
# Это отдельный трек от Qt .ts (qsTr/tr) — он покрывает только нативный Obj-C слой.
if(PARANOIA_IS_IOS OR PARANOIA_IS_MAC)
    target_sources(Paranoia PRIVATE
        apple/en.lproj/Localizable.strings
        apple/en.lproj/InfoPlist.strings
        apple/ru.lproj/Localizable.strings
        apple/ru.lproj/InfoPlist.strings)
    set_source_files_properties(
        "${CMAKE_CURRENT_SOURCE_DIR}/apple/en.lproj/Localizable.strings"
        "${CMAKE_CURRENT_SOURCE_DIR}/apple/en.lproj/InfoPlist.strings"
        PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/en.lproj")
    set_source_files_properties(
        "${CMAKE_CURRENT_SOURCE_DIR}/apple/ru.lproj/Localizable.strings"
        "${CMAKE_CURRENT_SOURCE_DIR}/apple/ru.lproj/InfoPlist.strings"
        PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/ru.lproj")
endif()

if(PARANOIA_IS_ANDROID)
    set_target_properties(Paranoia PROPERTIES
        QT_ANDROID_PACKAGE_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/android"
        QT_ANDROID_PACKAGE_NAME "app.paranoia.client"
        QT_ANDROID_APP_NAME "Paranoia"
        QT_ANDROID_VERSION_NAME "${PARANOIA_APP_VERSION}"
        QT_ANDROID_VERSION_CODE ${PARANOIA_ANDROID_VERSION_CODE}
        QT_ANDROID_PERMISSIONS "android.permission.INTERNET;android.permission.ACCESS_NETWORK_STATE;android.permission.FOREGROUND_SERVICE;android.permission.FOREGROUND_SERVICE_DATA_SYNC;android.permission.POST_NOTIFICATIONS;android.permission.CAMERA;android.permission.READ_EXTERNAL_STORAGE;android.permission.WRITE_EXTERNAL_STORAGE;android.permission.READ_MEDIA_IMAGES;android.permission.READ_MEDIA_VIDEO;android.permission.READ_MEDIA_AUDIO;android.permission.RECORD_AUDIO"
    )
    # Иконка приложения задаётся напрямую в android/AndroidManifest.xml
    # (android:icon/@mipmap/icon + roundIcon). Qt НЕ имеет свойства
    # QT_ANDROID_APP_ICON, а androiddeployqt при пустом android-app-icon вообще
    # убирает атрибут android:icon — поэтому прописываем его в манифесте вручную.
endif()

if(PARANOIA_IS_LINUX)
    # QtDBus — необязательная, но если есть, через неё гасятся карточки
    # уведомлений в шторке при выходе приложения на передний план
    # (см. LinuxNotifier).
    find_package(Qt6 QUIET COMPONENTS DBus)
    if(TARGET Qt6::DBus)
        target_link_libraries(Paranoia PRIVATE Qt6::DBus)
        target_compile_definitions(Paranoia PRIVATE PARANOIA_HAS_QT_DBUS=1)
    endif()

    set_target_properties(Paranoia PROPERTIES
        INSTALL_RPATH "$ORIGIN/../${CMAKE_INSTALL_LIBDIR}"
    )
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/resources/design/logo_symbol.svg"
        DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/icons/hicolor/scalable/apps"
        RENAME app.paranoia.client.svg
        COMPONENT Runtime
    )
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/resources/linux/app.paranoia.client.desktop"
        DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/applications"
        COMPONENT Runtime
    )

    # Deploy Wayland platform plugins (loaded dynamically — not picked up by auto-deploy)
    get_filename_component(_qt_prefix "${Qt6Core_DIR}/../../.." ABSOLUTE)
    get_filename_component(_qt_lib_dir "${Qt6Core_DIR}/../.." ABSOLUTE)
    file(GLOB _wayland_qt_libs CONFIGURE_DEPENDS "${_qt_lib_dir}/libQt6Wayland*.so*")

    if(_wayland_qt_libs)
        install(FILES ${_wayland_qt_libs}
            DESTINATION "${CMAKE_INSTALL_LIBDIR}" COMPONENT Runtime)
    endif()

    file(GLOB _wayland_platform_plugins CONFIGURE_DEPENDS "${_qt_prefix}/plugins/platforms/libqwayland*.so*")

    if(_wayland_platform_plugins)
        install(FILES ${_wayland_platform_plugins}
            DESTINATION "plugins/platforms" COMPONENT Runtime)
    endif()

    foreach(_dir IN ITEMS
        wayland-decoration-client
        wayland-graphics-integration-client
        wayland-shell-integration)
        if(EXISTS "${_qt_prefix}/plugins/${_dir}")
            install(DIRECTORY "${_qt_prefix}/plugins/${_dir}"
                DESTINATION "plugins" COMPONENT Runtime)
        endif()
    endforeach()
endif()

if(PARANOIA_IS_WINDOWS)
    # windeployqt разворачивает только Qt-зависимости. Сторонние DLL
    # (FFmpeg / opus / openh264 из vcpkg) нужно копировать в bin/ install-prefix
    # самим — иначе Paranoia.exe не запустится у пользователя.
    set(_paranoia_vcpkg_bin "")
    if(DEFINED VCPKG_INSTALLED_DIR AND DEFINED VCPKG_TARGET_TRIPLET)
        set(_paranoia_vcpkg_bin "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/bin")
    elseif(DEFINED _VCPKG_INSTALLED_DIR AND DEFINED VCPKG_TARGET_TRIPLET)
        set(_paranoia_vcpkg_bin "${_VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/bin")
    endif()

    if(_paranoia_vcpkg_bin AND EXISTS "${_paranoia_vcpkg_bin}")
        file(GLOB _paranoia_vcpkg_runtime_dlls CONFIGURE_DEPENDS
            "${_paranoia_vcpkg_bin}/avcodec-*.dll"
            "${_paranoia_vcpkg_bin}/avutil-*.dll"
            "${_paranoia_vcpkg_bin}/swscale-*.dll"
            "${_paranoia_vcpkg_bin}/swresample-*.dll"
            "${_paranoia_vcpkg_bin}/opus.dll"
            "${_paranoia_vcpkg_bin}/openh264*.dll"
        )
        if(_paranoia_vcpkg_runtime_dlls)
            install(FILES ${_paranoia_vcpkg_runtime_dlls}
                DESTINATION "${CMAKE_INSTALL_BINDIR}"
                COMPONENT Runtime)
            message(STATUS "Paranoia install: bundling vcpkg runtime DLLs from ${_paranoia_vcpkg_bin}")
        else()
            message(WARNING "Paranoia install: no FFmpeg/opus DLLs found under ${_paranoia_vcpkg_bin}; installed app may fail to start")
        endif()
    else()
        message(WARNING "Paranoia install: VCPKG_INSTALLED_DIR is not set — FFmpeg/opus DLLs will be missing from the Windows package")
    endif()
endif()

target_link_libraries(Paranoia
    PRIVATE Qt6::Quick
    Qt6::Concurrent
    Qt6::QuickControls2
    Qt6::QuickDialogs2
    Qt6::QuickLayouts
    Qt6::Svg
    Qt6::Network
    Qt6::LabsSettings
)

if(TARGET Qt6::VirtualKeyboard)
    target_link_libraries(Paranoia PRIVATE Qt6::VirtualKeyboard)
    qt_add_resources(Paranoia "keyboard_style"
        PREFIX "/qt-project.org/imports/QtQuick/VirtualKeyboard/Styles"
        BASE "ui/keyboard"
        FILES
        ui/keyboard/Paranoia/KeyboardIcon.qml
        ui/keyboard/Paranoia/style.qml
    )
    # Кастомные раскладки клавиатуры. Подключаются через переменную окружения
    # QT_VIRTUALKEYBOARD_LAYOUT_PATH=qrc:/paranoia/keyboard_layouts (см. main.cpp).
    # Базируются на штатных раскладках Qt: гарантируют alternativeKeys
    # (е→ё, ь→ъ, .→!?) в собранном APK и не содержат кнопки скрытия клавиатуры.
    qt_add_resources(Paranoia "keyboard_layouts"
        PREFIX "/paranoia/keyboard_layouts"
        BASE "ui/keyboard/layouts"
        FILES
        ui/keyboard/layouts/fallback/main.qml
        ui/keyboard/layouts/fallback/symbols.qml
        ui/keyboard/layouts/fallback/numbers.qml
        ui/keyboard/layouts/fallback/digits.qml
        ui/keyboard/layouts/fallback/dialpad.qml
        ui/keyboard/layouts/fallback/handwriting.qml
        ui/keyboard/layouts/en_US/main.fallback
        ui/keyboard/layouts/en_US/symbols.fallback
        ui/keyboard/layouts/en_US/numbers.fallback
        ui/keyboard/layouts/en_US/digits.fallback
        ui/keyboard/layouts/en_US/dialpad.fallback
        ui/keyboard/layouts/en_US/handwriting.fallback
        ui/keyboard/layouts/ru_RU/main.qml
        ui/keyboard/layouts/ru_RU/handwriting.qml
        ui/keyboard/layouts/ru_RU/symbols.fallback
        ui/keyboard/layouts/ru_RU/numbers.fallback
        ui/keyboard/layouts/ru_RU/digits.fallback
        ui/keyboard/layouts/ru_RU/dialpad.fallback
    )
endif()

if(TARGET Qt6::Multimedia)
    target_link_libraries(Paranoia PRIVATE Qt6::Multimedia)
endif()

if(PARANOIA_HAS_HUNSPELL)
    target_link_libraries(Paranoia PRIVATE ${PARANOIA_HUNSPELL_TARGET})
endif()

if(PARANOIA_IS_IOS)
    # На iOS используется native Darwin/AVFoundation backend для камеры.
    # Ограничиваем multimedia plugins одним darwin-плагином — это исключает
    # Qt6::QFFmpegMediaPlugin (и его impl), который тянет неразрешённые
    # FFmpeg/VideoToolbox символы.
    # Статическая iOS-сборка: platforminputcontext-плагины НЕ импортируются
    # автоматически. Без явного импорта QPlatformInputContextFactory::create(
    # "qtvirtualkeyboard") (вызывается из нашего QPA-патча qiosintegration.mm,
    # т.к. QT_IM_MODULE=qtvirtualkeyboard) возвращает null → fallback на
    # QIOSInputContext → всплывает РОДНАЯ клавиатура, а наша не работает.
    # Qt6::QVirtualKeyboardPlugin = libqtvirtualkeyboardplugin.a (input-context),
    # это НЕ то же, что Qt6::VirtualKeyboardplugin (QML-модуль).
    qt_import_plugins(Paranoia
        INCLUDE Qt6::QVirtualKeyboardPlugin
        INCLUDE_BY_TYPE multimedia Qt6::QDarwinMediaPlugin
    )
endif()

if(PARANOIA_IS_DESKTOP)
    target_link_libraries(Paranoia PRIVATE Qt6::Widgets)
endif()

install(TARGETS Paranoia
    BUNDLE DESTINATION . COMPONENT Runtime
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR} COMPONENT Runtime
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR} COMPONENT Runtime
)
include("${CMAKE_SOURCE_DIR}/deps/Libssh2.cmake")
setup_libssh2(Paranoia)
include("${CMAKE_SOURCE_DIR}/deps/ParanoiaLib.cmake")
setup_paranoia_lib(Paranoia)
include("${CMAKE_SOURCE_DIR}/deps/QrTools.cmake")
setup_qr_tools(Paranoia)

# ── Notifications-service JNI shim (Android) ──────────────────────────
# Сервис уведомлений живёт в отдельном процессе (:notifications). В нём не
# инициализирована Qt-VM, поэтому libParanoia_<abi>.so туда грузить нельзя —
# libQt6Multimedia JNI_OnLoad дёрнет QJniEnvironment::getJniEnv() и упадёт.
# Здесь собирается отдельная маленькая libParanoiaService_<abi>.so, тонкая
# обёртка над paranoia_lib C-ABI без Qt-зависимостей, которую Java-сервис
# грузит сам.
if(PARANOIA_IS_ANDROID)
    # Кладём .so прямо в android-build/libs/<abi>/, откуда androiddeployqt
    # подхватывает её для APK. Generator-expression в QT_ANDROID_EXTRA_LIBS
    # Qt 6.10 не разворачивает (макрос ломает двоеточие), поэтому используем
    # жёсткий путь.
    set(_paranoia_service_outdir "${CMAKE_BINARY_DIR}/android-build/libs/${ANDROID_ABI}")
    set(_paranoia_service_so "${_paranoia_service_outdir}/libParanoiaService_${ANDROID_ABI}.so")

    add_library(ParanoiaService SHARED
        ${CMAKE_CURRENT_SOURCE_DIR}/android/jni/paranoia_service_jni.c
    )
    set_target_properties(ParanoiaService PROPERTIES
        OUTPUT_NAME "ParanoiaService_${ANDROID_ABI}"
        LIBRARY_OUTPUT_DIRECTORY "${_paranoia_service_outdir}"
        POSITION_INDEPENDENT_CODE ON
    )
    target_include_directories(ParanoiaService PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/../ParanoiaLibrary/include
    )
    target_link_libraries(ParanoiaService PRIVATE paranoia_lib log dl m)
    add_dependencies(ParanoiaService paranoia_lib_build)

    set_property(TARGET Paranoia APPEND PROPERTY
        QT_ANDROID_EXTRA_LIBS "${_paranoia_service_so}"
    )
    add_dependencies(Paranoia ParanoiaService)
endif()

# ── Локализация (Qt Linguist) ─────────────────────────────────────────────
# Исходные строки в коде/QML — русские (sourcelanguage=ru_RU). Каждая целевая
# локаль = свой .ts. lupdate сканирует C++/QML цели и собирает строки в .ts;
# lrelease компилирует .qm и встраивает их в бинарь под префикс :/i18n.
#   • обновить .ts (после новых qsTr/tr):  cmake --build <dir> --target update_translations
#   • перевести:                           Qt Linguist → i18n/Paranoia_<locale>.ts
#   • .qm собираются автоматически при обычной сборке и грузятся QTranslator'ом в main.cpp
# Новый язык — добавить файл в TS_FILES (напр. i18n/Paranoia_de.ts) и запустить update_translations.
qt_add_translations(Paranoia
    TS_FILES
        i18n/Paranoia_en.ts
    RESOURCE_PREFIX "/i18n"
    LUPDATE_OPTIONS -no-obsolete -locations none
)

qt_finalize_executable(Paranoia)

qt_generate_deploy_qml_app_script(
    TARGET Paranoia
    OUTPUT_SCRIPT deploy_script
    MACOS_BUNDLE_POST_BUILD
    NO_UNSUPPORTED_PLATFORM_ERROR
    DEPLOY_USER_QML_MODULES_ON_UNSUPPORTED_PLATFORM
)
install(SCRIPT ${deploy_script} COMPONENT Runtime)

if(PARANOIA_IS_LINUX)
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/resources/linux/qt.conf"
        DESTINATION "${CMAKE_INSTALL_BINDIR}"
        COMPONENT Runtime
    )
endif()
