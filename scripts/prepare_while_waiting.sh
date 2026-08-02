#!/usr/bin/env bash
# Everything that can run without iOS Simulator installed.
set -euo pipefail
export PATH="$HOME/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build_logs

echo "=== 1) CMake ==="
cmake --version

echo "=== 2) Bundle official resources into iOS app (profiles subset) ==="
RES_DST="${ROOT}/ios/OrcaSlicerApp/Resources"
mkdir -p "$RES_DST"
# Copy essential profile data from official tree (not recreated)
rsync -a --delete \
  --include='profiles/***' \
  --include='images/OrcaSlicer*.png' \
  --include='images/' \
  --exclude='*' \
  "${ROOT}/resources/" "$RES_DST/" 2>/dev/null || {
  mkdir -p "$RES_DST/profiles"
  cp -R "${ROOT}/resources/profiles" "$RES_DST/" 2>/dev/null || true
}
echo "Resources staged: $(du -sh "$RES_DST" | awk '{print $1}')"

echo "=== 3) Verify C API sources ==="
test -f src/ios/orca_slice_c_api.cpp
test -f src/ios/orca_slice_c_api.h
echo "C API OK"

echo "=== 4) Verify Xcode project ==="
test -f ios/OrcaSlicer.xcodeproj/project.pbxproj
echo "Xcode project OK"

echo "=== 5) Start macOS deps build if not present (long, background-friendly) ==="
ARCH="$(uname -m)"
if find deps -type d -name 'OrcaSlicer_dep' 2>/dev/null | grep -q .; then
  echo "Deps already present — skip start"
  find deps -type d -name 'OrcaSlicer_dep' | head -5
elif pgrep -f "build_release_macos.sh -d" >/dev/null 2>&1; then
  echo "Deps build already running"
  pgrep -fl "build_release_macos.sh -d" | head -3
else
  echo "Starting: ./build_release_macos.sh -d -a ${ARCH}"
  echo "Log: build_logs/deps_macos.log"
  nohup env PATH="$HOME/local/bin:$PATH" \
    ./build_release_macos.sh -d -a "${ARCH}" \
    > build_logs/deps_macos.log 2>&1 &
  echo $! > build_logs/deps_macos.pid
  echo "PID $(cat build_logs/deps_macos.pid)"
fi

echo ""
echo "=== DONE prep ==="
echo "When simulator finishes, open WHEN_SIMULATOR_READY.md"
echo "Watch deps: tail -f $ROOT/build_logs/deps_macos.log"
