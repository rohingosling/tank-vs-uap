//============================================================================================
//  banner-resident.asm  --  pre-generated RAM-resident banner data. DO NOT HAND-EDIT.
//  RAM-resident banner data (press-any-key + game-over) + the layout constants the page-1
//  "R" overlay's copy loops need (src/resident.asm). These banners have NO .prg / disk
//  file; their pool slots still come from the shared slot allocator, so the screen cell
//  codes stay in lock-step with the disk banners in banner-layout.asm.
//============================================================================================

#import "constants.asm"

// PRESS: px (51,120), 10x1 cells, slots $32-$3B, charset $1590.

.const PRESS_BANNER_CODE    = $32   // First pool cell code (= charset slot).
.const PRESS_BANNER_CELLS   = 10    // Single-row rectangle width in cells.
.const PRESS_BANNER_BYTES   = 80    // Packed charset bytes (cells x 8).
.const PRESS_BANNER_CHARSET = CHARSET_BASE + PRESS_BANNER_CODE * 8
.const PRESS_BANNER_SCREEN  = SCREEN_RAM + 15 * SCREEN_COLUMNS + 6

press_banner_data:
    .byte $1f, $11, $11, $1f, $18, $18, $18, $00
    .byte $7c, $44, $44, $7e, $62, $62, $62, $00
    .byte $fb, $82, $82, $fb, $c0, $c2, $fb, $00
    .byte $ef, $28, $08, $ef, $61, $69, $ef, $00
    .byte $83, $82, $02, $87, $86, $86, $86, $00
    .byte $df, $51, $51, $d9, $59, $59, $59, $00
    .byte $42, $42, $42, $7e, $18, $18, $18, $00
    .byte $12, $12, $12, $1f, $19, $19, $19, $00
    .byte $7d, $41, $41, $7d, $60, $60, $7c, $00
    .byte $08, $08, $08, $f8, $60, $60, $60, $00

// GAMEOVER: px (62,80), 8x1 cells, slots $15-$1C, charset $14A8.

.const GAMEOVER_BANNER_CODE    = $15   // First pool cell code (= charset slot).
.const GAMEOVER_BANNER_CELLS   = 8     // Single-row rectangle width in cells.
.const GAMEOVER_BANNER_BYTES   = 64    // Packed charset bytes (cells x 8).
.const GAMEOVER_BANNER_CHARSET = CHARSET_BASE + GAMEOVER_BANNER_CODE * 8
.const GAMEOVER_BANNER_SCREEN  = SCREEN_RAM + 10 * SCREEN_COLUMNS + 7

gameover_banner_data:
    .byte $03, $02, $02, $03, $03, $03, $03, $00
    .byte $e7, $24, $04, $6f, $2c, $2c, $ec, $00
    .byte $bf, $a5, $a5, $b5, $b5, $b5, $b5, $00
    .byte $7c, $40, $40, $7c, $60, $60, $7c, $00
    .byte $3e, $26, $22, $22, $22, $22, $3e, $00
    .byte $cb, $ca, $ca, $db, $52, $52, $73, $00
    .byte $ef, $09, $09, $ef, $0c, $0c, $ec, $00
    .byte $00, $00, $00, $80, $80, $80, $80, $00
