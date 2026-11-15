#!/usr/bin/env bash
# 《刍狗》T4a 一键构建（Linux/macOS）：godot-cpp + sim_core GDExtension -> game/bin
# 依赖：CMake >= 3.22、Ninja、C++17 编译器、Godot 4.5
# 用法：GODOT_CPP_DIR=<godot-cpp 4.5 源码目录> ./build.sh
set -euo pipefail

cd "$(dirname "$0")"
: "${GODOT_CPP_DIR:?请先设置 GODOT_CPP_DIR=godot-cpp 4.5 源码目录}"

BIN="$PWD/bin"
BUILD="$PWD/build"
mkdir -p "$BIN"

build_one() {
  local cfg="$1" target="$2" outname="$3"
  echo "[T4a] 构建 $cfg（$target）..."
  cmake -S gdextension -B "$BUILD/$cfg" -G Ninja \
    -DCMAKE_BUILD_TYPE="$cfg" \
    -DGODOT_CPP_DIR="$GODOT_CPP_DIR" \
    -DGODOTCPP_TARGET="$target"
  cmake --build "$BUILD/$cfg"
  cp "$BUILD/$cfg/libgdsim.so" "$BIN/$outname"
}

build_one Debug template_debug "libgdsim.linux.template_debug.x86_64.so"
build_one Release template_release "libgdsim.linux.template_release.x86_64.so"

echo T4A_BUILD_OK
