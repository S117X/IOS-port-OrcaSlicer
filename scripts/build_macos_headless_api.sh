#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ARCH="$(uname -m)"
DEPS_PREFIX="${ROOT}/deps/build/${ARCH}/OrcaSlicer_dep/usr/local"
if [ ! -d "$DEPS_PREFIX" ]; then
  echo "ERROR: missing $DEPS_PREFIX"; exit 1
fi
BUILD_DIR="${ROOT}/build-macos-headless-${ARCH}"
echo "DEPS=$DEPS_PREFIX"
echo "BUILD=$BUILD_DIR"
# Python from bundled dep
export PATH="${DEPS_PREFIX}/libpython/bin:$PATH"
cmake -S "$ROOT" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$DEPS_PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=11.3 \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/local:/usr/local:/opt/homebrew" \
  -DPython3_ROOT_DIR="${DEPS_PREFIX}/libpython" \
  -DPython3_EXECUTABLE="${DEPS_PREFIX}/libpython/bin/python3.12" \
  -DSLIC3R_GUI=OFF \
  -DORCA_IOS_API=ON \
  -DSLIC3R_STATIC=ON \
  -DBUILD_TESTS=OFF \
  -DORCA_TOOLS=OFF \
  -DORCA_BUILD_PYTHON_STUBGEN_MODULE=OFF \
  -G "Unix Makefiles"
cmake --build "$BUILD_DIR" --target orca_ios_api -j "$(sysctl -n hw.ncpu)"
echo "BUILD OK"
find "$BUILD_DIR" -name 'liborca_ios_api*' -o -name 'libslic3r*' 2>/dev/null | head -30
