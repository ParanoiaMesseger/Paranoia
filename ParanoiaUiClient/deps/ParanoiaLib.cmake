# deps/ParanoiaLib.cmake
function(setup_paranoia_lib TARGET)
    set(RUST_LIB_DIR "${CMAKE_SOURCE_DIR}/../ParanoiaLibrary")

    # Собираем Rust-библиотеку
    add_custom_target(paranoia_lib_build
        COMMAND cargo build --release
        WORKING_DIRECTORY "${RUST_LIB_DIR}"
        COMMENT "Building paranoia_lib (Rust)"
    )

    # Определяем имя выходного файла под платформу
    if(WIN32)
        set(PARANOIA_LIB_FILE "${RUST_LIB_DIR}/target/release/paranoia_lib.lib")
    else()
        set(PARANOIA_LIB_FILE "${RUST_LIB_DIR}/target/release/libparanoia_lib.a")
    endif()

    add_library(paranoia_lib STATIC IMPORTED GLOBAL)
    set_target_properties(paranoia_lib PROPERTIES
        IMPORTED_LOCATION "${PARANOIA_LIB_FILE}"
    )
    add_dependencies(paranoia_lib paranoia_lib_build)

    # Подключаем include-папку с заголовком
    target_include_directories(${TARGET} PRIVATE "${RUST_LIB_DIR}/include")

    # Линкуем библиотеку + системные зависимости
    target_link_libraries(${TARGET} PRIVATE paranoia_lib)

    if(UNIX AND NOT APPLE)
        target_link_libraries(${TARGET} PRIVATE pthread dl)
    elseif(APPLE)
        target_link_libraries(${TARGET} PRIVATE
            "-framework Security"
            "-framework SystemConfiguration"
        )
    elseif(WIN32)
        target_link_libraries(${TARGET} PRIVATE ws2_32 userenv bcrypt ntdll)
    endif()
endfunction()
