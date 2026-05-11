cmake_minimum_required(VERSION 3.20)

project(ParanoiaUiClient VERSION 0.2.0 LANGUAGES CXX)

set(PARANOIA_APP_VERSION "${PROJECT_VERSION}_beta")
math(EXPR PARANOIA_ANDROID_VERSION_CODE
    "${PROJECT_VERSION_MAJOR} * 10000 + ${PROJECT_VERSION_MINOR} * 100 + ${PROJECT_VERSION_PATCH}"
)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
option(PARANOIA_ENABLE_QT_VIRTUAL_KEYBOARD "Enable Qt Virtual Keyboard when the Qt module is installed" ON)
option(PARANOIA_BETA_LOGGING "Write all Qt messages to paranoia_debug.log in app data dir" ON)
set(PARANOIA_QT_COMPONENTS Quick Concurrent QuickControls2 QuickDialogs2 QuickLayouts Svg Network LabsSettings)
if(WIN32 OR (UNIX AND NOT APPLE AND NOT ANDROID))
    list(APPEND PARANOIA_QT_COMPONENTS Widgets)
endif()
find_package(Qt6 REQUIRED COMPONENTS ${PARANOIA_QT_COMPONENTS})
set(PARANOIA_HAS_QT_VIRTUAL_KEYBOARD 0)
set(PARANOIA_OPTIONAL_QML_FILES)
set(PARANOIA_REQUIRES_QT_VIRTUAL_KEYBOARD OFF)
if(ANDROID OR IOS)
    set(PARANOIA_REQUIRES_QT_VIRTUAL_KEYBOARD ON)
endif()
if(PARANOIA_REQUIRES_QT_VIRTUAL_KEYBOARD)
    find_package(Qt6 REQUIRED COMPONENTS VirtualKeyboard)
    set(PARANOIA_HAS_QT_VIRTUAL_KEYBOARD 1)
    list(APPEND PARANOIA_OPTIONAL_QML_FILES ui/Components/VirtualKeyboardPanel.qml)
elseif(PARANOIA_ENABLE_QT_VIRTUAL_KEYBOARD)
    find_package(Qt6 OPTIONAL_COMPONENTS VirtualKeyboard)
    if(TARGET Qt6::VirtualKeyboard)
        set(PARANOIA_HAS_QT_VIRTUAL_KEYBOARD 1)
        list(APPEND PARANOIA_OPTIONAL_QML_FILES ui/Components/VirtualKeyboardPanel.qml)
    endif()
endif()
if(IOS)
    enable_language(OBJCXX)
endif()

set(CMAKE_AUTORCC ON)
qt_standard_project_setup()

qt_add_executable(Paranoia
    MANUAL_FINALIZATION
    resources/design/design.qrc
    resources/install_scripts/script.qrc    
    src/main.cpp
)

if(WIN32)
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
)

set_source_files_properties(ui/Theme.qml
    PROPERTIES QT_QML_SINGLETON_TYPE TRUE
)

qt_add_qml_module(Paranoia
    URI ParanoiaUiClient
    VERSION 1.0
    RESOURCE_PREFIX /qt/qml
    SOURCES
    src/backend/InstallServerBackend.hpp
    src/backend/InstallServerBackend.cpp
    src/backend/MainBackend.hpp
    src/backend/MainBackend.cpp
    src/backend/ChatBackend.hpp
    src/backend/ChatBackend.cpp
    src/session/Dialog.hpp
    src/session/Dialog.cpp
    src/session/ServerSession.hpp
    src/session/ServerSession.cpp
    src/session/SessionStore.hpp
    src/session/SessionStore.cpp
    src/platform/PlatformNotifications.hpp
    src/platform/PlatformNotifications.cpp
    src/utils/adminStorage.hpp
    src/utils/adminStorage.cpp
    src/utils/ClientSSH.hpp
    src/utils/ClientSSH.cpp
    src/utils/QrCodeUtils.cpp
    src/utils/QrCodeUtils.hpp
    src/utils/Utils.cpp
    src/utils/Utils.hpp
    src/utils/Paths.cpp
    src/utils/Paths.hpp
    QML_FILES
    ui/Main.qml
    ui/Theme.qml
    ui/Components/ParaButton.qml
    ui/Components/CopyablePublicKeyBlock.qml
    ui/Components/ParaHeader.qml
    ui/Components/ParaInput.qml
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
    ui/Pages/AddDialogPage.qml
    ui/Pages/UpdateKeyPage.qml
    ui/Pages/ClearHistoryPage.qml
    ui/Pages/RegisterUserPage.qml
)

target_compile_definitions(Paranoia
    PRIVATE
    APP_VERSION="${PARANOIA_APP_VERSION}"
    PARANOIA_HAS_QT_VIRTUAL_KEYBOARD=${PARANOIA_HAS_QT_VIRTUAL_KEYBOARD}
)
if(PARANOIA_BETA_LOGGING)
    target_compile_definitions(Paranoia PRIVATE PARANOIA_BETA_LOGGING=1)
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

if(IOS)
    target_sources(Paranoia PRIVATE src/platform/PlatformNotifications_ios.mm)
    set_source_files_properties(src/platform/PlatformNotifications_ios.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
    set_target_properties(Paranoia PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/ios/Info.plist.in"
    )
    target_link_libraries(Paranoia PRIVATE
        "-framework BackgroundTasks"
        "-framework UserNotifications"
        "-framework UIKit"
    )
endif()

if(ANDROID)
    set_target_properties(Paranoia PROPERTIES
        QT_ANDROID_PACKAGE_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/android"
        QT_ANDROID_PACKAGE_NAME "app.paranoia.client"
        QT_ANDROID_APP_NAME "Paranoia"
        QT_ANDROID_VERSION_NAME "${PARANOIA_APP_VERSION}"
        QT_ANDROID_VERSION_CODE ${PARANOIA_ANDROID_VERSION_CODE}
        QT_ANDROID_PERMISSIONS "android.permission.INTERNET;android.permission.ACCESS_NETWORK_STATE;android.permission.FOREGROUND_SERVICE;android.permission.FOREGROUND_SERVICE_DATA_SYNC;android.permission.POST_NOTIFICATIONS;android.permission.READ_EXTERNAL_STORAGE;android.permission.WRITE_EXTERNAL_STORAGE;android.permission.READ_MEDIA_IMAGES;android.permission.READ_MEDIA_VIDEO;android.permission.READ_MEDIA_AUDIO"
        QT_ANDROID_APP_ICON "@drawable/icon"
    )
elseif(UNIX AND NOT APPLE)
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
        ui/keyboard/Paranoia/style.qml
    )
endif()

if(WIN32 OR (UNIX AND NOT APPLE AND NOT ANDROID))
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

qt_finalize_executable(Paranoia)

qt_generate_deploy_qml_app_script(
    TARGET Paranoia
    OUTPUT_SCRIPT deploy_script
    MACOS_BUNDLE_POST_BUILD
    NO_UNSUPPORTED_PLATFORM_ERROR
    DEPLOY_USER_QML_MODULES_ON_UNSUPPORTED_PLATFORM
)
install(SCRIPT ${deploy_script} COMPONENT Runtime)
