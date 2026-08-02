#!/usr/bin/env bash
# Combine orca_ios_api + libslic3r + deps into one static lib for Xcode.
set -euo pipefail
export PATH="/usr/bin:/bin:$HOME/local/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build-macos-headless-arm64}"
DEPS_LIB="${2:-$ROOT/deps/build/arm64/OrcaSlicer_dep/usr/local/lib}"
OUTDIR="${BUILD}/engine_bundle"
mkdir -p "$OUTDIR/lib"

LIBS=(
  "$BUILD/src/ios/liborca_ios_api.a"
  "$BUILD/src/libslic3r/liblibslic3r.a"
  "$BUILD/src/libslic3r/liblibslic3r_cgal.a"
  "$BUILD/deps_src/libnest2d/liblibnest2d.a"
  "$BUILD/deps_src/admesh/libadmesh.a"
  "$BUILD/deps_src/clipper/libclipper.a"
  "$BUILD/deps_src/clipper2/libClipper2.a"
  "$BUILD/deps_src/miniz/libminiz_static.a"
  "$BUILD/deps_src/glu-libtess/libglu-libtess.a"
  "$BUILD/deps_src/mcut/libmcut.a"
  "$BUILD/deps_src/qoi/libqoi.a"
  "$BUILD/lib/libsemver.a"
)

if [[ -d "$DEPS_LIB" ]]; then
  while IFS= read -r -d '' f; do
    base=$(basename "$f")
    case "$base" in
      *python*|*GLEW*|*glfw*|*wx*|*eigen_blas*|*eigen_lapack*) continue ;;
      *.a) LIBS+=("$f") ;;
    esac
  done < <(find "$DEPS_LIB" -maxdepth 1 -name 'lib*.a' -print0 2>/dev/null || true)
fi

EXIST=()
for L in "${LIBS[@]}"; do
  [[ -f "$L" ]] && EXIST+=("$L")
done

echo "Bundling ${#EXIST[@]} archives → $OUTDIR/lib/liborca_engine.a"
printf '%s\n' "${EXIST[@]}" > "$OUTDIR/lib_list.txt"
/usr/bin/libtool -static -o "$OUTDIR/lib/liborca_engine.a" "${EXIST[@]}"
ls -lh "$OUTDIR/lib/liborca_engine.a"
nm -gU "$OUTDIR/lib/liborca_engine.a" 2>/dev/null | grep -E 'orca_session_create|orca_version' | head
echo "OK"
