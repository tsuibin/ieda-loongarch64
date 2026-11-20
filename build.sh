#!/usr/bin/env bash
# Reproducible iEDA build on loongarch64 + AOSC OS 14.
# Mirrors the steps in README.md (sections 2-5). Run from anywhere.
set -euo pipefail

IEDA_DIR="${IEDA_DIR:-$HOME/iEDA}"
OPT_ROOT="${OPT_ROOT:-$HOME/opt}"
DEPS_DIR="${DEPS_DIR:-/tmp/ieda-deps}"

command -v oma >/dev/null || { echo "oma not found (AOSC OS required)" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "dpkg-deb not found" >&2; exit 1; }

[ -d "$IEDA_DIR/.git" ] || {
  echo "iEDA source not found at $IEDA_DIR" >&2
  echo "git clone --depth 1 https://gitee.com/oscc-project/iEDA.git $IEDA_DIR" >&2
  exit 1
}

cd "$IEDA_DIR"

echo "==> [1/5] applying upstream patches"
for p in "$HOME/ieda-loongarch64"/patches/*.patch; do
  [ -e "$p" ] || continue
  echo "    $p"
  patch -p1 --forward --batch < "$p" || true
done

echo "==> [2/5] downloading user-level dependencies (no root)"
mkdir -p "$DEPS_DIR"
for pkg in eigen-3 zlib-static; do
  if ! ls "$DEPS_DIR"/${pkg}_*.deb >/dev/null 2>&1; then
    oma download -p "$DEPS_DIR" "$pkg"
  fi
done
mkdir -p "$OPT_ROOT/eigen3" "$OPT_ROOT/zlib-static"
dpkg-deb -x "$DEPS_DIR"/eigen-3_*.deb "$OPT_ROOT/eigen3"
dpkg-deb -x "$DEPS_DIR"/zlib-static_*.deb "$OPT_ROOT/zlib-static"

echo "==> [3/5] cmake configure"
CC=gcc CXX=g++ \
CMAKE_PREFIX_PATH="$OPT_ROOT/eigen3/usr" \
CMAKE_LIBRARY_PATH="$OPT_ROOT/zlib-static/usr/lib" \
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS="-include cstdint"

echo "==> [4/5] build iir Rust static library (ExternalProject not auto-pulled)"
cmake --build build --target iir

echo "==> [5/5] build iEDA"
cmake --build build -j"$(nproc)" --target iEDA

echo "==> verify"
mkdir -p bin
[ -e bin/iEDA ] || ln -s ../build/src/apps/iEDA bin/iEDA
./bin/iEDA -script scripts/hello.tcl
