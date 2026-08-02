# iOS / mobile C API over official libslic3r
# Built when ORCA_IOS_API=ON or when targeting iOS.

cmake_minimum_required(VERSION 3.13)

add_library(orca_ios_api STATIC
    orca_slice_c_api.cpp
    orca_slice_c_api.h
)

target_include_directories(orca_ios_api
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}
    PRIVATE
        ${CMAKE_SOURCE_DIR}/src
        ${CMAKE_SOURCE_DIR}/src/libslic3r
)

target_link_libraries(orca_ios_api
    PUBLIC
        libslic3r
)

target_compile_features(orca_ios_api PUBLIC cxx_std_17)

# Install headers for Xcode / Swift PM consumption
install(FILES orca_slice_c_api.h DESTINATION include/orca)
install(TARGETS orca_ios_api ARCHIVE DESTINATION lib)
