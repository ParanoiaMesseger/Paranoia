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
    elseif(IOS)
        set(_crypto_backend "mbedTLS")
        message(STATUS "[libssh2] Crypto backend: mbedTLS (fetched)")
        _fetch_mbedtls()
        # libssh2 uses its own FindMbedTLS.cmake. Use the fetched CMake targets here so
        # multi-config generators like Xcode resolve Release-iphoneos archive paths correctly.
        FetchContent_GetProperties(mbedtls)
        set(MBEDTLS_INCLUDE_DIR "${mbedtls_SOURCE_DIR}/include" CACHE PATH "" FORCE)
        set(MBEDCRYPTO_LIBRARY mbedcrypto CACHE STRING "" FORCE)
    elseif(ANDROID)
        set(_crypto_backend "mbedTLS")
        message(STATUS "[libssh2] Crypto backend: mbedTLS (fetched)")
        _fetch_mbedtls()
        # Android uses the single-config Ninja generator, so keep the resolved archive paths
        # that were already working for the Android CI job.
        FetchContent_GetProperties(mbedtls)
        set(MBEDTLS_INCLUDE_DIR "${mbedtls_SOURCE_DIR}/include"                 CACHE PATH     "" FORCE)
        set(MBEDCRYPTO_LIBRARY  "${mbedtls_BINARY_DIR}/library/libmbedcrypto.a" CACHE FILEPATH "" FORCE)
        set(MBEDX509_LIBRARY    "${mbedtls_BINARY_DIR}/library/libmbedx509.a"   CACHE FILEPATH "" FORCE)
        set(MBEDTLS_LIBRARY     "${mbedtls_BINARY_DIR}/library/libmbedtls.a"    CACHE FILEPATH "" FORCE)
    else()
        # Linux / macOS
        set(_crypto_backend "OpenSSL")
        set(OPENSSL_USE_STATIC_LIBS TRUE)
        set(OPENSSL_USE_STATIC_LIBS TRUE PARENT_SCOPE)
        if(APPLE AND NOT OPENSSL_ROOT_DIR)
            foreach(_openssl_prefix IN ITEMS
                    "/opt/homebrew/opt/openssl@3"
                    "/usr/local/opt/openssl@3")
                if(EXISTS "${_openssl_prefix}/include/openssl/ssl.h")
                    set(OPENSSL_ROOT_DIR "${_openssl_prefix}" CACHE PATH "OpenSSL root" FORCE)
                    break()
                endif()
            endforeach()
        endif()
        find_package(OpenSSL REQUIRED)
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
    set(BUILD_STATIC_LIBS          ON CACHE BOOL "" FORCE)
    set(BUILD_EXAMPLES             OFF CACHE BOOL "" FORCE)
    set(BUILD_TESTING              OFF CACHE BOOL "" FORCE)
    set(LIBSSH2_BUILD_TESTS        OFF CACHE BOOL "" FORCE)
    set(LIBSSH2_BUILD_EXAMPLES     OFF CACHE BOOL "" FORCE)
    set(LIBSSH2_BUILD_DOCUMENTATION OFF CACHE BOOL "" FORCE)
    set(LIBSSH2_BUILD_PKGCONFIG OFF CACHE BOOL "" FORCE)
    set(CRYPTO_BACKEND "${_crypto_backend}" CACHE STRING "" FORCE)
    message(STATUS "[libssh2] Will FetchContent_MakeAvailable")
    FetchContent_MakeAvailable(libssh2)
    if(IOS)
        # Keep libssh2's generated export files independent from fetched mbedTLS targets.
        # The application links mbedTLS explicitly below, preserving correct Xcode config paths.
        foreach(_libssh2_property IN ITEMS INTERFACE_LINK_LIBRARIES LINK_LIBRARIES)
            get_target_property(_libssh2_libraries libssh2_static ${_libssh2_property})
            if(_libssh2_libraries)
                foreach(_libssh2_mbedtls_target IN ITEMS mbedcrypto mbedx509 mbedtls)
                    list(REMOVE_ITEM _libssh2_libraries
                        "${_libssh2_mbedtls_target}"
                        "$<LINK_ONLY:${_libssh2_mbedtls_target}>"
                    )
                endforeach()
                set_property(TARGET libssh2_static PROPERTY ${_libssh2_property} "${_libssh2_libraries}")
            endif()
        endforeach()
    endif()
    if(IOS OR ANDROID)
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
