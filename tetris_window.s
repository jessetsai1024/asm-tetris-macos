// tetris_window.s：開視窗玩的俄羅斯方塊，Apple Silicon（ARM64）macOS 版。這個檔只管視窗、畫面和按鍵，
// 遊戲規則在 tetris_core.s。
// 編譯：./build.sh（或 clang tetris_core.s tetris_window.s -framework Cocoa -o tetris_window）
// 執行：./tetris_window
// 操作：← → 移動、↑ 旋轉、↓ 加速、空白鍵直接落下、P 暫停、R 重新開始、Q 或 ⌘Q 離開、A 開關自動遊玩（也可以用 D W S）
//
// 怎麼從組合語言用蘋果的視窗系統（Cocoa）：
//   Cocoa 是用 Objective-C 寫的，所有「叫物件做事」最後都變成呼叫一個 C 函式 objc_msgSend(物件, 選擇子, 參數...)。
//   選擇子（selector）就是方法名稱，用 sel_registerName("方法名稱") 換到；類別用 objc_getClass("類別名稱") 換到。
//   我們自己的畫面類別 TetrisView 是在執行時用 objc_allocateClassPair 造出來的，再用 class_addMethod
//   把這個檔裡的組合語言常式掛上去當它的 drawRect:、keyDown: 等方法。

    .include "tetris_common.inc"

    .equ CELL, 30            // 場地一格幾點
    .equ BX, 20              // 場地左上角在視窗裡的位置
    .equ BY, 20
    .equ PX, 350             // 右邊說明欄的左邊界
    .equ PREV, 24            // 「下一個」預覽一格幾點
    .equ WIN_W, 540          // 視窗內容區大小
    .equ WIN_H, 640

// 調色盤 palette 裡的顏色編號
    .equ C_BG, 0             // 視窗背景
    .equ C_FRAME, 1          // 場地外框
    .equ C_EMPTY, 2          // 空格
    .equ C_PIECE, 3          // 3..9 = 七種方塊，順序 I J L O S T Z
    .equ C_SHADE, 10         // 暫停與遊戲結束時蓋在場地上的半透明黑
    .equ C_SHINE, 11         // 方塊上緣的亮邊

// x1 = @selector(name)。x0 會保留；x2～x7、d0～d7 會被弄亂，所以其他參數要在這之後才放。
.macro SEL name
    LA   x1, \name
    bl   sel_reg
.endm

// x0 = 名字叫 name 的類別。
.macro CLS name
    LA   x0, \name
    bl   _objc_getClass
.endm

// reg = 全域變數 sym 裡存的 8 位元組值
.macro LDQ reg, sym
    adrp \reg, \sym@PAGE
    ldr  \reg, [\reg, \sym@PAGEOFF]
.endm

// reg = 系統框架匯出的全域常數（例如 NSFontAttributeName）的值
.macro LGOT reg, sym
    adrp \reg, \sym@GOTPAGE
    ldr  \reg, [\reg, \sym@GOTPAGEOFF]
    ldr  \reg, [\reg]
.endm

// 在 x19 這個類別上掛一個方法
.macro ADDM selname, imp, types
    mov  x0, x19
    SEL  \selname
    adr  x2, \imp
    LA   x3, \types
    bl   _class_addMethod
.endm

// ───────────────────────── 資料 ─────────────────────────
    .data
    .p2align 3
g_app:      .quad 0          // NSApplication
g_ctx:      .quad 0          // 這次 drawRect: 的 CoreGraphics 畫布
g_big:      .quad 0          // 大字的文字屬性（粗體 26 點、白色）
g_small:    .quad 0          // 小字的文字屬性（15 點、淡灰）
k_tick:     .double 0.01     // 計時器間隔：10 毫秒

