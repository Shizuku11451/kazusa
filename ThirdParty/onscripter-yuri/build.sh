#!/bin/bash
# 从源码构建自包含的通用二进制 onsyuri（OnscripterYuri，ONScripter 的增强版）。
#
# SDL2 / SDL2_image / SDL2_mixer / SDL2_ttf / Lua 全部编成 arm64 + x86_64 静态库再链接进去，
# 产物只依赖系统框架，可以直接放进 Kazusa.app。图片用 macOS 自带的 ImageIO 解码，
# 音频只用 SDL_mixer 内置的解码器（WAV / OGG / MP3 / FLAC），MIDI 走系统自带的 AudioToolbox，不引入其他外部库。
#
# 需要：Command Line Tools、cmake（brew install cmake）、git、curl。
# 用法：ThirdParty/onscripter-yuri/build.sh [工作目录]
# 产物：ThirdParty/onscripter-yuri/prebuilt/onsyuri
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-${TMPDIR:-/tmp}/kazusa-onscripter-build}"
PREFIX="$WORK/prefix"
OUT="$HERE/prebuilt"
JOBS="$(sysctl -n hw.ncpu)"

ONSYURI_TAG="v0.7.7beta"
ONSYURI_COMMIT="08f744b31cc1907b66a15f0402e62321a131ed81"
SDL2_TAG="release-2.32.10"
SDL2_IMAGE_TAG="release-2.8.8"
SDL2_MIXER_TAG="release-2.8.1"
SDL2_TTF_TAG="release-2.24.0"
LUA_VERSION="5.4.7"
LUA_SHA256="9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30"

export MACOSX_DEPLOYMENT_TARGET=11.0
ARCHS="arm64;x86_64"
ARCH_FLAGS=(-arch arm64 -arch x86_64)

mkdir -p "$WORK/src" "$PREFIX"
cd "$WORK/src"

clone() { # 目录 仓库 标签 [--recursive]
  if [[ ! -d "$1" ]]; then
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$3" ${4:-} "$2" "$1"
  fi
}

clone onsyuri https://github.com/YuriSizuku/OnscripterYuri.git "$ONSYURI_TAG"
[[ "$(git -C onsyuri rev-parse HEAD)" == "$ONSYURI_COMMIT" ]] || { echo "onsyuri 提交不对" >&2; exit 1; }
# Kazusa 的补丁：把显示出来的句子写到 KAZUSA_TEXT_PIPE 给翻译用（见 README）。每次都从干净的源码打。
git -C onsyuri checkout -q --force "$ONSYURI_COMMIT"
git -C onsyuri clean -qfd src/onsyuri
git -C onsyuri apply "$HERE/kazusa.patch"
clone SDL https://github.com/libsdl-org/SDL.git "$SDL2_TAG"
clone SDL_image https://github.com/libsdl-org/SDL_image.git "$SDL2_IMAGE_TAG"
clone SDL_mixer https://github.com/libsdl-org/SDL_mixer.git "$SDL2_MIXER_TAG"
clone SDL_ttf https://github.com/libsdl-org/SDL_ttf.git "$SDL2_TTF_TAG" --recursive --shallow-submodules

cmake_build() { # 源码目录 [cmake 参数...]
  local src="$1"; shift
  local log="$WORK/build/$src.log"
  mkdir -p "$WORK/build"
  # SDL_ttf 自带的 FreeType 声明的 CMake 最低版本太老，新版 CMake 不认，需要放宽。
  { cmake -S "$src" -B "$WORK/build/$src" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_OSX_ARCHITECTURES="$ARCHS" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" -DBUILD_SHARED_LIBS=OFF "$@" &&
    cmake --build "$WORK/build/$src" -j "$JOBS" &&
    cmake --install "$WORK/build/$src"; } >"$log" 2>&1 || { tail -40 "$log" >&2; echo "✗ $src（完整日志：$log）" >&2; exit 1; }
  echo "✓ $src"
}

cmake_build SDL -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
cmake_build SDL_image -DSDL2IMAGE_BACKEND_IMAGEIO=ON -DSDL2IMAGE_VENDORED=OFF -DSDL2IMAGE_SAMPLES=OFF \
  -DSDL2IMAGE_AVIF=OFF -DSDL2IMAGE_JXL=OFF -DSDL2IMAGE_TIF=OFF -DSDL2IMAGE_WEBP=OFF
cmake_build SDL_mixer -DSDL2MIXER_VENDORED=OFF -DSDL2MIXER_SAMPLES=OFF \
  -DSDL2MIXER_OPUS=OFF -DSDL2MIXER_MOD=OFF -DSDL2MIXER_MIDI_FLUIDSYNTH=OFF -DSDL2MIXER_WAVPACK=OFF \
  -DSDL2MIXER_GME=OFF -DSDL2MIXER_VORBIS=STB -DSDL2MIXER_FLAC_LIBFLAC=OFF -DSDL2MIXER_MP3_MPG123=OFF \
  -DSDL2MIXER_MIDI_TIMIDITY=OFF -DSDL2MIXER_MIDI_NATIVE=ON
