#!/bin/bash
# build.sh -- WASM/browser build of the Sonic Generations recomp port.
#
# Pipeline:
#   1. Emscripten toolchain (emsdk, pinned via EMSDK_VERSION)
#   2. rexglue-sdk v0.10.0 + submodules + emscripten patch (this dir)
#   3. Stage generated recompiled code + apply the wasm overload rewrite
#   4. CMake configure (SDK as subproject, WebGPU backend, pthreads+JSPI)
#   5. Build -> sonicgenerations.{js,wasm} into web/
#
# Usage:  bash emscripten/build.sh [--jobs N]
#         WASM_CONFIGURE_ONLY=1  -> stop after the CMake configure step
#         WASM_LTO=1             -> enable -O3/-flto (off by default)
#         WASM_NO_CCACHE=1       -> do not use ccache even if installed
# Output: build/web/  ->  copy sonicgenerations.js + sonicgenerations.wasm
#         next to web/index.html and serve with web/serve.py.
set -euo pipefail

PRJ="$(cd "$(dirname "$0")/.." && pwd)"
GAME="${GAME_DIR:-$PRJ/../Sonic-Generations-recomp-android-and-pc-edition}"
SDK_ROOT="${REXGLUE_SDK_DIR:-$PRJ/../rexglue-sdk}"
SDK_VER="v0.10.0"
# NOTE: deliberately NOT named "EMSDK_DIR". Sourcing emsdk_env.sh runs
# `emsdk construct_env`, which emits `unset <VAR>` for every environment
# variable starting with EMSDK_ that emsdk does not itself manage (see
# construct_env_with_vars in emsdk.py). Under `set -u`, any later $EMSDK_DIR
# reference would die with "unbound variable". The workflow's EMSDK_DIR env
# override is still honored -- it is read here, before the source.
WASM_EMSDK_DIR="${WASM_EMSDK_DIR:-${EMSDK_DIR:-$PRJ/../emsdk}}"
# Pin the toolchain. "latest" is fine locally; CI should set an exact version
# so a toolchain rollover cannot silently break a working build.
EMSDK_VERSION="${EMSDK_VERSION:-latest}"
BUILD_DIR="$PRJ/build/web"
PATCH="$PRJ/emscripten/rexglue-sdk-v0.10.0-emscripten.patch"
STAMP="$SDK_ROOT/.emscripten-patched"
JOBS="$(nproc)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs) JOBS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "=== [1/5] Emscripten toolchain (emsdk $EMSDK_VERSION) ==="
if [ ! -x "$WASM_EMSDK_DIR/emsdk" ]; then
  git clone --depth 1 https://github.com/emscripten-core/emsdk.git "$WASM_EMSDK_DIR"
fi
export EMSDK_QUIET=1
# A fresh emsdk clone has no toolchain installed: emsdk_env.sh only puts emcc
# on PATH once install+activate have run, so bootstrap first when needed.
if [ ! -x "$WASM_EMSDK_DIR/upstream/emscripten/emcc" ]; then
  echo "[build] emsdk: installing + activating $EMSDK_VERSION (first run only)"
  if ! "$WASM_EMSDK_DIR/emsdk" install "$EMSDK_VERSION"; then
    echo "ERROR: emsdk install $EMSDK_VERSION failed" >&2
    df -h >&2
    exit 1
  fi
  "$WASM_EMSDK_DIR/emsdk" activate "$EMSDK_VERSION"
fi
# shellcheck disable=SC1091
source "$WASM_EMSDK_DIR/emsdk_env.sh"
if ! command -v emcc >/dev/null 2>&1; then
  echo "ERROR: emcc is not on PATH after sourcing $WASM_EMSDK_DIR/emsdk_env.sh" >&2
  echo "       emsdk state: $(ls "$WASM_EMSDK_DIR" 2>/dev/null | tr '\n' ' ')" >&2
  exit 1
fi
emcc --version | head -1

echo "=== [2/5] rexglue-sdk $SDK_VER + emscripten patch ==="
if [ ! -d "$SDK_ROOT/src" ]; then
  git clone --depth 1 --branch "$SDK_VER" https://github.com/rexglue/rexglue-sdk.git "$SDK_ROOT"
