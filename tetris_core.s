// tetris_core.s：俄羅斯方塊的遊戲規則，不管畫面也不管按鍵。
// 終端機版（tetris.s）和視窗版（tetris_window.s）都連結這一份。
// 【職責】保存遊戲狀態（場地、正在掉的方塊、分數），執行移動、旋轉、落下、消行、升級。
//   刻意不做任何輸出入：畫面由前端讀下面匯出的狀態變數自己畫，按鍵由前端翻成動作代號再呼叫 game_action。
// 【生命週期】前端先呼叫一次 game_restart，之後每 10 毫秒呼叫一次 game_tick。
//   所有常式都只能在同一條執行緒上呼叫，沒有鎖。
// 【狀態】進行中 → 暫停（game_toggle_pause 來回切）；進行中 → 遊戲結束（新方塊一出來就被擋住）。
//   遊戲結束後只有 game_restart 能回到進行中。
//   另外有一個跟上面無關的開關「自動遊玩」（game_toggle_autoplay），打開時電腦替玩家移動和旋轉。

    .include "tetris_common.inc"

// ───────────────────────── 匯出的狀態 ─────────────────────────
// 前端只讀這些變數來畫畫面；要改狀態請走下面的常式。
    .global board, pieces, cur_type, cur_rot, cur_x, cur_y, next_type
    .global score, lines, level, game_over, paused, dirty, autoplay

    .data
    .p2align 3
// 正在掉的方塊種類，0..6，順序 I J L O S T Z。
cur_type:   .word 0
// 正在掉的方塊方向，0..3。
cur_rot:    .word 0
// 正在掉的方塊 4x4 框左上角的欄，可能是負的。
cur_x:      .word 0
// 正在掉的方塊 4x4 框左上角的列。
cur_y:      .word 0
// 下一個方塊的種類，0..6。
next_type:  .word 0
// 目前分數。
score:      .word 0
// 目前總共消了幾行。
lines:      .word 0
// 目前等級，從 1 開始，每消 10 行加 1。
level:      .word 1
// 1 = 遊戲結束，0 = 還沒。
game_over:  .word 0
// 1 = 暫停中，0 = 進行中。
paused:     .word 0
// 狀態有變就被設成 1，表示畫面該重畫；由前端畫完後自己清回 0。
dirty:      .word 1
// 1 = 自動遊玩開著，0 = 關著。重新開始不會改變它。
autoplay:   .word 0

drop_timer: .word 0          // 距離上次自然落下過了幾輪
ai_timer:   .word 0          // 距離電腦上次動作過了幾輪
ai_planned: .word 0          // 1 = 這個方塊已經算好要放哪裡
ai_rot:     .word 0          // 電腦選好的方向
ai_x:       .word 0          // 電腦選好的欄
line_pts:   .word 0, 100, 300, 500, 800   // 一次消 0～4 行的基本分

// 7 種方塊 × 4 個方向的 4x4 點陣，每個是一個 16 位元的數。
// 0x8000 是框的左上角，往右、往下依序是較低的位元；第 t 種第 r 個方向在第 (t×4 + r) 個。
pieces:
    .hword 0x0F00, 0x2222, 0x00F0, 0x4444   // I
    .hword 0x44C0, 0x8E00, 0x6440, 0x0E20   // J
    .hword 0x4460, 0x0E80, 0xC440, 0x2E00   // L
    .hword 0xCC00, 0xCC00, 0xCC00, 0xCC00   // O
    .hword 0x06C0, 0x8C40, 0x6C00, 0x4620   // S
    .hword 0x0E40, 0x4C40, 0x4E00, 0x4640   // T
    .hword 0x0C60, 0x4C80, 0xC600, 0x2640   // Z

kicks:      .byte 0, -1, 1, -2, 2          // 旋轉卡牆時依序試的左右位移

// 場地，10 欄 × 20 列，一列接一列排；第 y 列第 x 欄在第 (y×10 + x) 個位元組。
// 0 = 空格，1..7 = 已經固定的方塊，值是種類 + 1。
board:      .space BW*BH

ai_sim:     .space BW*BH     // 電腦試放方塊用的場地副本

// ───────────────────────── 匯出的常式 ─────────────────────────
    .text
    .p2align 2
    .global game_restart, game_action, game_toggle_pause, game_toggle_autoplay, game_tick

    .equ AI_DELAY, 6         // 自動遊玩時電腦每 6 輪（60 毫秒）動一步，讓人看得到它在做什麼

