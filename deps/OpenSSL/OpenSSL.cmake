
include(ProcessorCount)
ProcessorCount(NPROC)

if(DEFINED OPENSSL_ARCH)
    set(_cross_arch ${OPENSSL_ARCH})
else()
    if(WIN32)
        if("${CMAKE_GENERATOR_PLATFORM}" STREQUAL "ARM64")
            set(_cross_arch "VC-WIN64-ARM")
        else()
            set(_cross_arch "VC-WIN64A")
        endif()
    elseif(APPLE)
        if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
            # OpenSSL 1.1.1 Configure targets for Apple mobile
            # SYSROOT may be "iphonesimulator" or a full path .../iPhoneSimulator....sdk
            if(CMAKE_OSX_SYSROOT MATCHES "[Ii][Pp]hone[Ss]imulator")
                set(_cross_arch "iossimulator-xcrun")
            else()
                set(_cross_arch "ios64-xcrun")
            endif()
            message(STATUS "OpenSSL iOS target: ${_cross_arch} (sysroot=${CMAKE_OSX_SYSROOT})")
        else()
            set(_cross_arch "darwin64-${CMAKE_OSX_ARCHITECTURES}-cc")
        endif()
	endif()
endif()

if(WIN32)
    set(_conf_cmd perl Configure )
    set(_cross_comp_prefix_line "")
    set(_make_cmd nmake)
    set(_install_cmd nmake install_sw )
else()
    if(APPLE AND CMAKE_SYSTEM_NAME STREQUAL "iOS")
        set(_conf_cmd ./Configure)
    elseif(APPLE)
        set(_conf_cmd export MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET} && ./Configure -mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET})
    else()
        set(_conf_cmd env "CC=${CMAKE_C_COMPILER}" "LDFLAGS=${CMAKE_EXE_LINKER_FLAGS}" "./config")
    endif()
    set(_cross_comp_prefix_line "")
    set(_make_cmd make -j${NPROC})
    set(_install_cmd make -j${NPROC} install_sw)
    if (CMAKE_CROSSCOMPILING AND NOT (APPLE AND CMAKE_SYSTEM_NAME STREQUAL "iOS"))
        set(_cross_comp_prefix_line "--cross-compile-prefix=${TOOLCHAIN_PREFIX}-")

        if (CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64")
            set(_cross_arch "linux-aarch64")
        elseif (CMAKE_SYSTEM_PROCESSOR STREQUAL "armhf") # For raspbian
            # TODO: verify
            set(_cross_arch "linux-armv4")
        endif ()
    endif ()
endif()

ExternalProject_Add(dep_OpenSSL
    #EXCLUDE_FROM_ALL ON
    URL "https://github.com/openssl/openssl/archive/OpenSSL_1_1_1w.tar.gz"
    URL_HASH SHA256=2130E8C2FB3B79D1086186F78E59E8BC8D1A6AEDF17AB3907F4CB9AE20918C41
    # URL "https://github.com/openssl/openssl/archive/refs/tags/openssl-3.1.2.tar.gz"
    # URL_HASH SHA256=8c776993154652d0bb393f506d850b811517c8bd8d24b1008aef57fbe55d3f31
    DOWNLOAD_DIR ${DEP_DOWNLOAD_DIR}/OpenSSL
	CONFIGURE_COMMAND ${_conf_cmd} ${_cross_arch}
        "--openssldir=${DESTDIR}"
        "--prefix=${DESTDIR}"
        ${_cross_comp_prefix_line}
        no-shared
        no-asm
        no-ssl3-method
        no-dynamic-engine
    BUILD_IN_SOURCE ON
    BUILD_COMMAND ${_make_cmd}
    INSTALL_COMMAND ${_install_cmd}
)

ExternalProject_Add_Step(dep_OpenSSL install_cmake_files
    DEPENDEES install

    COMMAND ${CMAKE_COMMAND} -E copy_directory openssl "${DESTDIR}${CMAKE_INSTALL_LIBDIR}/cmake/openssl"
    WORKING_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}"
)