// 每個顏色 4 個 double：紅、綠、藍、不透明度
palette:
    .double 0.09, 0.09, 0.13, 1.0   // 背景
    .double 0.32, 0.32, 0.42, 1.0   // 外框
    .double 0.14, 0.14, 0.19, 1.0   // 空格
    .double 0.00, 0.80, 0.90, 1.0   // I 青
    .double 0.20, 0.40, 0.95, 1.0   // J 藍
    .double 1.00, 0.55, 0.10, 1.0   // L 橘
    .double 0.98, 0.82, 0.10, 1.0   // O 黃
    .double 0.25, 0.85, 0.35, 1.0   // S 綠
    .double 0.65, 0.35, 0.90, 1.0   // T 紫
    .double 0.95, 0.25, 0.30, 1.0   // Z 紅
    .double 0.00, 0.00, 0.00, 0.65  // 半透明黑
    .double 1.00, 1.00, 1.00, 0.25  // 亮邊

// 右下角的操作說明：每行兩個指標（按鍵、說明），0 結尾
    .p2align 3
help_tbl:   .quad k_h1, t_h1, k_h2, t_h2, k_h3, t_h3, k_h4, t_h4
            .quad k_h5, t_h5, k_h6, t_h6, k_h8, t_h8, k_h7, t_h7, 0

numbuf:     .space 16

// 類別名稱
n_NSApplication:    .asciz "NSApplication"
n_NSWindow:         .asciz "NSWindow"
n_NSView:           .asciz "NSView"
n_NSString:         .asciz "NSString"
n_NSTimer:          .asciz "NSTimer"
n_NSGraphicsContext: .asciz "NSGraphicsContext"
n_NSFont:           .asciz "NSFont"
n_NSColor:          .asciz "NSColor"
n_NSDictionary:     .asciz "NSDictionary"
n_NSMenu:           .asciz "NSMenu"
n_NSMenuItem:       .asciz "NSMenuItem"
n_TetrisView:       .asciz "TetrisView"

// 選擇子（方法名稱）
n_sharedApplication: .asciz "sharedApplication"
n_setActivationPolicy: .asciz "setActivationPolicy:"
n_activate:         .asciz "activateIgnoringOtherApps:"
n_alloc:            .asciz "alloc"
n_init:             .asciz "init"
n_retain:           .asciz "retain"
n_initWithFrame:    .asciz "initWithFrame:"
n_initWindow:       .asciz "initWithContentRect:styleMask:backing:defer:"
n_setTitle:         .asciz "setTitle:"
n_center:           .asciz "center"
n_setContentView:   .asciz "setContentView:"
n_makeKeyAndOrderFront: .asciz "makeKeyAndOrderFront:"
n_makeFirstResponder: .asciz "makeFirstResponder:"
n_setDelegate:      .asciz "setDelegate:"
n_run:              .asciz "run"
n_terminate:        .asciz "terminate:"
n_timer:            .asciz "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"
n_setNeedsDisplay:  .asciz "setNeedsDisplay:"
n_currentContext:   .asciz "currentContext"
n_CGContext:        .asciz "CGContext"
n_stringWithUTF8String: .asciz "stringWithUTF8String:"
n_drawAtPoint:      .asciz "drawAtPoint:withAttributes:"
n_boldSystemFontOfSize: .asciz "boldSystemFontOfSize:"
n_systemFontOfSize: .asciz "systemFontOfSize:"
n_colorWithWhite:   .asciz "colorWithCalibratedWhite:alpha:"
n_dictWithObjects:  .asciz "dictionaryWithObjects:forKeys:count:"
n_keyCode:          .asciz "keyCode"
n_addItem:          .asciz "addItem:"
n_setMainMenu:      .asciz "setMainMenu:"
n_setSubmenu:       .asciz "setSubmenu:"
n_initMenuItem:     .asciz "initWithTitle:action:keyEquivalent:"
n_drawRect:         .asciz "drawRect:"
n_keyDown:          .asciz "keyDown:"
n_acceptsFirstResponder: .asciz "acceptsFirstResponder"
n_isFlipped:        .asciz "isFlipped"
n_tick:             .asciz "tick:"
n_shouldTerminate:  .asciz "applicationShouldTerminateAfterLastWindowClosed:"

// 方法的型別字串（給執行環境做記錄用，呼叫時不會檢查）
ty_rect:    .asciz "v@:{CGRect={CGPoint=dd}{CGSize=dd}}"
ty_obj:     .asciz "v@:@"
ty_bool:    .asciz "B@:"
ty_bool_obj: .asciz "B@:@"