# TiMidity 需要另装音色库，macOS 上用不上，而且是 Artistic 许可证，关掉。
cmake_build SDL_ttf -DSDL2TTF_VENDORED=ON -DSDL2TTF_HARFBUZZ=ON -DSDL2TTF_SAMPLES=OFF

# Lua 没有 CMake，直接编。
if [[ ! -f "$PREFIX/lib/liblua.a" ]]; then
  curl -fsSL --retry 5 --retry-all-errors "https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz" -o lua.tar.gz
  echo "$LUA_SHA256  lua.tar.gz" | shasum -a 256 -c - >/dev/null
  rm -rf lua && mkdir lua && tar -xzf lua.tar.gz -C lua --strip-components 1
  mkdir -p "$WORK/build/lua" "$PREFIX/include"
  for f in lua/src/*.c; do
    case "$(basename "$f")" in lua.c|luac.c) continue ;; esac
    clang "${ARCH_FLAGS[@]}" -O2 -DLUA_USE_MACOSX -c "$f" -o "$WORK/build/lua/$(basename "${f%.c}").o"
  done
  libtool -static -o "$PREFIX/lib/liblua.a" "$WORK/build/lua"/*.o
  cp lua/src/{lua.h,luaconf.h,lualib.h,lauxlib.h,lua.hpp} "$PREFIX/include/"
  echo "✓ lua"
fi

# onsyuri 本体：源码列表和宏照搬上游 CMakeLists.txt 的 darwin 配置，去掉 USE_GLES
# （只用于 --sharpness 锐化，macOS 没有原生 GLES）和 USE_FILELOG（会往游戏目录写 stdout.txt / stderr.txt，
# Kazusa 自己会收集输出）。
ONS=onsyuri/src/onsyuri
SOURCES=(
  AnimationInfo coding2utf16 DirectReader DirtyRect FontInfo gbk2utf16 LUAHandler NsaReader
  ONScripter ONScripter_animation ONScripter_command ONScripter_effect ONScripter_effect_breakup
  ONScripter_event ONScripter_file ONScripter_file2 ONScripter_image ONScripter_lut onscripter_main
  ONScripter_rmenu ONScripter_sound ONScripter_text Parallel resize_image SarReader ScriptHandler
  ScriptParser ScriptParser_command sjis2utf16 kazusa_text
  builtin_dll/layer_oldmovie builtin_dll/layer_snow builtin_dll/ONScripter_effect_cascade builtin_dll/ONScripter_effect_trig
)
OBJ="$WORK/build/onsyuri"
mkdir -p "$OBJ"
for s in "${SOURCES[@]}"; do
  clang++ "${ARCH_FLAGS[@]}" -std=c++11 -O2 -w \
    -DMACOSX -DUSE_PARALLEL -DUSE_LUA -DUSE_BUILTIN_LAYER_EFFECTS -DENABLE_1BYTE_CHAR \
    -I"$PREFIX/include" -I"$PREFIX/include/SDL2" \
    -c "$ONS/$s.cpp" -o "$OBJ/$(echo "$s" | tr / _).o" &
done
# 系统自带的 bash 3.2 没有 wait -n，三十几个文件就一起编，逐个 wait 以便拿到失败的返回码。
for pid in $(jobs -p); do wait "$pid"; done

# SDL2 静态库需要的系统框架由 sdl2-config 给出；SDL_image 用 ImageIO，SDL_ttf 自带 FreeType / HarfBuzz。
SDL_LIBS="$("$PREFIX/bin/sdl2-config" --static-libs | sed 's/-lSDL2main//')"
mkdir -p "$OUT"
# shellcheck disable=SC2086
clang++ "${ARCH_FLAGS[@]}" -o "$OUT/onsyuri" "$OBJ"/*.o \
  "$PREFIX/lib/libSDL2_ttf.a" "$PREFIX/lib/libfreetype.a" "$PREFIX/lib/libharfbuzz.a" \
  "$PREFIX/lib/libSDL2_image.a" "$PREFIX/lib/libSDL2_mixer.a" "$PREFIX/lib/liblua.a" \
  $SDL_LIBS -framework ImageIO -framework CoreGraphics -framework CoreServices -lbz2 -lz -liconv
strip -x "$OUT/onsyuri"
cp onsyuri/LICENSE "$HERE/COPYING"
# 静态链接进去的库的许可证（zlib / FTL / MIT），随二进制一起分发。
LIC="$HERE/licenses"
rm -rf "$LIC" && mkdir -p "$LIC"
cp SDL/LICENSE.txt "$LIC/SDL2.txt"
cp SDL_image/LICENSE.txt "$LIC/SDL2_image.txt"
cp SDL_mixer/LICENSE.txt "$LIC/SDL2_mixer.txt"
cp SDL_ttf/LICENSE.txt "$LIC/SDL2_ttf.txt"
cp SDL_ttf/external/freetype/docs/FTL.TXT "$LIC/FreeType.txt"
cp SDL_ttf/external/harfbuzz/COPYING "$LIC/HarfBuzz.txt"
sed -n '/^\* Copyright (C) 1994/,/^\*\*\*\*/p' lua/src/lua.h | sed 's/^\* \{0,1\}//; /^\*\*\*/d' > "$LIC/Lua.txt"
lipo -info "$OUT/onsyuri"
echo "✅ $OUT/onsyuri"
