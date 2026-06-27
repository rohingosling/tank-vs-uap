//*******************************************************************************
//
// Project:      Tank vs UAP (Commodore VIC-20)
// Version:      1.0
// Release Date: 2021
// Last Updated: 2021-07-01
// Author:       Rohin Gosling
//
// DESCRIPTION:
//
//   charset.asm. the custom character set: static glyphs ($00-$14) plus the
//   dynamic tile pool ($15-$xx).
//
//   Each glyph is 8 bytes, one per row, bit 7 = leftmost pixel.
//   Placement-agnostic:
//   the includer sets `.pc = $1400` before `#import`-ing this file so the
//   bytes land in the charset region. The pool slots ($15-$7F max) are
//   zero-filled here and re-zeroed at boot by canvas_init.
//
//*******************************************************************************

#importonce

#import "constants.asm"

//==============================================================================
// Data — Character Set
//==============================================================================

charset_data:

    // $00: canvas blank cell marker.

    .byte $00, $00, $00, $00, $00, $00, $00, $00

    // $01-$0A: digits 0-9 (OCR-style; score / high).

    .byte $7E, $42, $42, $46, $46, $46, $7E, $00  // $01: "0"
    .byte $08, $08, $08, $18, $18, $18, $18, $00  // $02: "1"
    .byte $7E, $42, $02, $7E, $60, $60, $7E, $00  // $03: "2"
    .byte $7C, $44, $04, $7E, $06, $46, $7E, $00  // $04: "3"
    .byte $7E, $42, $42, $7F, $06, $06, $06, $00  // $05: "4"
    .byte $7E, $40, $40, $7E, $06, $46, $7E, $00  // $06: "5"
    .byte $7E, $42, $40, $7E, $46, $46, $7E, $00  // $07: "6"
    .byte $7E, $42, $02, $06, $06, $06, $06, $00  // $08: "7"
    .byte $3C, $24, $24, $7E, $46, $46, $7E, $00  // $09: "8"
    .byte $7E, $42, $42, $7E, $06, $06, $06, $00  // $0A: "9"

    // $0B: static ground tile.

    .byte $FF, $FF, $AA, $55, $88, $22, $00, $00

    // $0C: player-lives icon (small tank).

    .byte $00, $40, $40, $F8, $FC, $00, $7C, $00

    // $0D: colon (HUD punctuation).

    .byte $00, $C0, $C0, $00, $C0, $C0, $00, $00

    // $0E-$11: "SCORE" label (4 cells).

    .byte $FB, $8A, $82, $FB, $1B, $9B, $FB, $00  // $0E
    .byte $EF, $28, $08, $0C, $0C, $2C, $EF, $00  // $0F
    .byte $BC, $A4, $A4, $BE, $B2, $B2, $B2, $00  // $10
    .byte $F8, $80, $80, $F8, $C0, $C0, $F8, $00  // $11

    // $12-$14: "HIGH" label (3 cells).

    .byte $45, $45, $45, $7D, $65, $65, $65, $00  // $12
    .byte $3E, $22, $20, $B6, $B2, $B2, $BE, $00  // $13
    .byte $88, $88, $88, $F8, $C8, $C8, $C8, $00  // $14

charset_static_end:

    // $15-$xx: Dynamic Tile Canvas pool. zero-filled (re-zeroed by
    // canvas_init). ($15 was the pool-exhaustion sentinel saltire, deleted
    // once exhaustion became skip-and-self-heal. nothing ever drew it.)

    .fill POOL_SLOTS * 8, $00

charset_end:

.assert "static glyphs occupy $00-$14 (168 bytes)", charset_static_end - charset_data, 21 * 8
.assert "charset (static + pool) ends at the tail gap", charset_end, CHARSET_TAIL_BASE