// 畫面上的文字
t_title:    .asciz "俄羅斯方塊（組合語言版）"
t_quit:     .asciz "結束俄羅斯方塊"
t_q:        .asciz "q"
t_score:    .asciz "分數"
t_lines:    .asciz "行數"
t_level:    .asciz "等級"
t_next:     .asciz "下一個"
t_over:     .asciz "遊戲結束"
t_over2:    .asciz "按 R 重新開始"
t_paused:   .asciz "暫停中"
t_paused2:  .asciz "按 P 繼續"
k_h1:       .asciz "← →"
t_h1:       .asciz "移動"
k_h2:       .asciz "↑"
t_h2:       .asciz "旋轉"
k_h3:       .asciz "↓"
t_h3:       .asciz "加速"
k_h4:       .asciz "空白鍵"
t_h4:       .asciz "直接落下"
k_h5:       .asciz "P"
t_h5:       .asciz "暫停"
k_h6:       .asciz "R"
t_h6:       .asciz "重新開始"
k_h7:       .asciz "Q"
t_h7:       .asciz "離開"
k_h8:       .asciz "A"
t_h8:       .asciz "自動遊玩"
t_auto:     .asciz "自動遊玩中"

// ───────────────────────── 程式 ─────────────────────────
    .text
    .p2align 2
    .global _main

// 【行為】開一個 540×640 的視窗玩俄羅斯方塊：建立選單（⌘Q 可離開）、畫面類別、視窗與每 10 毫秒一次的計時器，
//   然後把控制權交給 Cocoa 的事件迴圈。玩家按 Q、⌘Q 或關掉視窗時整個程式結束，不會回到這裡。
// 【何時能呼叫】要在有登入畫面的 Mac 上執行；透過 SSH 等沒有畫面的連線跑，視窗開不起來。
// 【設計備註】不是 .app 包裝，所以一開始要 setActivationPolicy: 0，否則不會出現在 Dock、也拿不到鍵盤。
_main:
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    bl   _objc_autoreleasePoolPush     // 啟動期間產生的暫時物件放這裡；run 不會回來，所以不 pop

    CLS  n_NSApplication               // app = [NSApplication sharedApplication]
    SEL  n_sharedApplication
    bl   _objc_msgSend
    mov  x19, x0
    LA   x9, g_app
    str  x0, [x9]
    mov  x0, x19                       // 當一般 App：有 Dock 圖示、有選單列
    SEL  n_setActivationPolicy
    mov  x2, #0
    bl   _objc_msgSend

    bl   build_menu
    bl   build_attrs
    bl   make_view_class
    mov  x20, x0

    mov  x0, x20                       // view = [[TetrisView alloc] initWithFrame:{0,0,540,640}]
    SEL  n_alloc
    bl   _objc_msgSend
    SEL  n_initWithFrame
    fmov d0, xzr
    fmov d1, xzr
    mov  w9, #WIN_W
    scvtf d2, w9
    mov  w9, #WIN_H
    scvtf d3, w9
    bl   _objc_msgSend
    mov  x21, x0

    CLS  n_NSWindow                    // win = [[NSWindow alloc] initWithContentRect:... styleMask:7 backing:2 defer:NO]
    SEL  n_alloc
    bl   _objc_msgSend
    SEL  n_initWindow
    fmov d0, xzr
    fmov d1, xzr
    mov  w9, #WIN_W
    scvtf d2, w9
    mov  w9, #WIN_H
    scvtf d3, w9
    mov  x2, #7                        // 有標題列、可關閉、可縮小
    mov  x3, #2                        // NSBackingStoreBuffered
    mov  w4, #0
    bl   _objc_msgSend
    mov  x22, x0

    LA   x0, t_title
    bl   make_nsstring
    mov  x20, x0                       // 類別已經用完，x20 借來放標題
    mov  x0, x22
    SEL  n_setTitle
    mov  x2, x20
    bl   _objc_msgSend
    mov  x0, x22
    SEL  n_setContentView
    mov  x2, x21
    bl   _objc_msgSend
    mov  x0, x22
    SEL  n_center
    bl   _objc_msgSend
    mov  x0, x22
    SEL  n_makeKeyAndOrderFront
    mov  x2, #0
    bl   _objc_msgSend
    mov  x0, x22                       // 讓按鍵送到我們的畫面
    SEL  n_makeFirstResponder
    mov  x2, x21
    bl   _objc_msgSend
    mov  x0, x19                       // 畫面兼任 App 的代理人：關掉最後一個視窗就結束
    SEL  n_setDelegate
    mov  x2, x21
    bl   _objc_msgSend

    bl   game_restart

    CLS  n_NSTimer                     // [NSTimer scheduledTimerWithTimeInterval:0.01 target:view selector:tick: userInfo:nil repeats:YES]
    SEL  n_timer
    mov  x20, x1
    LA   x1, n_tick
    bl   sel_reg                       // x1 = @selector(tick:)，x0 還是 NSTimer
    mov  x3, x1
    mov  x1, x20
    LA   x9, k_tick
    ldr  d0, [x9]
    mov  x2, x21
    mov  x4, #0
    mov  w5, #1
    bl   _objc_msgSend

    mov  x0, x19
    SEL  n_activate
    mov  w2, #1
    bl   _objc_msgSend
    mov  x0, x19
    SEL  n_run
    bl   _objc_msgSend

    mov  w0, #0
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #64
    ret

