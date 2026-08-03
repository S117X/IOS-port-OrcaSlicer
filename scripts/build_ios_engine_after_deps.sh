#!/usr/bin/env bash
# Build orca_ios_api for iOS Simulator or device once deps finish, bundle, regen Xcode.
set -euo pipefail
export PATH="$HOME/local/bin:/usr/bin:/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-iphonesimulator}"   # iphonesimulator | iphoneos
ARCH="${2:-arm64}"
DEPS_PREFIX="${ROOT}/deps/build-ios-${TARGET}-${ARCH}/OrcaSlicer_dep/usr/local"
BUILD_DIR="${ROOT}/build-ios-${TARGET}-${ARCH}"
if [[ ! -d "$DEPS_PREFIX/lib" ]]; then
  echo "Missing deps at $DEPS_PREFIX"; exit 1
fi
if [[ "$TARGET" == "iphoneos" ]]; then
  PLATFORM=OS64
else
  PLATFORM=OS64SIMULATOR
fi
mkdir -p "$BUILD_DIR"
cmake -S "$ROOT" -B "$BUILD_DIR" \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/cmake/ios.toolchain.cmake" \
  -DPLATFORM="$PLATFORM" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$DEPS_PREFIX" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DSLIC3R_GUI=OFF -DORCA_IOS=ON -DORCA_IOS_API=ON \
  -DSLIC3R_STATIC=ON -DBUILD_TESTS=OFF -DORCA_TOOLS=OFF \
  -DORCA_BUILD_PYTHON_STUBGEN_MODULE=OFF \
  -G "Unix Makefiles"
cmake --build "$BUILD_DIR" --target orca_ios_api -j "$(sysctl -n hw.ncpu)"
"$ROOT/scripts/bundle_engine_libs.sh" "$BUILD_DIR" "$DEPS_PREFIX/lib"
cd "$ROOT/ios" && python3 generate_xcodeproj.py
echo "iOS engine ready ($TARGET $ARCH). Rebuild Xcode with ORCA_LINKED."
