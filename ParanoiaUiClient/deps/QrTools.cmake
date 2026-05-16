include(FetchContent)

function(setup_qr_tools TARGET)
    FetchContent_Declare(qrcodegen
        GIT_REPOSITORY https://github.com/nayuki/QR-Code-generator.git
        GIT_TAG        v1.8.0
        GIT_SHALLOW    TRUE
    )
    FetchContent_GetProperties(qrcodegen)
    if(NOT qrcodegen_POPULATED)
        FetchContent_Populate(qrcodegen)
    endif()
    if(NOT TARGET qrcodegen)
        add_library(qrcodegen STATIC
            "${qrcodegen_SOURCE_DIR}/cpp/qrcodegen.cpp"
        )
        target_include_directories(qrcodegen PUBLIC
            "${qrcodegen_SOURCE_DIR}/cpp"
        )
    endif()

    set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
    set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(ZXING_READERS ON CACHE BOOL "" FORCE)
    set(ZXING_WRITERS OFF CACHE STRING "" FORCE)
    set(ZXING_C_API OFF CACHE BOOL "" FORCE)
    set(ZXING_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(ZXING_EXAMPLES_QT OFF CACHE BOOL "" FORCE)
    set(ZXING_BLACKBOX_TESTS OFF CACHE BOOL "" FORCE)
    set(ZXING_UNIT_TESTS OFF CACHE BOOL "" FORCE)
    set(ZXING_ENABLE_1D OFF CACHE BOOL "" FORCE)
    set(ZXING_ENABLE_AZTEC OFF CACHE BOOL "" FORCE)
    set(ZXING_ENABLE_DATAMATRIX OFF CACHE BOOL "" FORCE)
    set(ZXING_ENABLE_MAXICODE OFF CACHE BOOL "" FORCE)
    set(ZXING_ENABLE_PDF417 OFF CACHE BOOL "" FORCE)
    set(ZXING_ENABLE_QRCODE ON CACHE BOOL "" FORCE)
    FetchContent_Declare(zxingcpp
        GIT_REPOSITORY https://github.com/zxing-cpp/zxing-cpp.git
        GIT_TAG        v2.3.0
        GIT_SHALLOW    TRUE
        GIT_SUBMODULES ""
    )
    FetchContent_MakeAvailable(zxingcpp)

    target_link_libraries(${TARGET} PRIVATE qrcodegen ZXing::ZXing)
endfunction()
