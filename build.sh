#!/bin/sh
# 一次編譯兩個版本：終端機版 tetris、視窗版 tetris_window。
set -e
cd "$(dirname "$0")"
clang tetris_core.s tetris.s -o tetris
clang tetris_core.s tetris_window.s -framework Cocoa -o tetris_window
echo "完成：./tetris（終端機版）、./tetris_window（視窗版）"
