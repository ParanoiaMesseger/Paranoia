include(FetchContent)
# ── mbedTLS (для iOS и Android) ───────────────────────────────────────────────
function(_fetch_mbedtls)
    FetchContent_Declare(mbedtls
        GIT_REPOSITORY https://github.com/Mbed-TLS/mbedtls.git
        GIT_TAG        v3.6.0
        GIT_SHALLOW    TRUE
    )
    set(ENABLE_TESTING  OFF CACHE BOOL "" FORCE)
    set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(mbedtls)
endfunction()
# ── Главная функция: вызывается из корневого CMakeLists.txt ───────────────────
function(setup_libssh2 TARGET)
    # -- Выбор и подготовка crypto-бэкенда ------------------------------------
    if(WIN32)
        set(_crypto_backend "WinCNG")
        message(STATUS "[libssh2] Crypto backend: WinCNG (system)")
    elseif(IOS OR ANDROID)
        set(_crypto_backend "mbedTLS")
        message(STATUS "[libssh2] Crypto backend: mbedTLS (fetched)")
        _fetch_mbedtls()
        # libssh2 uses its own FindMbedTLS.cmake (find_library style), not cmake targets.
        # Point it at the FetchContent build tree so find_package(MbedTLS) succeeds.
        FetchContent_GetProperties(mbedtls)
        set(MBEDTLS_INCLUDE_DIR "${mbedtls_SOURCE_DIR}/include"                 CACHE PATH     "" FORCE)
        set(MBEDCRYPTO_LIBRARY  "${mbedtls_BINARY_DIR}/library/libmbedcrypto.a" CACHE FILEPATH "" FORCE)
        set(MBEDX509_LIBRARY    "${mbedtls_BINARY_DIR}/library/libmbedx509.a"   CACHE FILEPATH "" FORCE)
        set(MBEDTLS_LIBRARY     "${mbedtls_BINARY_DIR}/library/libmbedtls.a"    CACHE FILEPATH "" FORCE)
    else()
        # Linux / macOS
        set(_crypto_backend "OpenSSL")
        set(OPENSSL_USE_STATIC_LIBS TRUE PARENT_SCOPE)
        find_package(OpenSSL REQUIRED)
        if(APPLE)
            # Homebrew OpenSSL не в системных путях
            if(NOT OPENSSL_FOUND)
                set(OPENSSL_ROOT_DIR "/opt/homebrew/opt/openssl@3")
                find_package(OpenSSL REQUIRED)
            endif()
        endif()
        message(STATUS "[libssh2] Crypto backend: OpenSSL ${OPENSSL_VERSION}")
    endif()
    message(STATUS "[libssh2] Will FetchContent_Declare")
    # -- Fetch libssh2 ---------------------------------------------------------
    FetchContent_Declare(libssh2
        GIT_REPOSITORY https://github.com/libssh2/libssh2.git
        GIT_TAG        libssh2-1.11.1
        GIT_SHALLOW    TRUE
    )
    set(BUILD_SHARED_LIBS          OFF CACHE BOOL "" FORCE)
    set(BUILD_TESTING              OFF CACHE BOOL "" FORCE)
    set(LIBSSH2_BUILD_TESTS        OFF CACHE BOOL "" FORCE)
    set(LIBSSH2_BUILD_EXAMPLES     OFF CACHE BOOL "" FORCE)
    set(LIBSSH2_BUILD_DOCUMENTATION OFF CACHE BOOL "" FORCE)
    set(LIBSSH2_BUILD_PKGCONFIG OFF CACHE BOOL "" FORCE)
    set(CRYPTO_BACKEND "${_crypto_backend}" CACHE STRING "" FORCE)
    message(STATUS "[libssh2] Will FetchContent_MakeAvailable")
    FetchContent_MakeAvailable(libssh2)
    if(IOS OR ANDROID)
        # libssh2_static links against IMPORTED MbedTLS targets (paths only, not cmake targets),
        # so we must explicitly order the build.
        add_dependencies(libssh2_static mbedcrypto mbedx509 mbedtls)
    endif()
    # -- Линковка к переданному таргету ----------------------------------------
    target_link_libraries(${TARGET} PRIVATE libssh2_static)
    if(IOS OR ANDROID)
        target_link_libraries(${TARGET} PRIVATE
            mbedtls
            mbedx509
            mbedcrypto
        )
    endif()
    if(ANDROID)
        target_link_libraries(${TARGET} PRIVATE log)
    endif()
    if(IOS)
        target_link_options(${TARGET} PRIVATE -ObjC)
    endif()
    message(STATUS "[libssh2] Linked to target: ${TARGET}")
endfunction()