// 【行為】清空場地、分數、行數，等級回到 1，取消暫停與遊戲結束，抽出第一個和下一個方塊，並設定 dirty。
// 【何時能呼叫】任何時候都可以；開始遊戲前一定要先呼叫一次，否則 next_type 永遠是 I。
game_restart:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    LA   x0, board
    mov  x1, #(BW*BH)
    bl   _bzero
    LA   x9, score
    str  wzr, [x9]
    LA   x9, lines
    str  wzr, [x9]
    LA   x9, game_over
    str  wzr, [x9]
    LA   x9, paused
    str  wzr, [x9]
    LA   x9, drop_timer
    str  wzr, [x9]
    mov  w10, #1
    LA   x9, level
    str  w10, [x9]
    mov  w0, #7
    bl   _arc4random_uniform
    LA   x9, next_type
    str  w0, [x9]
    bl   spawn
    mov  w10, #1
    LA   x9, dirty
    str  w10, [x9]
    ldp  x29, x30, [sp], #16
    ret

// 【行為】w0 = 動作代號（見 tetris_common.inc 的 ACT_）：
//   左移、右移：放得下才移。加速：往下一格並加 1 分，到底就落地。
//   旋轉：卡牆時依序試左右挪 1、2 格，都不行就不轉。直接落下：掉到底、每格 2 分，然後落地。
//   落地會消行、算分、升級、換下一個方塊，可能因此遊戲結束。有執行動作就設定 dirty。
// 【何時能呼叫】任何時候；暫停中或遊戲結束時什麼都不做。不認得的代號也什麼都不做。
game_action:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    LA   x9, game_over
    ldr  w10, [x9]
    cbnz w10, 9f
    LA   x9, paused
    ldr  w10, [x9]
    cbnz w10, 9f
    mov  w10, #1
    LA   x9, dirty
    str  w10, [x9]
    cmp  w0, #ACT_LEFT
    b.ne 2f
    mov  w0, #-1
    mov  w1, #0
    mov  w2, #0
    bl   try_move
    b    9f
2:  cmp  w0, #ACT_RIGHT
    b.ne 3f
    mov  w0, #1
    mov  w1, #0
    mov  w2, #0
    bl   try_move
    b    9f
3:  cmp  w0, #ACT_DOWN
    b.ne 4f
    bl   soft_drop
    b    9f
4:  cmp  w0, #ACT_ROTATE
    b.ne 5f
    bl   rotate
    b    9f
5:  cmp  w0, #ACT_DROP
    b.ne 9f
    bl   hard_drop
9:  ldp  x29, x30, [sp], #16
    ret

// 【行為】在暫停與進行中之間切換，並設定 dirty。
// 【何時能呼叫】任何時候；遊戲結束時什麼都不做。
game_toggle_pause:
    LA   x9, game_over
    ldr  w10, [x9]
    cbnz w10, 1f
    LA   x9, paused
    ldr  w10, [x9]
    eor  w10, w10, #1
    str  w10, [x9]
    mov  w10, #1
    LA   x9, dirty
    str  w10, [x9]
1:  ret

// 【行為】打開或關掉自動遊玩，並設定 dirty。打開後，電腦會替目前這個方塊重新選位置。
// 【何時能呼叫】任何時候都可以，暫停中或遊戲結束時也能切換，只是要等恢復進行才會開始動。
game_toggle_autoplay:
    LA   x9, autoplay
    ldr  w10, [x9]
    eor  w10, w10, #1
    str  w10, [x9]
    LA   x9, ai_planned
    str  wzr, [x9]
    LA   x9, ai_timer
    str  wzr, [x9]
    mov  w10, #1
    LA   x9, dirty
    str  w10, [x9]
    ret

// 【行為】時間往前走一輪。累積到該落下的輪數時，方塊往下一格（到底就落地）並設定 dirty。
//   第 1 級每 50 輪落一格，每升一級少 5 輪，最少 5 輪。
//   自動遊玩開著時，電腦每 6 輪做一步：先轉到選好的方向，再左右移到選好的欄，最後直接落下。
//   自然落下照常進行，所以等級高的時候電腦可能來不及移到位置。
// 【何時能呼叫】前端每 10 毫秒呼叫一次，速度才會對；暫停中或遊戲結束時什麼都不做。
game_tick:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    LA   x9, game_over
    ldr  w10, [x9]
    cbnz w10, 1f
    LA   x9, paused
    ldr  w10, [x9]
    cbnz w10, 1f
    LA   x9, autoplay
    ldr  w10, [x9]
    cbz  w10, 2f
    bl   ai_step
    LA   x9, game_over                 // 電腦剛剛的落下可能讓遊戲結束
    ldr  w10, [x9]
    cbnz w10, 1f
