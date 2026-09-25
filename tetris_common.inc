// tetris_common.inc：終端機版、視窗版與遊戲規則共用的常數與巨集。用 .include 引進來。

    .equ BW, 10              // 場地寬（格）
    .equ BH, 20              // 場地高（格）

// 動作代號，傳給 game_action
    .equ ACT_LEFT, 1
    .equ ACT_RIGHT, 2
    .equ ACT_DOWN, 3
    .equ ACT_ROTATE, 4
    .equ ACT_DROP, 5

// 把符號位址載入暫存器（Mach-O 沒有 ldr x0, =sym 這種寫法）
.macro LA reg, sym
    adrp \reg, \sym@PAGE
    add  \reg, \reg, \sym@PAGEOFF
.endm
