cmake_minimum_required(VERSION 3.20)

project(ParanoiaUiClient VERSION 0.0.5 LANGUAGES CXX)

set(PARANOIA_APP_VERSION "${PROJECT_VERSION}_beta")
math(EXPR PARANOIA_ANDROID_VERSION_CODE
    "${PROJECT_VERSION_MAJOR} * 10000 + ${PROJECT_VERSION_MINOR} * 100 + ${PROJECT_VERSION_PATCH}"
)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
find_package(Qt6 REQUIRED COMPONENTS Quick Concurrent QuickControls2 QuickDialogs2 QuickLayouts Svg)

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
)

set_source_files_properties(ui/Theme.qml
    PROPERTIES QT_QML_SINGLETON_TYPE TRUE
)

qt_add_qml_module(Paranoia
    URI ParanoiaUiClient
    VERSION 1.0
    RESOURCE_PREFIX /qt/qml
    SOURCES
    src/InstallServerBackend.hpp
    src/InstallServerBackend.cpp
    src/ClientSSH.hpp
    src/ClientSSH.cpp
    src/adminStorage.hpp
    src/adminStorage.cpp
    src/ClientBackend.hpp
    src/ClientBackend.cpp
    src/QrCodeUtils.cpp
    src/QrCodeUtils.hpp
    src/Utils.cpp
    src/Utils.hpp
    QML_FILES
    ui/Main.qml
    ui/Theme.qml
    ui/Components/ParaButton.qml
    ui/Components/CopyablePublicKeyBlock.qml
    ui/Components/ParaHeader.qml
    ui/Components/ParaInput.qml
    ui/Components/QrCodeBox.qml
    ui/Components/ProgressStep.qml
    ui/Components/Pages/ClientRegistrationPage.qml
    ui/Components/Pages/HelloPage.qml
    ui/Components/Pages/ImportProfilePage.qml
    ui/Components/Pages/InstallServerPage.qml
    ui/Components/Pages/MainPage.qml
    ui/Components/Pages/ChatPage.qml
    ui/Components/Pages/ExportImportPage.qml
)

target_compile_definitions(Paranoia
    PRIVATE APP_VERSION="${PARANOIA_APP_VERSION}"
)

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

if(ANDROID)
    set_target_properties(Paranoia PROPERTIES
        QT_ANDROID_PACKAGE_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/android"
        QT_ANDROID_PACKAGE_NAME "app.paranoia.client"
        QT_ANDROID_APP_NAME "Paranoia"
        QT_ANDROID_VERSION_NAME "${PARANOIA_APP_VERSION}"
        QT_ANDROID_VERSION_CODE ${PARANOIA_ANDROID_VERSION_CODE}
        QT_ANDROID_PERMISSIONS "android.permission.INTERNET;android.permission.ACCESS_NETWORK_STATE"
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
)

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
