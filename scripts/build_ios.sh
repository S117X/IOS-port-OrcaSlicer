#!/usr/bin/env bash
# Build path for OrcaSlicer iOS port (official source tree).
# Phase 1: build deps + libslic3r + orca_ios_api for iOS Simulator or device.
#
# Prerequisites: Xcode, cmake ≥ 3.13, ~20–40GB free for deps.
# See PORT_IOS.md
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-iphonesimulator}"  # iphonesimulator | iphoneos
ARCH="${2:-arm64}"
BUILD_DIR="${ROOT}/build-ios-${TARGET}-${ARCH}"
DEPS_DIR="${ROOT}/deps/build-ios-${TARGET}-${ARCH}"

echo "=== OrcaSlicer iOS build ==="
echo "ROOT=$ROOT"
echo "TARGET=$TARGET ARCH=$ARCH"

# --- 1) Dependencies (long) ---
# Official deps use deps/CMakeLists.txt; cross-compile for iOS is non-trivial.
# This script configures the main project when CMAKE_PREFIX_PATH already points
# at an iOS-built dep prefix. If missing, we only configure and show next steps.

IOS_CMAKE_ARGS=(
  -G Xcode
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_SYSROOT="$TARGET"
  -DCMAKE_OSX_ARCHITECTURES="$ARCH"
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0
  -DSLIC3R_GUI=OFF
  -DORCA_IOS=ON
  -DORCA_IOS_API=ON
  -DSLIC3R_STATIC=ON
  -DBUILD_TESTS=OFF
  -DORCA_TOOLS=OFF
  -DORCA_BUILD_PYTHON_STUBGEN_MODULE=OFF
)

if [[ -n "${CMAKE_PREFIX_PATH:-}" ]]; then
  IOS_CMAKE_ARGS+=(-DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH")
  echo "Using CMAKE_PREFIX_PATH=$CMAKE_PREFIX_PATH"
else
  echo "WARN: CMAKE_PREFIX_PATH not set."
  echo "  Build Boost/TBB/Eigen/CURL/OpenSSL/… for iOS first (see deps/)."
  echo "  Example once deps exist:"
  echo "    export CMAKE_PREFIX_PATH=$DEPS_DIR/OrcaSlicer_dep/usr/local"
fi

mkdir -p "$BUILD_DIR"
set +e
cmake -S "$ROOT" -B "$BUILD_DIR" "${IOS_CMAKE_ARGS[@]}"
CFG_RC=$?
set -e

if [[ $CFG_RC -ne 0 ]]; then
  echo ""
  echo "Configure failed (expected until iOS deps are built)."
  echo "C API sources are ready: src/ios/orca_slice_c_api.{h,cpp}"
  echo "Swift host: ios/OrcaSlicerApp/"
  echo "Next: port deps with iOS toolchain, re-run this script."
  exit $CFG_RC
fi

cmake --build "$BUILD_DIR" --config Release --target orca_ios_api
echo "Built orca_ios_api. Link into ios/OrcaSlicerApp in Xcode."