// x1 = 選擇子名稱字串 → 換成選擇子放回 x1。x0 原樣保留。
sel_reg:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x0, [sp, #16]
    mov  x0, x1
    bl   _sel_registerName
    mov  x1, x0
    ldr  x0, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// x0 = UTF-8 字串 → x0 = NSString（暫時物件）
make_nsstring:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    mov  x19, x0
    CLS  n_NSString
    SEL  n_stringWithUTF8String
    mov  x2, x19
    bl   _objc_msgSend
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// 選單列：只有一個 App 選單，裡面一項「結束俄羅斯方塊 ⌘Q」。
build_menu:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    CLS  n_NSMenu                      // menubar
    SEL  n_alloc
    bl   _objc_msgSend
    SEL  n_init
    bl   _objc_msgSend
    mov  x19, x0
    CLS  n_NSMenuItem                  // appItem
    SEL  n_alloc
    bl   _objc_msgSend
    SEL  n_init
    bl   _objc_msgSend
    mov  x20, x0
    mov  x0, x19
    SEL  n_addItem
    mov  x2, x20
    bl   _objc_msgSend
    LDQ  x0, g_app
    SEL  n_setMainMenu
    mov  x2, x19
    bl   _objc_msgSend
    CLS  n_NSMenu                      // appMenu
    SEL  n_alloc
    bl   _objc_msgSend
    SEL  n_init
    bl   _objc_msgSend
    mov  x19, x0
    LA   x0, t_quit
    bl   make_nsstring
    mov  x21, x0
    LA   x0, t_q
    bl   make_nsstring
    mov  x22, x0
    CLS  n_NSMenuItem                  // [[NSMenuItem alloc] initWithTitle:… action:terminate: keyEquivalent:@"q"]
    SEL  n_alloc
    bl   _objc_msgSend
    LA   x1, n_terminate
    bl   sel_reg
    mov  x3, x1
    str  x3, [sp, #-16]!
    SEL  n_initMenuItem
    ldr  x3, [sp], #16
    mov  x2, x21
    mov  x4, x22
    bl   _objc_msgSend
    mov  x21, x0                       // 標題字串已經用完，x21 改放這個選單項目
    mov  x0, x19
    SEL  n_addItem
    mov  x2, x21
    bl   _objc_msgSend
    mov  x0, x20
    SEL  n_setSubmenu
    mov  x2, x19
    bl   _objc_msgSend
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// 準備兩種文字樣式，存進 g_big、g_small。
build_attrs:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    CLS  n_NSFont
    SEL  n_boldSystemFontOfSize
    mov  w9, #26
    scvtf d0, w9
    bl   _objc_msgSend
    fmov d0, #1.0
    bl   make_attrs
    LA   x9, g_big
    str  x0, [x9]
    CLS  n_NSFont
    SEL  n_systemFontOfSize
    mov  w9, #15
    scvtf d0, w9
    bl   _objc_msgSend
    fmov d0, #0.75
    bl   make_attrs
    LA   x9, g_small
    str  x0, [x9]
    ldp  x29, x30, [sp], #16
    ret

// x0 = 字型、d0 = 灰階亮度（1 是白）→ x0 = 文字屬性字典，已 retain，不會被自動釋放。
make_attrs:
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    str  d0, [sp, #32]
    CLS  n_NSColor
    SEL  n_colorWithWhite
    ldr  d0, [sp, #32]
    fmov d1, #1.0
    bl   _objc_msgSend
    mov  x20, x0
    stp  x19, x20, [sp, #48]           // 值：字型、顏色
    LGOT x9, _NSFontAttributeName
    LGOT x10, _NSForegroundColorAttributeName
    stp  x9, x10, [sp, #64]            // 鍵
    CLS  n_NSDictionary
    SEL  n_dictWithObjects
    add  x2, sp, #48
    add  x3, sp, #64
    mov  x4, #2
    bl   _objc_msgSend
    SEL  n_retain
    bl   _objc_msgSend
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #80
    ret

// 造出 NSView 的子類別 TetrisView，掛上這個檔裡的方法。回傳 x0 = 類別。
make_view_class:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    CLS  n_NSView
    LA   x1, n_TetrisView
    mov  x2, #0
    bl   _objc_allocateClassPair
    mov  x19, x0
    ADDM n_drawRect, view_drawRect, ty_rect
    ADDM n_keyDown, view_keyDown, ty_obj
    ADDM n_acceptsFirstResponder, view_yes, ty_bool     // 沒有這個，按鍵不會送進來
    ADDM n_isFlipped, view_yes, ty_bool                 // 讓 y 往下增加，列 0 在最上面
    ADDM n_tick, view_tick, ty_obj
    ADDM n_shouldTerminate, view_yes, ty_bool_obj
    mov  x0, x19
    bl   _objc_registerClassPair
    mov  x0, x19
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// ───────────────────────── TetrisView 的方法 ─────────────────────────
// 這幾個常式由 Cocoa 呼叫：x0 = 畫面物件自己，x1 = 選擇子，之後才是方法參數。

// 回傳 YES。拿來當 acceptsFirstResponder、isFlipped、applicationShouldTerminateAfterLastWindowClosed:。
view_yes:
    mov  w0, #1
    ret

// tick:，計時器每 10 毫秒叫一次：遊戲往前走一輪，有變化就要求重畫。
view_tick:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    str  x19, [sp, #16]
    mov  x19, x0
    bl   game_tick
    mov  x0, x19
    bl   request_redraw
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// keyDown:，x2 = 按鍵事件。用按鍵的實體位置代碼（keyCode）判斷，跟輸入法無關。
view_keyDown:
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    mov  x19, x0
    mov  x0, x2
    SEL  n_keyCode
    bl   _objc_msgSend
    and  w20, w0, #0xffff
    cmp  w20, #12                      // Q
    b.eq 8f
    cmp  w20, #15                      // R
    b.ne 1f
    bl   game_restart
    b    7f
1:  cmp  w20, #35                      // P
    b.ne 2f
    bl   game_toggle_pause
    b    7f
2:  cmp  w20, #0                       // A
    b.ne 3f
    bl   game_toggle_autoplay
    b    7f
3:  mov  w0, #ACT_LEFT
    cmp  w20, #123                     // ←
    b.eq 6f
    mov  w0, #ACT_RIGHT
    cmp  w20, #124                     // →
    b.eq 6f
    cmp  w20, #2                       // D
    b.eq 6f
    mov  w0, #ACT_DOWN
    cmp  w20, #125                     // ↓
    b.eq 6f
    cmp  w20, #1                       // S
    b.eq 6f
    mov  w0, #ACT_ROTATE
    cmp  w20, #126                     // ↑
    b.eq 6f
    cmp  w20, #13                      // W
    b.eq 6f
    mov  w0, #ACT_DROP
    cmp  w20, #49                      // 空白鍵
    b.eq 6f
    b    9f                            // 其他鍵不理
6:  bl   game_action
7:  mov  x0, x19
    bl   request_redraw
    b    9f
8:  LDQ  x0, g_app
    SEL  n_terminate
    mov  x2, #0
    bl   _objc_msgSend
9:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// x0 = 畫面。遊戲狀態有變（dirty）就清掉記號並要求 Cocoa 重畫。
request_redraw:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    LA   x9, dirty
    ldr  w10, [x9]
    cbz  w10, 1f
    str  wzr, [x9]
    SEL  n_setNeedsDisplay
    mov  w2, #1
    bl   _objc_msgSend
1:  ldp  x29, x30, [sp], #16
    ret

// drawRect:，把整個畫面畫一遍：背景、場地、正在掉的方塊、右邊說明欄、暫停或結束的遮罩。
view_drawRect:
    stp  x29, x30, [sp, #-80]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    CLS  n_NSGraphicsContext           // g_ctx = [[NSGraphicsContext currentContext] CGContext]
    SEL  n_currentContext
    bl   _objc_msgSend
    SEL  n_CGContext
    bl   _objc_msgSend
    LA   x9, g_ctx
    str  x0, [x9]

    mov  w0, #C_BG
    bl   set_color
    mov  w0, #0
    mov  w1, #0
    mov  w2, #WIN_W
    mov  w3, #WIN_H
    bl   fill_i
    mov  w0, #C_FRAME
    bl   set_color
    mov  w0, #(BX - 4)
    mov  w1, #(BY - 4)
    mov  w2, #(BW*CELL + 8)
    mov  w3, #(BH*CELL + 8)
    bl   fill_i

    LA   x9, cur_type                  // 正在掉的方塊
    ldr  w25, [x9]
    LA   x9, cur_rot
    ldr  w10, [x9]
    LA   x9, pieces
    add  w11, w10, w25, lsl #2
    ldrh w22, [x9, w11, uxtw #1]
    LA   x9, cur_x
    ldr  w23, [x9]
    LA   x9, cur_y
    ldr  w24, [x9]
    LA   x26, board
    mov  w20, #0                       // 列
d_row:
    mov  w21, #0                       // 欄
d_col:
    mov  w9, #BW
    madd w9, w20, w9, w21
    ldrb w0, [x26, w9, uxtw]
    cbz  w0, 1f
    add  w0, w0, #(C_PIECE - 1)        // 場地裡存的是種類 + 1
    b    3f
1:  sub  w9, w21, w23                  // 這格在不在正在掉的方塊的 4x4 框裡？
    sub  w10, w20, w24
    mov  w0, #C_EMPTY
    cmp  w9, #0
    b.lt 3f
    cmp  w9, #3
    b.gt 3f
    cmp  w10, #0
    b.lt 3f
    cmp  w10, #3
    b.gt 3f
    add  w11, w9, w10, lsl #2
    mov  w12, #0x8000
    lsr  w12, w12, w11
    tst  w22, w12
    b.eq 3f
    add  w0, w25, #C_PIECE
3:  mov  w9, #CELL
    mov  w10, #BX
    madd w1, w21, w9, w10
    mov  w10, #BY
    madd w2, w20, w9, w10
    mov  w3, #CELL
    bl   draw_cell
    add  w21, w21, #1
    cmp  w21, #BW
    b.lt d_col
    add  w20, w20, #1
    cmp  w20, #BH
    b.lt d_row

    LA   x0, t_score                   // 右邊說明欄
    mov  w1, #PX
    mov  w2, #20
    LDQ  x3, g_small
    bl   draw_text
    LA   x9, score
    ldr  w0, [x9]
    mov  w1, #PX
    mov  w2, #40
    LDQ  x3, g_big
    bl   draw_num
    LA   x0, t_lines
    mov  w1, #PX
    mov  w2, #92
    LDQ  x3, g_small
    bl   draw_text
    LA   x9, lines
    ldr  w0, [x9]
    mov  w1, #PX
    mov  w2, #112
    LDQ  x3, g_big
    bl   draw_num
    LA   x0, t_level
    mov  w1, #PX
    mov  w2, #164
    LDQ  x3, g_small
    bl   draw_text
    LA   x9, level
    ldr  w0, [x9]
    mov  w1, #PX
    mov  w2, #184
    LDQ  x3, g_big
    bl   draw_num
    LA   x0, t_next
    mov  w1, #PX
    mov  w2, #240
    LDQ  x3, g_small
    bl   draw_text

    LA   x9, next_type                 // 「下一個」預覽，4x4
    ldr  w23, [x9]
    LA   x9, pieces
    lsl  w10, w23, #3                  // 每種方塊 4 個 hword = 8 位元組，取方向 0
    ldrh w22, [x9, w10, uxtw]
    mov  w20, #0
4:  mov  w21, #0
5:  add  w11, w21, w20, lsl #2
    mov  w12, #0x8000
    lsr  w12, w12, w11
    tst  w22, w12
    b.eq 6f
    add  w0, w23, #C_PIECE
    mov  w9, #PREV
    mov  w10, #PX
    madd w1, w21, w9, w10
    mov  w10, #268
    madd w2, w20, w9, w10
    mov  w3, #PREV
    bl   draw_cell
6:  add  w21, w21, #1
    cmp  w21, #4
    b.lt 5b
    add  w20, w20, #1
    cmp  w20, #4
    b.lt 4b

    LA   x9, autoplay                  // 自動遊玩開著就在預覽下面標出來
    ldr  w10, [x9]
    cbz  w10, 12f
    LA   x0, t_auto
    mov  w1, #PX
    mov  w2, #366
    LDQ  x3, g_big
    bl   draw_text
12: LA   x20, help_tbl                 // 操作說明，每行 26 點
    mov  w21, #400
7:  ldr  x0, [x20], #8               // 按鍵
    cbz  x0, 8f
    mov  w1, #PX
    mov  w2, w21
    LDQ  x3, g_small
    bl   draw_text
    ldr  x0, [x20], #8               // 說明
    mov  w1, #(PX + 64)
    mov  w2, w21
    LDQ  x3, g_small
    bl   draw_text
    add  w21, w21, #26
    b    7b

8:  LA   x9, game_over                 // 遊戲結束或暫停時蓋一層半透明黑
    ldr  w10, [x9]
    cbz  w10, 9f
    LA   x19, t_over
    LA   x20, t_over2
    mov  w21, #114
    mov  w22, #124
    b    10f
9:  LA   x9, paused
    ldr  w10, [x9]
    cbz  w10, 11f
    LA   x19, t_paused
    LA   x20, t_paused2
    mov  w21, #131
    mov  w22, #139
10: mov  w0, #C_SHADE
    bl   set_color
    mov  w0, #BX
    mov  w1, #BY
    mov  w2, #(BW*CELL)
    mov  w3, #(BH*CELL)
    bl   fill_i
    mov  x0, x19
    mov  w1, w21
    mov  w2, #270
    LDQ  x3, g_big
    bl   draw_text
    mov  x0, x20
    mov  w1, w22
    mov  w2, #316
    LDQ  x3, g_small
    bl   draw_text

11: ldp  x25, x26, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #80
    ret

// ───────────────────────── 畫圖小工具 ─────────────────────────
// 都畫在 g_ctx 上，只能在 drawRect: 裡面用。

// w0 = 調色盤編號，設成接下來填色用的顏色。
set_color:
    LA   x9, palette
    mov  w10, w0
    add  x9, x9, x10, lsl #5           // 每個顏色 32 位元組
    ldp  d0, d1, [x9]
    ldp  d2, d3, [x9, #16]
    LDQ  x0, g_ctx
    b    _CGContextSetRGBFillColor     // 直接跳過去，它會自己 ret 回呼叫者

// w0 = x、w1 = y、w2 = 寬、w3 = 高（整數點），用目前顏色填滿這個矩形。
fill_i:
    scvtf d0, w0
    scvtf d1, w1
    scvtf d2, w2
    scvtf d3, w3
    LDQ  x0, g_ctx
    b    _CGContextFillRect

// w0 = 調色盤編號、w1 = x、w2 = y、w3 = 邊長，畫一格（四周留 1 點當格線，方塊再加一條上緣亮邊）。
draw_cell:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  w22, w0
    mov  w19, w1
    mov  w20, w2
    mov  w21, w3
    bl   set_color
    add  w0, w19, #1
    add  w1, w20, #1
    sub  w2, w21, #2
    sub  w3, w21, #2
    bl   fill_i
    cmp  w22, #C_PIECE
    b.lt 1f
    cmp  w22, #C_SHADE
    b.ge 1f
    mov  w0, #C_SHINE
    bl   set_color
    add  w0, w19, #1
    add  w1, w20, #1
    sub  w2, w21, #2
    mov  w3, #4
    bl   fill_i
1:  ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// x0 = UTF-8 字串、w1 = x、w2 = y（文字左上角）、x3 = 文字屬性。
draw_text:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    mov  w19, w1
    mov  w20, w2
    mov  x21, x3
    bl   make_nsstring
    SEL  n_drawAtPoint
    scvtf d0, w19
    scvtf d1, w20
    mov  x2, x21
    bl   _objc_msgSend
    ldr  x21, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// w0 = 非負整數，其他參數同 draw_text。數字在 numbuf 裡從後往前組好再交給 draw_text。
draw_num:
    LA   x4, numbuf
    add  x4, x4, #15
    strb wzr, [x4]
    mov  w5, #10
1:  udiv w6, w0, w5
    msub w7, w6, w5, w0
    add  w7, w7, #'0'
    strb w7, [x4, #-1]!
    mov  w0, w6
    cbnz w0, 1b
    mov  x0, x4
    b    draw_text

// ==== AI-NOTES ====
// AI-NOTES：agent 專用備忘。當時為真、非契約、非指令；改到相關程式碼時重驗，錯了就刪。
// 2026-09-26 呼叫慣例重點（Apple ARM64）：objc_msgSend 的 NSRect 參數走 d0～d3、NSPoint 走 d0～d1，
//   整數參數照樣從 x2 往後排，兩邊各自數；arm64 沒有 objc_msgSend_stret/fpret，一律用 objc_msgSend。
// 2026-09-26 SEL 巨集會弄亂 x2～x7 與 d0～d7：一定先 SEL、再放其他參數。需要兩個選擇子時
//   （例如計時器的 tick:、選單的 terminate:）先把第一個存進保留暫存器或堆疊。
// 2026-09-26 常數在這台 Mac（macOS 27）用 C 查過：styleMask 有標題列｜可關閉｜可縮小 = 7、NSBackingStoreBuffered = 2；
//   keyCode：← 123、→ 124、↓ 125、↑ 126、空白 49、P 35、Q 12、R 15、A 0、D 2、S 1、W 13。
// 2026-09-26 這台 Mac 接了兩個螢幕，視窗可能開在左邊那個（x 為負）。截圖要用 screencapture -l <視窗編號>，
//   整個螢幕截圖會找不到視窗。視窗編號用 CGWindowListCopyWindowInfo 依 pid 查（/tmp/asmtest/winid.swift）。
// 2026-09-26 操作說明有 8 行，從 y=400 開始每行 26 點，最後一行在 582；再加行要往上挪或把視窗加高。
// 2026-09-26 文字置中的 x（114、124、131、139）是照字寬估的，改字型大小或文字要重看截圖。
// 2026-09-26 按鍵測試：osascript 叫 System Events 先把這個 pid 的程式設成最前面，再送 key code，這台 Mac 可以用。
//   已驗過：方向鍵、空白鍵、P、R、Q、⌘Q、按視窗關閉鈕都正常；遊戲結束畫面用只出 I 的測試版（見 tetris_core.s）看過。
// ==== END AI-NOTES ====