fi
if [ -d "$SDK_ROOT/.git" ]; then
  SDK_DESC="$(git -C "$SDK_ROOT" describe --tags --always 2>/dev/null || echo unknown)"
  echo "[build] SDK tree at: $SDK_DESC"
  if [ "$SDK_DESC" != "$SDK_VER" ] && [ "$SDK_DESC" != "unknown" ]; then
    echo "[build] WARNING: expected $SDK_VER, tree reports $SDK_DESC" >&2
  fi
fi
# Submodules required to compile core + generated code (GPU/video giants are
# pulled only when their backends are enabled; WebGPU needs none of them).
# libmspack/FFmpeg/sdl3 are in the SDK's unconditional REQUIRED_SUBMODULES
# check (thirdparty/CMakeLists.txt) even when the wasm build never links them.
for m in fmt spdlog tomlplusplus simde xxHash utfcpp stb imgui o1heap \
         disruptorplus inja cli11 aes_128 tiny-aes-c crypto pe disasm \
         vulkan-headers spirv-headers glslang renderdoc catch2 \
         libmspack FFmpeg sdl3; do
  git -C "$SDK_ROOT" submodule update --init --depth 1 "thirdparty/$m"
done
# FFmpeg (WMA Pro decoder) is built without a configure step: the submodule
# vendors per-platform config headers but none for Emscripten. Copy the wasm
# config + dispatch stub over the submodule files on every run (idempotent,
# survives SDK cache restores that ship the upstream stubs).
mkdir -p "$SDK_ROOT/thirdparty/FFmpeg"
cp "$PRJ/emscripten/ffmpeg/config_emscripten.h" \
   "$SDK_ROOT/thirdparty/FFmpeg/config_emscripten.h"
cp "$PRJ/emscripten/ffmpeg/config.h" "$SDK_ROOT/thirdparty/FFmpeg/config.h"
echo "[build] FFmpeg wasm config installed"

# The patch stamp holds the patch's SHA-256, NOT a bare "applied" flag. A cache
# restored under a different patch used to keep the old stamp and silently skip
# the new patch, which is exactly how the setFromMaskInt breakage happened.
PATCH_SHA="$(sha256sum "$PATCH" | cut -d' ' -f1)"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$PATCH_SHA" ]; then
  echo "[build] emscripten patch already applied (sha ${PATCH_SHA:0:12})"
else
  echo "[build] applying emscripten patch (sha ${PATCH_SHA:0:12})"
  if git -C "$SDK_ROOT" apply --check --whitespace=nowarn "$PATCH" 2>/dev/null; then
    git -C "$SDK_ROOT" apply --whitespace=nowarn "$PATCH"
  elif git -C "$SDK_ROOT" apply --reverse --check --whitespace=nowarn "$PATCH" 2>/dev/null; then
    echo "[build] patch already present in tree, recording stamp"
  else
    # Stale or partially patched tree from a restored cache: reset and retry.
    echo "[build] resetting SDK tree and retrying"
    git -C "$SDK_ROOT" checkout -- . 2>/dev/null || true
    git -C "$SDK_ROOT" clean -fdq src/graphics/webgpu include/rex/graphics/webgpu 2>/dev/null || true
    rm -f "$SDK_ROOT/src/core/fiber_wasm.cpp" \
          "$SDK_ROOT/include/rex/graphics/webgpu/graphics_system.h"
    if ! git -C "$SDK_ROOT" apply --whitespace=nowarn "$PATCH"; then
      echo "ERROR: patch does not apply -- SDK tree is not pristine $SDK_VER." >&2
      echo "       Delete $SDK_ROOT and re-run to get a clean clone." >&2
      exit 1
    fi
  fi
  printf '%s\n' "$PATCH_SHA" > "$STAMP"
fi

echo "=== [3/5] Stage generated code + wasm overload rewrite ==="
GEN_SRC="$GAME/port/generated/default"
GEN_DST="$BUILD_DIR/generated/default"
if [ ! -f "$GAME/port/src/main.cpp" ] || [ ! -d "$GEN_SRC" ]; then
  echo "ERROR: generated game code not found at $GAME" >&2
  echo "       Expected the Sonic-Generations-recomp checkout with:" >&2
  echo "         $GEN_SRC/*.cpp" >&2
  echo "         $GAME/port/src/main.cpp" >&2
  echo "       Point GAME_DIR at your checkout, e.g.:" >&2
  echo "         GAME_DIR=\$GITHUB_WORKSPACE/game bash harness/emscripten/build.sh" >&2
  exit 1
