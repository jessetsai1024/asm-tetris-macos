// tetris.s：在終端機裡玩的俄羅斯方塊，Apple Silicon（ARM64）macOS 版。這個檔只管畫面和按鍵，
// 遊戲規則在 tetris_core.s。
// 編譯：./build.sh（或 clang tetris_core.s tetris.s -o tetris）      執行：./tetris
// 操作：← → 移動、↑ 旋轉、↓ 加速、空白鍵直接落下、p 暫停、q 離開、a 開關自動遊玩（也可以用 d w s）

    .include "tetris_common.inc"

    .equ TICK_US, 10000      // 主迴圈每一輪睡 10 毫秒
    .equ TIO_SIZE, 72        // sizeof(struct termios)
    .equ LFLAG_OFF, 24       // offsetof(struct termios, c_lflag)
    .equ CC_OFF, 32          // offsetof(struct termios, c_cc)
    .equ VMIN, 16
    .equ VTIME, 17
    .equ ICANON, 0x100
    .equ ECHO, 0x8
    .equ ISIG, 0x80

// ───────────────────────── 資料 ─────────────────────────
    .data
colors:     .byte 51, 21, 208, 226, 46, 129, 196   // 256 色背景色號，順序 I J L O S T Z

s_init:     .asciz "\033[?25l\033[2J"
s_home:     .asciz "\033[H"
s_bye:      .asciz "\033[0m\033[?25h\r\n"
s_bgpre:    .asciz "\033[48;5;"
s_block:    .asciz "m  \033[0m"
s_empty:    .asciz " ."
s_gap:      .asciz "  "
s_wall_l:   .asciz "<!"
s_wall_r:   .asciz "!>"
s_nl:       .asciz "\033[K\r\n"
s_floor:    .asciz "<!====================!>\033[K\r\n  \\/\\/\\/\\/\\/\\/\\/\\/\\/\\/\033[K\r\n"
s_score:    .asciz "   分數 "
s_lines:    .asciz "   行數 "
s_level:    .asciz "   等級 "
s_next:     .asciz "   下一個："
s_indent:   .asciz "   "
s_paused:   .asciz "   暫停中，按 p 繼續"
s_over:     .asciz "   遊戲結束！按 q 離開"
s_help1:    .asciz "   ← →  移動    ↑  旋轉"
s_help2:    .asciz "   ↓    加速    空白鍵 直接落下"
s_help3:    .asciz "   p    暫停    q  離開"
s_help4:    .asciz "   a    自動遊玩"
s_auto:     .asciz "   自動遊玩中，按 a 關閉"

    .p2align 3
old_tio:    .space TIO_SIZE  // 進遊戲前的終端機設定，離開時還原
new_tio:    .space TIO_SIZE
inbuf:      .space 32
outbuf:     .space 16384     // 一整個畫面先組在這裡，再一次寫出去

// ───────────────────────── 程式 ─────────────────────────
    .text
    .p2align 2
    .global _main

