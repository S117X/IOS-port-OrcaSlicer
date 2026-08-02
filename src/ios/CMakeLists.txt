# iOS / mobile C API over official libslic3r
# Built when ORCA_IOS_API=ON or when targeting iOS.

cmake_minimum_required(VERSION 3.13)

add_library(orca_ios_api STATIC
    orca_slice_c_api.cpp
    orca_slice_c_api.h
    nanosvg_impl.cpp
    rgb2hsv_stub.cpp
)

target_include_directories(orca_ios_api
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}
    PRIVATE
        ${CMAKE_SOURCE_DIR}/src
        ${CMAKE_SOURCE_DIR}/src/libslic3r
        ${CMAKE_SOURCE_DIR}/deps_src
        ${CMAKE_SOURCE_DIR}/deps_src/nanosvg
)

target_link_libraries(orca_ios_api
    PUBLIC
        libslic3r
)

target_compile_features(orca_ios_api PUBLIC cxx_std_17)

# CLI for host verification (macOS / Linux). Skip on pure iOS toolchains.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    add_executable(orca_slice_cli orca_slice_cli.cpp)
    target_link_libraries(orca_slice_cli PRIVATE orca_ios_api)
    target_include_directories(orca_slice_cli PRIVATE
        ${CMAKE_SOURCE_DIR}/deps_src
        ${CMAKE_SOURCE_DIR}/deps_src/nanosvg
    )
    if(APPLE)
        target_link_libraries(orca_slice_cli PRIVATE "-liconv" "-framework Foundation" "-framework ModelIO" "-framework IOKit" "-framework CoreFoundation")
    endif()
    target_compile_features(orca_slice_cli PRIVATE cxx_std_17)
endif()

# Install headers for Xcode / Swift PM consumption
install(FILES orca_slice_c_api.h DESTINATION include/orca)
install(TARGETS orca_ios_api ARCHIVE DESTINATION lib)
