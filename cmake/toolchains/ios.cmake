# Placeholder toolchain for Phase 1 iOS cross-compile of libslic3r.
# Use with a proper iOS CMake toolchain (e.g. ios-cmake) once deps are ready.
#
# Example (NOT complete — deps must be built first):
#   cmake -G Xcode \
#     -DCMAKE_SYSTEM_NAME=iOS \
#     -DCMAKE_OSX_ARCHITECTURES=arm64 \
#     -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
#     -DSLIC3R_GUI=OFF \
#     -DSLIC3R_STATIC=ON \
#     -B build-ios
#
# Upstream does not yet support this; this file marks the port entry point.
message(STATUS "OrcaSlicer iOS toolchain stub — set SLIC3R_GUI=OFF and cross-built CMAKE_PREFIX_PATH")