fi
mkdir -p "$GEN_DST" "$BUILD_DIR/app"
cp "$GEN_SRC"/*.cpp "$GEN_SRC"/*.h "$GEN_DST/"
cp "$GAME/port/src/main.cpp" "$GAME/port/src/sonicgenerations_app.h" "$BUILD_DIR/app/"
cp "$GAME/port/"sonicgenerations_*.toml "$BUILD_DIR/" 2>/dev/null || true
# On wasm+SIMD128 simde maps __m128/__m128i to the same v128_t; the
# movemask_epi8 call sites emitted by the vector builder are rewritten to the
# explicit setFromMaskInt variant added by the patch (see context.h).
# Process substitution, not a pipe, so COUNT survives the loop.
COUNT=0
while IFS= read -r f; do
  sed -i 's/setFromMask(simde_mm_load_si128((simde__m128i\*)/setFromMaskInt(simde_mm_load_si128((simde__m128i*)/g' "$f"
  COUNT=$((COUNT + 1))
done < <(grep -rl 'setFromMask(simde_mm_load_si128((simde__m128i\*)' "$GEN_DST" || true)
echo "[build] setFromMaskInt rewrite applied to $COUNT files"
if [ "$COUNT" -eq 0 ]; then
  echo "[build] WARNING: rewrite matched no files -- generated code may have changed shape" >&2
fi
# Cheap guard against the exact regression that broke CI: the rewrite is only
# valid if the patched header actually provides the method.
if ! grep -q 'setFromMaskInt' "$SDK_ROOT/include/rex/ppc/context.h"; then
  echo "ERROR: $SDK_ROOT/include/rex/ppc/context.h has no setFromMaskInt --" >&2
  echo "       the emscripten patch is not applied. Delete the SDK cache/checkout." >&2
  exit 1
fi

# ccache: only used when available and not opted out. Keyed build-to-build,
# this turns a full 295-TU rebuild into a few minutes of cache hits.
CCACHE_FLAGS=()
if [ "${WASM_NO_CCACHE:-0}" != "1" ] && command -v ccache >/dev/null 2>&1; then
  export CCACHE_BASEDIR="$PRJ"
  export CCACHE_NOHASHDIR=1
  export CCACHE_SLOPPINESS="include_file_ctime,include_file_mtime,time_macros,pch_defines"
  export CCACHE_COMPRESS=1
  ccache --zero-stats || true
  CCACHE_FLAGS=(
    -DCMAKE_C_COMPILER_LAUNCHER=ccache
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
  )
  echo "[build] ccache enabled ($(ccache --version | head -1))"
else
  echo "[build] ccache disabled"
fi

echo "=== [4/5] CMake configure ==="
cmake -B "$BUILD_DIR" -S "$PRJ/emscripten" \
  "${CCACHE_FLAGS[@]}" \
  -DCMAKE_TOOLCHAIN_FILE="$WASM_EMSDK_DIR/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DREXGLUE_SDK_DIR="$SDK_ROOT" \
  -DREXGLUE_APP_SRC_DIR="$BUILD_DIR" \
  -DREXGLUE_USE_WEBGPU=ON \
  -DREXGLUE_ENABLE_TRACY=OFF \
  -DREXGLUE_ENABLE_PERF_COUNTERS=OFF \
  -DREXGLUE_BUILD_TESTS=OFF \
  -DWASM_LTO="${WASM_LTO:-0}"

if [ "${WASM_CONFIGURE_ONLY:-0}" = "1" ]; then
  echo "[build] WASM_CONFIGURE_ONLY=1 -> configure succeeded, skipping build step"
  exit 0
fi

echo "=== [5/5] Build (jobs=$JOBS) ==="
START=$(date +%s)
cmake --build "$BUILD_DIR" -j "$JOBS"
echo "[build] build step took $(( $(date +%s) - START ))s"
if command -v ccache >/dev/null 2>&1; then
  ccache --show-stats || true
fi
echo "[build] done -> $BUILD_DIR/sonicgenerations.{js,wasm}"
