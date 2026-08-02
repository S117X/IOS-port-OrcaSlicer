#!/usr/bin/env bash
# Build OrcaSlicer dependencies for iOS Simulator or device (headless engine subset).
# Skips wxWidgets / GLEW / GLFW / OpenCSG / python / wxInspector via ORCA_IOS_DEPS=ON.
set -euo pipefail
export PATH="$HOME/local/bin:/usr/bin:/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-iphonesimulator}"   # iphonesimulator | iphoneos
ARCH="${2:-arm64}"
BUILD_DIR="${ROOT}/deps/build-ios-${TARGET}-${ARCH}"
LOG_DIR="${ROOT}/build_logs"
mkdir -p "$LOG_DIR" "$BUILD_DIR"

if [[ "$TARGET" == "iphonesimulator" ]]; then
  PLATFORM=OS64SIMULATOR
  SYSROOT=iphonesimulator
else
  PLATFORM=OS64
  SYSROOT=iphoneos
fi

SDK_PATH="$(xcrun --sdk "$SYSROOT" --show-sdk-path)"
echo "=== iOS deps ==="
echo "TARGET=$TARGET ARCH=$ARCH"
echo "SDK=$SDK_PATH"
echo "BUILD=$BUILD_DIR"

# Patch flag: deps/CMakeLists.txt honors ORCA_IOS_DEPS
cmake -S "${ROOT}/deps" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$SYSROOT" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DCMAKE_C_COMPILER="$(xcrun --sdk "$SYSROOT" -f clang)" \
  -DCMAKE_CXX_COMPILER="$(xcrun --sdk "$SYSROOT" -f clang++)" \
  -DORCA_IOS_DEPS=ON \
  -DDEP_DOWNLOAD_DIR="${ROOT}/deps/DL_CACHE" \
  -G "Unix Makefiles" \
  2>&1 | tee "${LOG_DIR}/ios_deps_configure.log"

# Build the aggregated deps target (long)
cmake --build "$BUILD_DIR" --target deps -j "$(sysctl -n hw.ncpu)" \
  2>&1 | tee "${LOG_DIR}/ios_deps_build.log"

echo "DEPS OK → ${BUILD_DIR}/OrcaSlicer_dep/usr/local"
ls -la "${BUILD_DIR}/OrcaSlicer_dep/usr/local/lib" | head -40