2:  bl   gravity
1:  ldp  x29, x30, [sp], #16
    ret

// ───────────────────────── 內部常式 ─────────────────────────

// w0 = 種類、w1 = 方向、w2 = 欄、w3 = 列。回傳 w0 = 1 表示撞牆、撞底或疊到方塊。
// 只動 x9～x16，不呼叫別人。
collides:
    LA   x9, pieces
    add  w10, w1, w0, lsl #2
    ldrh w10, [x9, w10, uxtw #1]       // 這個方向的點陣
    LA   x11, board
    mov  w12, #0                       // i = 0..15
1:  mov  w13, #0x8000
    lsr  w13, w13, w12
    tst  w10, w13
    b.eq 2f
    and  w14, w12, #3
    add  w14, w14, w2                  // 欄
    lsr  w15, w12, #2
    add  w15, w15, w3                  // 列
    cmp  w14, #0
    b.lt 9f
    cmp  w14, #BW
    b.ge 9f
    cmp  w15, #BH
    b.ge 9f
    cmp  w15, #0
    b.lt 2f                            // 還在場地上方，不算撞
    mov  w16, #BW
    madd w16, w15, w16, w14
    ldrb w16, [x11, w16, uxtw]
    cbnz w16, 9f
2:  add  w12, w12, #1
    cmp  w12, #16
    b.lt 1b
    mov  w0, #0
    ret
9:  mov  w0, #1
    ret

// w0 = 左右位移、w1 = 上下位移、w2 = 旋轉量。放得下就真的移過去並回傳 w0 = 1，放不下什麼都不改、回傳 0。
try_move:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    LA   x9, cur_x
    ldr  w10, [x9]
    add  w19, w10, w0                  // 新的欄
    LA   x9, cur_y
    ldr  w10, [x9]
    add  w20, w10, w1                  // 新的列
    LA   x9, cur_rot
    ldr  w10, [x9]
    add  w10, w10, w2
    and  w21, w10, #3                  // 新的方向
    LA   x9, cur_type
    ldr  w0, [x9]
    mov  w1, w21
    mov  w2, w19
    mov  w3, w20
    bl   collides
    cbnz w0, 1f
    LA   x9, cur_x
    str  w19, [x9]
    LA   x9, cur_y
    str  w20, [x9]
    LA   x9, cur_rot
    str  w21, [x9]
    mov  w0, #1
    b    2f
1:  mov  w0, #0
2:  ldr  x21, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// 旋轉；卡牆時依序試著往左右挪 1、2 格（簡單的踢牆）。
rotate:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    mov  w19, #0
1:  LA   x9, kicks
    ldrsb w0, [x9, w19, uxtw]
    mov  w1, #0
    mov  w2, #1
    bl   try_move
    cbnz w0, 2f
    add  w19, w19, #1
    cmp  w19, #5
    b.lt 1b
2:  ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// 把目前方塊寫進場地。
lock_piece:
    LA   x0, board
    LA   x9, cur_type
    ldr  w1, [x9]
    LA   x9, cur_rot
    ldr  w2, [x9]
    LA   x9, cur_x
    ldr  w3, [x9]
    LA   x9, cur_y
    ldr  w4, [x9]
    b    stamp

// x0 = 場地（board 或 ai_sim）、w1 = 種類、w2 = 方向、w3 = 欄、w4 = 列：把方塊寫進去，值是種類 + 1。
// 場地上方（列為負）的格子略過。不檢查碰撞。只動 x9～x17，不呼叫別人。
stamp:
    LA   x9, pieces
    add  w10, w2, w1, lsl #2
    ldrh w10, [x9, w10, uxtw #1]
    add  w17, w1, #1
    mov  w12, #0
1:  mov  w13, #0x8000
    lsr  w13, w13, w12
    tst  w10, w13
    b.eq 2f
    and  w14, w12, #3
    add  w14, w14, w3
    lsr  w15, w12, #2
    add  w15, w15, w4
    cmp  w15, #0
    b.lt 2f
    mov  w16, #BW
    madd w16, w15, w16, w14
    strb w17, [x0, w16, uxtw]
2:  add  w12, w12, #1
    cmp  w12, #16
    b.lt 1b
    ret

// 消掉所有滿的行，上面的往下掉。回傳 w0 = 消掉幾行。
clear_lines:
    LA   x9, board
    mov  w10, #0                       // 消掉的行數
    mov  w11, #(BH - 1)                // 從最底下一行往上檢查
1:  cmp  w11, #0
    b.lt 8f
    mov  w12, #BW
    mul  w13, w11, w12                 // 這一行的起點
    mov  w14, #0
2:  add  w15, w13, w14
    ldrb w15, [x9, w15, uxtw]
    cbz  w15, 5f                       // 有空格，不是滿的
    add  w14, w14, #1
    cmp  w14, #BW
    b.lt 2b
    add  w10, w10, #1                  // 滿了：把上面每一行往下搬一行
    mov  w12, w11
3:  cbz  w12, 4f
    mov  w14, #BW
    mul  w13, w12, w14                 // 目的行起點
    sub  w15, w13, #BW                 // 來源行起點
    mov  w14, #0
6:  add  w16, w15, w14
    ldrb w17, [x9, w16, uxtw]
    add  w16, w13, w14
    strb w17, [x9, w16, uxtw]
    add  w14, w14, #1
    cmp  w14, #BW
    b.lt 6b
    sub  w12, w12, #1
    b    3b
4:  mov  w14, #0                       // 最上面一行清空
7:  strb wzr, [x9, w14, uxtw]
    add  w14, w14, #1
    cmp  w14, #BW
    b.lt 7b
    b    1b                            // 同一行再檢查一次（上面掉下來的可能也滿）
5:  sub  w11, w11, #1
    b    1b
8:  mov  w0, w10
    ret

// 下一個方塊上場，再抽一個新的「下一個」。上場位置就被擋住時設定 game_over。
spawn:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    LA   x9, next_type
    ldr  w10, [x9]
    LA   x9, cur_type
    str  w10, [x9]
    mov  w0, #7
    bl   _arc4random_uniform
    LA   x9, next_type
    str  w0, [x9]
    LA   x9, cur_rot
    str  wzr, [x9]
    LA   x9, ai_planned                // 新方塊，電腦要重新選位置
    str  wzr, [x9]
    mov  w10, #3
    LA   x9, cur_x
    str  w10, [x9]
    LA   x9, cur_y
    str  wzr, [x9]
    LA   x9, cur_type
    ldr  w0, [x9]
    mov  w1, #0
    mov  w2, #3
    mov  w3, #0
    bl   collides
    cbz  w0, 1f
    mov  w10, #1
    LA   x9, game_over
    str  w10, [x9]
1:  ldp  x29, x30, [sp], #16
    ret

// 方塊落地：固定進場地、消行、算分、升級、換下一個方塊。
land:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    bl   lock_piece
    bl   clear_lines
    mov  w19, w0
    LA   x9, line_pts
    ldr  w10, [x9, w19, uxtw #2]
    LA   x11, level
    ldr  w12, [x11]
    mul  w10, w10, w12                 // 基本分 × 等級
    LA   x9, score
    ldr  w13, [x9]
    add  w13, w13, w10
    str  w13, [x9]
    LA   x9, lines
    ldr  w13, [x9]
    add  w13, w13, w19
    str  w13, [x9]
    mov  w14, #10
    udiv w13, w13, w14
    add  w13, w13, #1                  // 每 10 行升一級
    str  w13, [x11]
    LA   x9, drop_timer
    str  wzr, [x9]
    bl   spawn
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// 往下一格；到底了就落地。成功往下時加 1 分。
soft_drop:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    mov  w0, #0
    mov  w1, #1
    mov  w2, #0
    bl   try_move
    cbz  w0, 1f
    LA   x9, score
    ldr  w10, [x9]
    add  w10, w10, #1
    str  w10, [x9]
    LA   x9, drop_timer
    str  wzr, [x9]
    b    2f
1:  bl   land
2:  ldp  x29, x30, [sp], #16
    ret

// 直接掉到底並落地，每掉一格加 2 分。
hard_drop:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    mov  w19, #0
1:  mov  w0, #0
    mov  w1, #1
    mov  w2, #0
    bl   try_move
    cbz  w0, 2f
    add  w19, w19, #2
    b    1b
2:  LA   x9, score
    ldr  w10, [x9]
    add  w10, w10, w19
    str  w10, [x9]
    bl   land
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// 累積到該落下的輪數就往下一格；第 1 級 50 輪一格，每升一級少 5 輪，最少 5 輪。
gravity:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    LA   x9, drop_timer
    ldr  w10, [x9]
    add  w10, w10, #1
    LA   x11, level
    ldr  w12, [x11]
    mov  w13, #5
    mul  w12, w12, w13
    mov  w13, #55
    sub  w13, w13, w12                 // 55 - 等級 × 5
    mov  w14, #5
    cmp  w13, w14
    csel w13, w13, w14, ge
    cmp  w10, w13
    b.lt 1f
    str  wzr, [x9]
    mov  w10, #1
    LA   x9, dirty
    str  w10, [x9]
    mov  w0, #0
    mov  w1, #1
    mov  w2, #0
    bl   try_move
    cbnz w0, 2f
    bl   land
    b    2f
1:  str  w10, [x9]
2:  ldp  x29, x30, [sp], #16
    ret

// ───────────────────────── 自動遊玩 ─────────────────────────

// 電腦的一步。每 AI_DELAY 輪真的動一次；方塊還沒選好位置就先選。
ai_step:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    LA   x9, ai_timer
    ldr  w10, [x9]
    add  w10, w10, #1
    cmp  w10, #AI_DELAY
    b.ge 1f
    str  w10, [x9]
    b    9f
1:  str  wzr, [x9]
    mov  w10, #1
    LA   x9, dirty
    str  w10, [x9]
    LA   x9, ai_planned
    ldr  w10, [x9]
    cbnz w10, 2f
    bl   ai_plan
    mov  w10, #1
    LA   x9, ai_planned
    str  w10, [x9]
2:  LA   x9, cur_rot                   // 先轉方向
    ldr  w10, [x9]
    LA   x9, ai_rot
    ldr  w11, [x9]
    cmp  w10, w11
    b.eq 3f
    bl   rotate
    cbz  w0, 8f                        // 轉不動就直接放下，免得卡住
    b    9f
3:  LA   x9, cur_x                     // 再左右移
    ldr  w10, [x9]
    LA   x9, ai_x
    ldr  w11, [x9]
    cmp  w10, w11
    b.eq 8f
    mov  w0, #1
    mov  w1, #-1
    csel w0, w0, w1, lt                // 目前在左邊就往右，反之往左
    mov  w1, #0
    mov  w2, #0
    bl   try_move
    cbz  w0, 8f                        // 移不動也直接放下
    b    9f
8:  bl   hard_drop
9:  ldp  x29, x30, [sp], #16
    ret

// 替目前的方塊選位置：每個方向、每一欄都試著從現在的高度直直落到底，
// 在 ai_sim 上放放看、用 ai_eval 打分數，分數最高的存進 ai_rot、ai_x。
// 一個都放不下時（快輸了），就維持目前的方向和欄。
ai_plan:
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    LA   x9, cur_type
    ldr  w23, [x9]
    LA   x9, cur_y
    ldr  w26, [x9]
    LA   x9, cur_rot
    ldr  w24, [x9]                     // 預設答案 = 不動
    LA   x9, cur_x
    ldr  w25, [x9]
    mov  w22, #0x80000000              // 目前最好的分數，先設成最小的整數
    mov  w19, #0                       // 方向
1:  mov  w20, #-2                      // 欄；4x4 框可以超出左邊兩格
2:  mov  w0, w23
    mov  w1, w19
    mov  w2, w20
    mov  w3, w26
    bl   collides
    cbnz w0, 5f                        // 這個位置一開始就放不下
    mov  w21, w26
3:  mov  w0, w23                       // 往下掉到底
    mov  w1, w19
    mov  w2, w20
    add  w3, w21, #1
    bl   collides
    cbnz w0, 4f
    add  w21, w21, #1
    b    3b
4:  LA   x0, ai_sim
    LA   x1, board
    mov  x2, #(BW*BH)
    bl   _memcpy
    LA   x0, ai_sim
    mov  w1, w23
    mov  w2, w19
    mov  w3, w20
    mov  w4, w21
    bl   stamp
    LA   x0, ai_sim
    bl   ai_eval
    cmp  w0, w22
    b.le 5f
    mov  w22, w0
    mov  w24, w19
    mov  w25, w20
5:  add  w20, w20, #1
    cmp  w20, #BW
    b.lt 2b
    add  w19, w19, #1
    cmp  w19, #4
    b.lt 1b
    LA   x9, ai_rot
    str  w24, [x9]
    LA   x9, ai_x
    str  w25, [x9]
    ldp  x25, x26, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #80
    ret

// x0 = 場地 → w0 = 這個盤面的分數，越大越好。看四件事：
//   總高度（每欄最高的方塊有多高，加起來）× -51、滿的行數 × 76、
//   洞（上面有方塊、自己是空的格子）× -36、凹凸（相鄰兩欄高度差，加起來）× -18。
// 只動 x0～x4、x9～x17，不呼叫別人。
ai_eval:
    mov  x9, x0
    mov  w10, #0                       // 總高度
    mov  w11, #0                       // 洞
    mov  w12, #0                       // 凹凸
    mov  w13, #-1                      // 前一欄的高度；-1 表示還沒有前一欄
    mov  w14, #0                       // 欄
1:  mov  w15, #0                       // 列
    mov  w16, #0                       // 這一欄的高度
    mov  w17, #0                       // 這一欄是否已經碰到方塊
2:  mov  w1, #BW
    madd w1, w15, w1, w14
    ldrb w1, [x9, w1, uxtw]
    cbz  w1, 3f
    cbnz w17, 4f
    mov  w17, #1                       // 第一個方塊：高度 = 20 - 列
    mov  w2, #BH
    sub  w16, w2, w15
    b    4f
3:  add  w11, w11, w17                 // 空格，而且上面已經有方塊 → 洞
4:  add  w15, w15, #1
    cmp  w15, #BH
    b.lt 2b
    add  w10, w10, w16
    tbnz w13, #31, 5f
    subs w2, w16, w13
    cneg w2, w2, mi
    add  w12, w12, w2
5:  mov  w13, w16
    add  w14, w14, #1
    cmp  w14, #BW
    b.lt 1b
    mov  w3, #0                        // 滿的行數
    mov  w15, #0
6:  mov  w4, #0
7:  mov  w1, #BW
    madd w1, w15, w1, w4
    ldrb w1, [x9, w1, uxtw]
    cbz  w1, 8f
    add  w4, w4, #1
    cmp  w4, #BW
    b.lt 7b
    add  w3, w3, #1
8:  add  w15, w15, #1
    cmp  w15, #BH
    b.lt 6b
    mov  w1, #-51
    mul  w0, w10, w1
    mov  w1, #76
    madd w0, w3, w1, w0
    mov  w1, #-36
    madd w0, w11, w1, w0
    mov  w1, #-18
    madd w0, w12, w1, w0
    ret

// ==== AI-NOTES ====
// AI-NOTES：agent 專用備忘。當時為真、非契約、非指令；改到相關程式碼時重驗，錯了就刪。
// 2026-09-26 從 tetris.s 拆出來，讓終端機版和視窗版共用同一份規則。前端只准讀匯出的變數、
//   只准呼叫 game_ 開頭的五個常式；別讓前端直接呼叫 try_move 之類，暫停與遊戲結束的擋關都在 game_action 裡。
// 2026-09-26 測消行的方法：另外連一個 C 檔定義 arc4random_uniform 永遠回 0（全是 I），
//   十根直的 I 排滿十欄 → 行數 4、分數 1120（直接落下 10×32 + 四行 800）。同一欄疊 6 根會遊戲結束。
//   測試腳本在 /tmp/asmtest（drive.py、drive2.py、drive3.py、drive_auto.py），是暫存的，可能已被清掉。
//   a 鍵現在是自動遊玩開關，測試腳本往左移要送 ← 鍵（ESC [ D），不能再送 a。
// 2026-09-26 自動遊玩的四個權重（-51、76、-36、-18）取自 Yiyuan Lee 公開的俄羅斯方塊 AI（0.51、0.76、0.36、0.18），
//   照他的做法在「放上去、還沒消行」的盤面上打分數，沒有先消行。只看目前這個方塊，不看「下一個」。
// 2026-09-26 ai_plan 從「目前的高度」往下試，不是從最上面；所以電腦中途接手時也能用。
//   選到的位置只檢查了起點和終點放得下，沒檢查從現在位置移過去的路上會不會被擋住；被擋住時 ai_step 會直接放下。
// ==== END AI-NOTES ====
