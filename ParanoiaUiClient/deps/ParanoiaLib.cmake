# deps/ParanoiaLib.cmake
function(setup_paranoia_lib TARGET)
    set(RUST_LIB_DIR "${CMAKE_SOURCE_DIR}/../ParanoiaLibrary")

    # Кросс-компиляция: -DPARANOIA_CARGO_TARGET=aarch64-linux-android и т.п.
    if(DEFINED PARANOIA_CARGO_TARGET AND NOT "${PARANOIA_CARGO_TARGET}" STREQUAL "")
        set(_cargo_args --release --target "${PARANOIA_CARGO_TARGET}")
        set(_lib_subdir "${PARANOIA_CARGO_TARGET}/release")
    else()
        set(_cargo_args --release)
        set(_lib_subdir "release")
    endif()

    if(WIN32)
        set(PARANOIA_LIB_FILE "${RUST_LIB_DIR}/target/${_lib_subdir}/paranoia_lib.lib")
    else()
        set(PARANOIA_LIB_FILE "${RUST_LIB_DIR}/target/${_lib_subdir}/libparanoia_lib.a")
    endif()

    # Для Android передаём NDK-линкер и C-компилятор через окружение cargo/cc
    if(ANDROID AND DEFINED PARANOIA_CARGO_TARGET)
        set(_ndk_bin "${ANDROID_TOOLCHAIN_ROOT}/bin")
        string(TOUPPER "${PARANOIA_CARGO_TARGET}" _upper)
        string(REPLACE "-" "_" _upper "${_upper}")
        string(TOLOWER "${PARANOIA_CARGO_TARGET}" _lower)
        string(REPLACE "-" "_" _lower "${_lower}")
        set(_clang "${_ndk_bin}/${PARANOIA_CARGO_TARGET}${ANDROID_PLATFORM_LEVEL}-clang")
        add_custom_target(paranoia_lib_build
            COMMAND ${CMAKE_COMMAND} -E env
                "CARGO_TARGET_${_upper}_LINKER=${_clang}"
                "CC_${_lower}=${_clang}"
                "AR_${_lower}=${_ndk_bin}/llvm-ar"
                "PATH=$ENV{PATH}:${_ndk_bin}"
                cargo build ${_cargo_args}
            BYPRODUCTS "${PARANOIA_LIB_FILE}"
            WORKING_DIRECTORY "${RUST_LIB_DIR}"
            COMMENT "Building paranoia_lib (Rust) → ${PARANOIA_CARGO_TARGET}"
        )
    elseif(IOS AND DEFINED PARANOIA_CARGO_TARGET)
        add_custom_target(paranoia_lib_build
            COMMAND ${CMAKE_COMMAND} -E env
                "IPHONEOS_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}"
                cargo build ${_cargo_args}
            BYPRODUCTS "${PARANOIA_LIB_FILE}"
            WORKING_DIRECTORY "${RUST_LIB_DIR}"
            COMMENT "Building paranoia_lib (Rust) → ${PARANOIA_CARGO_TARGET}"
        )
    else()
        add_custom_target(paranoia_lib_build
            COMMAND cargo build ${_cargo_args}
            BYPRODUCTS "${PARANOIA_LIB_FILE}"
            WORKING_DIRECTORY "${RUST_LIB_DIR}"
            COMMENT "Building paranoia_lib (Rust)"
        )
    endif()

    add_library(paranoia_lib STATIC IMPORTED GLOBAL)
    set_target_properties(paranoia_lib PROPERTIES IMPORTED_LOCATION "${PARANOIA_LIB_FILE}")
    add_dependencies(paranoia_lib paranoia_lib_build)

    target_include_directories(${TARGET} PRIVATE "${RUST_LIB_DIR}/include")
    target_link_libraries(${TARGET} PRIVATE paranoia_lib)

    if(ANDROID)
        target_link_libraries(${TARGET} PRIVATE log dl m)
    elseif(UNIX AND NOT APPLE)
        target_link_libraries(${TARGET} PRIVATE pthread dl)
    elseif(APPLE)
        target_link_libraries(${TARGET} PRIVATE
            "-framework CoreFoundation"
            "-framework Security"
            "-framework SystemConfiguration"
        )
    elseif(WIN32)
        target_link_libraries(${TARGET} PRIVATE ws2_32 userenv bcrypt ntdll)
        # rusqlite/bundled-sqlcipher линкуется к OpenSSL только под Windows
        # (на Android используется vendored-openssl, см. ParanoiaLibrary/Cargo.toml).
        # CMake находит установку через OPENSSL_ROOT_DIR (vcpkg x64-windows-static-md на CI).
        find_package(OpenSSL REQUIRED)
        target_link_libraries(${TARGET} PRIVATE OpenSSL::SSL OpenSSL::Crypto crypt32 secur32)
    endif()
endfunction()
