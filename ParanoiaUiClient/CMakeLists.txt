cmake_minimum_required(VERSION 3.16)

project(ParanoiaUiClient VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
find_package(Qt6 REQUIRED COMPONENTS Quick Concurrent QuickControls2 QuickDialogs2 QuickLayouts)

set(CMAKE_AUTORCC ON)
qt_standard_project_setup()

qt_add_executable(appParanoiaUiClient
    MANUAL_FINALIZATION
    resources/install_scripts/script.qrc    
    src/main.cpp
)

target_include_directories(appParanoiaUiClient
    PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

set_source_files_properties(ui/Theme.qml
    PROPERTIES QT_QML_SINGLETON_TYPE TRUE
)

qt_add_qml_module(appParanoiaUiClient
    URI ParanoiaUiClient
    VERSION 1.0
    RESOURCE_PREFIX /qt/qml
    SOURCES
    src/InstallServerBackend.h
    src/InstallServerBackend.cpp
    src/ClientSSH.hpp
    src/ClientSSH.cpp
    src/adminStorage.hpp
    src/adminStorage.cpp
    src/ClientBackend.h
    src/ClientBackend.cpp
    QML_FILES
    ui/Main.qml
    ui/Theme.qml
    ui/Components/ParaButton.qml
    ui/Components/ParaHeader.qml
    ui/Components/ParaInput.qml
    ui/Components/QrCodeBox.qml
    ui/Components/ProgressStep.qml
    ui/Components/Pages/ClientLoginPage.qml
    ui/Components/Pages/ClientRegistrationPage.qml
    ui/Components/Pages/ConnectAdminPage.qml
    ui/Components/Pages/ConnectChoicePage.qml
    ui/Components/Pages/ConnectClientChoicePage.qml
    ui/Components/Pages/HelloPage.qml
    ui/Components/Pages/InstallServerPage.qml
    ui/Components/Pages/MainPage.qml
    ui/Components/Pages/ChatPage.qml
    ui/Components/Pages/ExportImportPage.qml
)

# Qt for iOS sets MACOSX_BUNDLE_GUI_IDENTIFIER automatically since Qt 6.1.
# If you are developing for iOS or macOS you should consider setting an
# explicit, fixed bundle identifier manually though.
set_target_properties(appParanoiaUiClient PROPERTIES

    # MACOSX_BUNDLE_GUI_IDENTIFIER com.example.appParanoiaUiClient
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

if(ANDROID)
    set_target_properties(appParanoiaUiClient PROPERTIES
        QT_ANDROID_PERMISSIONS "android.permission.INTERNET;android.permission.ACCESS_NETWORK_STATE"
    )
elseif(UNIX AND NOT APPLE)
    set_target_properties(appParanoiaUiClient PROPERTIES
        INSTALL_RPATH "$ORIGIN/../${CMAKE_INSTALL_LIBDIR}"
    )
endif()


target_link_libraries(appParanoiaUiClient
    PRIVATE Qt6::Quick
    Qt6::Concurrent
    Qt6::QuickControls2
    Qt6::QuickDialogs2
    Qt6::QuickLayouts
)

include(GNUInstallDirs)
install(TARGETS appParanoiaUiClient
    BUNDLE DESTINATION . COMPONENT Runtime
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR} COMPONENT Runtime
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR} COMPONENT Runtime
)
include("${CMAKE_SOURCE_DIR}/deps/Libssh2.cmake")
setup_libssh2(appParanoiaUiClient)
include("${CMAKE_SOURCE_DIR}/deps/ParanoiaLib.cmake")
setup_paranoia_lib(appParanoiaUiClient)
include("${CMAKE_SOURCE_DIR}/deps/QrTools.cmake")
setup_qr_tools(appParanoiaUiClient)

qt_finalize_executable(appParanoiaUiClient)

qt_generate_deploy_qml_app_script(
    TARGET appParanoiaUiClient
    OUTPUT_SCRIPT deploy_script
    MACOS_BUNDLE_POST_BUILD
    NO_UNSUPPORTED_PLATFORM_ERROR
    DEPLOY_USER_QML_MODULES_ON_UNSUPPORTED_PLATFORM
)
install(SCRIPT ${deploy_script} COMPONENT Runtime)