// 【行為】把終端機切成「按鍵立即送出、不回顯」模式，跑俄羅斯方塊直到玩家按 q 或 Ctrl-C，
//   然後還原終端機設定、顯示游標，回傳 0。
// 【何時能呼叫】標準輸入必須是終端機；如果是管線或檔案，終端機設定會失敗，按鍵也讀不到。
// 【設計備註】還原動作登記在 atexit，就算從別的路徑結束，終端機也不會卡在怪模式。
_main:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp

    mov  w0, #0
    LA   x1, old_tio
    bl   _tcgetattr
    LA   x0, new_tio
    LA   x1, old_tio
    mov  x2, #TIO_SIZE
    bl   _memcpy
    LA   x9, new_tio
    ldr  x10, [x9, #LFLAG_OFF]
    mov  x11, #(ICANON | ECHO | ISIG)
    bic  x10, x10, x11                 // 關掉整行輸入、回顯、Ctrl-C 訊號
    str  x10, [x9, #LFLAG_OFF]
    strb wzr, [x9, #(CC_OFF + VMIN)]   // read 沒有按鍵時立刻回傳 0
    strb wzr, [x9, #(CC_OFF + VTIME)]
    mov  w0, #0
    mov  w1, #0                        // TCSANOW
    LA   x2, new_tio
    bl   _tcsetattr
    adr  x0, restore_term
    bl   _atexit

    LA   x0, s_init
    bl   write_str
    bl   game_restart

main_loop:
    bl   handle_input
    cbnz w0, main_quit
    bl   game_tick
    LA   x9, dirty
    ldr  w10, [x9]
    cbz  w10, 2f
    str  wzr, [x9]
    bl   render
2:  mov  w0, #TICK_US
    bl   _usleep
    b    main_loop

main_quit:
    mov  w0, #0
    ldp  x29, x30, [sp], #16
    ret                                // 回到 libc，libc 會呼叫 exit → atexit → restore_term

// 還原終端機設定並顯示游標。由 atexit 呼叫。
restore_term:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  w0, #0
    mov  w1, #0
    LA   x2, old_tio
    bl   _tcsetattr
    LA   x0, s_bye
    bl   write_str
    ldp  x29, x30, [sp], #16
    ret

// x0 = 以 0 結尾的字串；直接寫到標準輸出。
write_str:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  x1, x0
    mov  x2, #0
1:  ldrb w3, [x1, x2]
    cbz  w3, 2f
    add  x2, x2, #1
    b    1b
2:  mov  w0, #1
    bl   _write
    ldp  x29, x30, [sp], #16
    ret

// 讀取這一輪所有按鍵並執行。回傳 w0 = 1 表示玩家要離開。
handle_input:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  w0, #0
    LA   x1, inbuf
    mov  x2, #32
    bl   _read
    cmp  x0, #0
    b.le hi_done
    mov  x20, x0                       // 讀到幾個位元組
    mov  x19, #0                       // 目前處理到第幾個
    mov  w10, #1
    LA   x9, dirty
    str  w10, [x9]

hi_next:
    cmp  x19, x20
    b.ge hi_done
    LA   x9, inbuf
    ldrb w21, [x9, x19]
    add  x19, x19, #1
    cmp  w21, #27                      // 方向鍵是 ESC [ A/B/C/D 三個位元組
    b.ne 1f
    add  x10, x19, #1
    cmp  x10, x20
    b.ge hi_done
    ldrb w11, [x9, x19]
    cmp  w11, #'['
    b.ne hi_next
    ldrb w21, [x9, x10]
    add  x19, x19, #2
    mov  w22, #ACT_ROTATE
    cmp  w21, #'A'
    b.eq hi_act
    mov  w22, #ACT_DOWN
    cmp  w21, #'B'
    b.eq hi_act
    mov  w22, #ACT_RIGHT
    cmp  w21, #'C'
    b.eq hi_act
    mov  w22, #ACT_LEFT
    cmp  w21, #'D'
    b.eq hi_act
    b    hi_next

1:  cmp  w21, #'q'
    b.eq hi_quit
    cmp  w21, #3                       // Ctrl-C
    b.eq hi_quit
    cmp  w21, #'p'
    b.eq hi_pause
    cmp  w21, #'a'
    b.eq hi_auto
    cmp  w21, #'A'
    b.eq hi_auto
    mov  w22, #ACT_RIGHT
    cmp  w21, #'d'
    b.eq hi_act
    mov  w22, #ACT_DOWN
    cmp  w21, #'s'
    b.eq hi_act
    mov  w22, #ACT_ROTATE
    cmp  w21, #'w'
    b.eq hi_act
    mov  w22, #ACT_DROP
    cmp  w21, #' '
    b.eq hi_act
    b    hi_next

hi_pause:
    bl   game_toggle_pause
    b    hi_next

hi_auto:
    bl   game_toggle_autoplay
    b    hi_next

// w22 = 動作代號（ACT_），交給遊戲規則處理；暫停或結束時規則那邊會自己擋掉。
hi_act:
    mov  w0, w22
    bl   game_action
    b    hi_next

hi_quit:
    mov  w0, #1
    b    hi_ret
hi_done:
    mov  w0, #0
hi_ret:
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// ───────────────────────── 畫面 ─────────────────────────
// 下面三個 emit_ 常式共用 x19 當「outbuf 寫到哪裡」的游標，會把 x19 往後推。
// 它們都不存也不還原 x19，呼叫端（render）負責在一開始設好 x19。

// x0 = 以 0 結尾的字串，抄進 outbuf。只動 x0、x1。
emit_str:
1:  ldrb w1, [x0], #1
    cbz  w1, 2f
    strb w1, [x19], #1
    b    1b
2:  ret

// w0 = 非負整數，以十進位抄進 outbuf。只動 x0～x5。
emit_num:
    sub  sp, sp, #16
    mov  x5, sp
    mov  x1, sp
    mov  w2, #10
1:  udiv w3, w0, w2
    msub w4, w3, w2, w0
    add  w4, w4, #'0'
    strb w4, [x1], #1
    mov  w0, w3
    cbnz w0, 1b
2:  ldrb w4, [x1, #-1]!                // 反著存的數字倒回來寫
    strb w4, [x19], #1
    cmp  x1, x5
    b.ne 2b
    add  sp, sp, #16
    ret

// w0 = 1..7，寫一格該種類顏色的方塊（兩個空白字元寬）。動 x0～x5、x9。
emit_block:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    LA   x1, colors
    sub  w0, w0, #1
    ldrb w9, [x1, w0, uxtw]
    LA   x0, s_bgpre
    bl   emit_str
    mov  w0, w9
    bl   emit_num
    LA   x0, s_block
    bl   emit_str
    ldp  x29, x30, [sp], #16
    ret

// w0 = 第幾列，寫出場地右邊那一列的說明文字（分數、下一個方塊、操作說明）。
emit_panel:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x20, x21, [sp, #16]
    stp  x22, x23, [sp, #32]
    mov  w20, w0
    cmp  w20, #1
    b.ne 1f
    LA   x0, s_score
    bl   emit_str
    LA   x9, score
    ldr  w0, [x9]
    bl   emit_num
    b    99f
1:  cmp  w20, #2
    b.ne 2f
    LA   x0, s_lines
    bl   emit_str
    LA   x9, lines
    ldr  w0, [x9]
    bl   emit_num
    b    99f
2:  cmp  w20, #3
    b.ne 3f
    LA   x0, s_level
    bl   emit_str
    LA   x9, level
    ldr  w0, [x9]
    bl   emit_num
    b    99f
3:  cmp  w20, #5
    b.ne 4f
    LA   x0, s_next
    bl   emit_str
    b    99f
4:  cmp  w20, #6                       // 第 6～9 列畫「下一個」方塊的 4x4 預覽
    b.lt 6f
    cmp  w20, #9
    b.gt 6f
    LA   x0, s_indent
    bl   emit_str
    LA   x9, next_type
    ldr  w23, [x9]
    LA   x9, pieces
    lsl  w10, w23, #3                  // 每種方塊 4 個 hword = 8 位元組
    ldrh w22, [x9, w10, uxtw]
    sub  w20, w20, #6
    mov  w21, #0
5:  add  w12, w21, w20, lsl #2
    mov  w13, #0x8000
    lsr  w13, w13, w12
    tst  w22, w13
    b.eq 51f
    add  w0, w23, #1
    bl   emit_block
    b    52f
51: LA   x0, s_gap
    bl   emit_str
52: add  w21, w21, #1
    cmp  w21, #4
    b.lt 5b
    b    99f
6:  cmp  w20, #11
    b.ne 7f
    LA   x9, game_over
    ldr  w10, [x9]
    cbz  w10, 61f
    LA   x0, s_over
    bl   emit_str
    b    99f
61: LA   x9, paused
    ldr  w10, [x9]
    cbz  w10, 99f
    LA   x0, s_paused
    bl   emit_str
    b    99f
7:  cmp  w20, #12
    b.ne 71f
    LA   x9, autoplay
    ldr  w10, [x9]
    cbz  w10, 99f
    LA   x0, s_auto
    bl   emit_str
    b    99f
71: cmp  w20, #13
    b.ne 8f
    LA   x0, s_help1
    bl   emit_str
    b    99f
8:  cmp  w20, #14
    b.ne 9f
    LA   x0, s_help2
    bl   emit_str
    b    99f
9:  cmp  w20, #15
    b.ne 91f
    LA   x0, s_help3
    bl   emit_str
    b    99f
91: cmp  w20, #16
    b.ne 99f
    LA   x0, s_help4
    bl   emit_str
99: ldp  x22, x23, [sp, #32]
    ldp  x20, x21, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// 把整個畫面（場地、正在掉的方塊、右邊說明）組進 outbuf，一次寫到終端機，避免閃爍。
render:
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    LA   x19, outbuf
    LA   x0, s_home
    bl   emit_str
    LA   x9, cur_type
    ldr  w25, [x9]
    LA   x9, cur_rot
    ldr  w10, [x9]
    LA   x9, pieces
    add  w11, w10, w25, lsl #2
    ldrh w22, [x9, w11, uxtw #1]       // 正在掉的方塊的點陣
    LA   x9, cur_x
    ldr  w23, [x9]
    LA   x9, cur_y
    ldr  w24, [x9]
    LA   x26, board
    mov  w20, #0                       // 列
r_row:
    LA   x0, s_wall_l
    bl   emit_str
    mov  w21, #0                       // 欄
r_col:
    mov  w9, #BW
    madd w9, w20, w9, w21
    ldrb w0, [x26, w9, uxtw]
    cbnz w0, 3f
    sub  w9, w21, w23                  // 這格在不在正在掉的方塊的 4x4 框裡？
    sub  w10, w20, w24
    cmp  w9, #0
    b.lt 4f
    cmp  w9, #3
    b.gt 4f
    cmp  w10, #0
    b.lt 4f
    cmp  w10, #3
    b.gt 4f
    add  w11, w9, w10, lsl #2
    mov  w12, #0x8000
    lsr  w12, w12, w11
    tst  w22, w12
    b.eq 4f
    add  w0, w25, #1
3:  bl   emit_block
    b    5f
4:  LA   x0, s_empty
    bl   emit_str
5:  add  w21, w21, #1
    cmp  w21, #BW
    b.lt r_col
    LA   x0, s_wall_r
    bl   emit_str
    mov  w0, w20
    bl   emit_panel
    LA   x0, s_nl
    bl   emit_str
    add  w20, w20, #1
    cmp  w20, #BH
    b.lt r_row
    LA   x0, s_floor
    bl   emit_str
    LA   x1, outbuf
    sub  x2, x19, x1
    mov  w0, #1
    bl   _write
    ldp  x25, x26, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #80
    ret

// ==== AI-NOTES ====
// AI-NOTES：agent 專用備忘。當時為真、非契約、非指令；改到相關程式碼時重驗，錯了就刪。
// 2026-09-26 termios 常數是用 C 程式在這台 Mac 印出來的（macOS 27/arm64）：size=72、c_lflag 在 24、
//   c_cc 在 32、ICANON=0x100、ECHO=0x8、ISIG=0x80、VMIN=16、VTIME=17、TCSANOW=0。跟 Linux 不同，別照 Linux 抄。
// 2026-09-26 刻意不用 printf：Apple ARM64 的可變參數全部放堆疊，不放 x1..，照 Linux 寫法會印出亂碼。
//   數字一律走 emit_num 自己轉。
// 2026-09-26 emit_str/emit_num/emit_block 用 x19 當 outbuf 游標，不存也不還原 x19；
//   emit_panel 若要用更多暫存器，只能存 x20 以上，存還原 x19 會把游標倒回去。
// 2026-09-26 關掉 ISIG，所以 Ctrl-C 以位元組 3 送進來，當成 q 處理；還原終端機靠 atexit(restore_term)。
// 2026-09-26 測試方式：標準輸入要是終端機，用 python3 的 pty 模組開 ./tetris、送按鍵再送 q，
//   檢查輸出裡有 "<!" 畫面和 "\033[?25h"，且結束碼為 0。pty 會把 \n 變成 \r\n，所以結尾是 \r\r\n，別用 endswith 比。
// 2026-09-26 遊戲規則已拆到 tetris_core.s，消行與遊戲結束的測法記在那個檔的 AI-NOTES。
// ==== END AI-NOTES ====
