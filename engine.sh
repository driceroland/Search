#!/bin/bash
# engine.sh — builds the AI add-on's engine: the small program that runs the
# model for "On this Mac" (see Engine/search-ai-engine.cpp and AIEngine.swift).
#
#   ./engine.sh            both: arm64 (Metal) and x86_64 (CPU)
#   ./engine.sh arm64      one of them
#
# From llama.cpp's source at one pinned commit, fetched here and checked
# against it, built static with nothing that reaches the network compiled
# in, linked with the helper, stripped, and signed with the hardened runtime
# and the App Sandbox (Engine/engine.entitlements) — the Developer ID when
# there is one (SEARCH_SIGN_IDENTITY, or the first found; "-" for none), ad-hoc otherwise,
# which Search accepts only in a test run. Everything goes to build/engine/.
# Notarizing and publishing are the release's, not this script's.
set -euo pipefail
cd "$(dirname "$0")"

LLAMA_TAG="v0.5.0"
LLAMA_COMMIT="7fe450e19305b828c199d602c23a8337aaa1f03b"
OUT="build/engine"
SRC="$OUT/llama.cpp"
IDENTIFIER="com.officecommun.search.ai-engine"
JOBS=$(sysctl -n hw.logicalcpu)
which="${1:-all}"

mkdir -p "$OUT"
if [ ! -d "$SRC/.git" ]; then
  git clone --quiet --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$SRC"
fi
have=$(git -C "$SRC" rev-parse HEAD)
if [ "$have" != "$LLAMA_COMMIT" ]; then
  echo "llama.cpp is at $have, not the pinned $LLAMA_COMMIT — delete $SRC and run again" >&2
  exit 1
fi
if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
  echo "llama.cpp in $SRC has local changes — delete it and run again" >&2
  exit 1
fi

COMMON=(
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_CCACHE=OFF -DGGML_CPU_KLEIDIAI=OFF
  -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_LLGUIDANCE=OFF -DLLAMA_BUILD_MTMD=OFF
  -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
  -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF -DFETCHCONTENT_FULLY_DISCONNECTED=ON
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF
)

IDENTITY="${SEARCH_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"

build() {
  local arch=$1 libs=() frameworks=() flags=()
  local dir="$OUT/build-$arch"
  if [ "$arch" = arm64 ]; then
    flags=(-DCMAKE_OSX_ARCHITECTURES=arm64 -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
    frameworks=(-framework Foundation -framework Metal -framework MetalKit -framework Accelerate)
  else
    flags=(-DCMAKE_OSX_ARCHITECTURES=x86_64 -DGGML_METAL=OFF -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON
           -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON -DGGML_AVX512=OFF)
    frameworks=(-framework Foundation -framework Accelerate)
  fi
  cmake -S "$SRC" -B "$dir" "${COMMON[@]}" "${flags[@]}" > "$dir.log" 2>&1 || { tail -20 "$dir.log"; exit 1; }
  cmake --build "$dir" --config Release -j "$JOBS" >> "$dir.log" 2>&1 || { tail -20 "$dir.log"; exit 1; }
  libs=("$dir/src/libllama.a" "$dir/ggml/src/libggml.a")
  [ "$arch" = arm64 ] && libs+=("$dir/ggml/src/ggml-metal/libggml-metal.a")
  libs+=("$dir/ggml/src/ggml-blas/libggml-blas.a" "$dir/ggml/src/libggml-cpu.a" "$dir/ggml/src/libggml-base.a"
         "$dir/vendor/hash/libvendor-hash.a")

  local exe="$OUT/search-ai-engine-$arch"
  clang++ -std=c++17 -O2 -arch "$arch" -mmacosx-version-min=14.0 \
    -I"$SRC/include" -I"$SRC/ggml/include" -I"$SRC/vendor" \
    Engine/search-ai-engine.cpp -o "$exe" -Wl,-dead_strip \
    -Wl,-sectcreate,__TEXT,__info_plist,Engine/Info.plist \
    "${libs[@]}" "${frameworks[@]}"
  strip -x "$exe"
  if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    codesign --force --timestamp --options runtime --entitlements Engine/engine.entitlements \
      --identifier "$IDENTIFIER" --sign "$IDENTITY" "$exe"
  else
    codesign --force --options runtime --entitlements Engine/engine.entitlements \
      --identifier "$IDENTIFIER" --sign - "$exe"
    echo "note: signed ad-hoc — only a test run of Search will start it"
  fi
  printf '%s  %s bytes  sha256 %s\n' "$exe" "$(stat -f %z "$exe")" "$(shasum -a 256 "$exe" | cut -d' ' -f1)"
}

case "$which" in
  all) build arm64; build x86_64 ;;
  arm64|x86_64) build "$which" ;;
  *) echo "usage: ./engine.sh [arm64|x86_64]" >&2; exit 1 ;;
esac
