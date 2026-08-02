#!/usr/bin/env bash
# Build official libslic3r + orca_ios_api on macOS (no GUI).
# Requires deps already built via: ./build_release_macos.sh -d -a arm64
set -euo pipefail
export PATH="$HOME/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ARCH="$(uname -m)"
DEPS_PREFIX="${ROOT}/deps/build-${ARCH}/OrcaSlicer_dep/usr/local"
# alternate paths used by upstream script
if [ ! -d "$DEPS_PREFIX" ]; then
  DEPS_PREFIX="${ROOT}/deps/build-${ARCH}-macos/OrcaSlicer_dep/usr/local"
fi
if [ ! -d "$DEPS_PREFIX" ]; then
  # find any OrcaSlicer_dep
  FOUND=$(find "${ROOT}/deps" -type d -path '*/OrcaSlicer_dep/usr/local' 2>/dev/null | head -1 || true)
  if [ -n "$FOUND" ]; then
    DEPS_PREFIX="$FOUND"
  fi
fi

if [ ! -d "$DEPS_PREFIX" ]; then
  echo "ERROR: deps not found. Build them first:"
  echo "  export PATH=\"\$HOME/local/bin:\$PATH\""
  echo "  cd $ROOT && ./build_release_macos.sh -d -a $ARCH"
  exit 1
fi

BUILD_DIR="${ROOT}/build-macos-headless-${ARCH}"
echo "Using CMAKE_PREFIX_PATH=$DEPS_PREFIX"
echo "Build dir: $BUILD_DIR"

cmake -S "$ROOT" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$DEPS_PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DSLIC3R_GUI=OFF \
  -DORCA_IOS_API=ON \
  -DSLIC3R_STATIC=ON \
  -DBUILD_TESTS=OFF \
  -DORCA_TOOLS=OFF \
  -DORCA_BUILD_PYTHON_STUBGEN_MODULE=OFF \
  -G "Unix Makefiles"

cmake --build "$BUILD_DIR" --target orca_ios_api -j "$(sysctl -n hw.ncpu)"
echo "OK: orca_ios_api built under $BUILD_DIR"
find "$BUILD_DIR" -name 'liborca_ios_api*' -o -name '*orca_ios*' 2>/dev/null | head -20
