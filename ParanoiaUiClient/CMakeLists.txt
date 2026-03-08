cmake_minimum_required(VERSION 3.16)

project(ParanoiaUiClient VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
find_package(Qt6 REQUIRED COMPONENTS Quick)

set(CMAKE_AUTORCC ON)
qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(appParanoiaUiClient
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
    SOURCES
    src/InstallServerBackend.h
    src/InstallServerBackend.cpp
    src/ClientSSH.hpp
    src/ClientSSH.cpp
    src/adminStorage.hpp
    src/adminStorage.cpp
    QML_FILES
    ui/Main.qml
    ui/Theme.qml
    ui/Components/ParaButton.qml
    ui/Components/ParaHeader.qml
    ui/Components/ParaInput.qml
    ui/Components/ProgressStep.qml
    ui/Components/Pages/ClientLoginPage.qml
    ui/Components/Pages/ClientRegistrationPage.qml
    ui/Components/Pages/ConnectAdminPage.qml
    ui/Components/Pages/ConnectChoicePage.qml
    ui/Components/Pages/ConnectClientChoicePage.qml
    ui/Components/Pages/HelloPage.qml
    ui/Components/Pages/InstallServerPage.qml
    ui/Components/Pages/MainPage.qml
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


target_link_libraries(appParanoiaUiClient
    PRIVATE Qt6::Quick
    Qt6::Concurrent
)

include(GNUInstallDirs)
install(TARGETS appParanoiaUiClient
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
include("${CMAKE_SOURCE_DIR}/deps/Libssh2.cmake")
setup_libssh2(appParanoiaUiClient)
include("${CMAKE_SOURCE_DIR}/deps/ParanoiaLib.cmake")
setup_paranoia_lib(appParanoiaUiClient)
