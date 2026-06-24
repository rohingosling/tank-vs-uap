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
//   score.asm. scoring. Resident in the second disk overlay at
//   $0200 (the BASIC input buffer; free after SYS, never touched again since
//   the game never returns to BASIC). Loaded from the .d64 by load_overlay
//   alongside the $033C overlay.
//
//   The 6-digit decimal score lives in SCORE_DIG (zero page,
//   [0] = MSB .. [5] = units) and is mirrored to the row-0 score field
//   (digit + 1 = screen code). Called from the collision handlers
//   (collide.asm, $1xxx). a cross-region jsr. After each change it calls
//   update_high (tank-vs-uap.asm) so the high score (HIGH_DIG) tracks the
//   current score once it is overtaken, and that high score persists across
//   games within a session.
//
//   Bands: rows 1-16 (y 8-128) split into high / medium / low; higher
//   altitude (lower y) scores most. UAP kill = 100/50/25; bullet intercepts
//   a bomb = 200/100/50. (Every award is a multiple of 25; the old +1 for a
//   bomb reaching the ground was removed to keep scores on multiples of 5.)
//
//*******************************************************************************

#importonce

#import "constants.asm"

//==============================================================================
// Data
//==============================================================================

//------------------------------------------------------------------------------
// Per-band point tables.
//
// band_index (the y → band classifier) lives in the charset tail
// (proj-lower.asm). The per-band point tables live HERE, indexed by collide's
// hit handlers with the band returned by band_index: higher altitude
// (lower y / lower index) scores most.
//------------------------------------------------------------------------------

uap_band_points:

    .byte 100,  50, 25                          // UAP kill:        high / med / low.

bomb_band_points:

    .byte 200, 100, 50                          // Bomb intercept:  high / med / low.

//==============================================================================
// Subroutines — Scoring
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: add_score
//
// Description:
//
//   Adds A points to the 6-digit decimal score with carry, freezes the score
//   at 999999, and refreshes the row-0 display.
//
//   The units add cannot overflow a byte: SCORE_DIG + 5 [0-9] + points
//   [≤ 200] = ≤ 209 < 256; the tens-carry normalization loop folds the rest.
//
// Parameters:
//
//   A - Points to add (25..200).
//
// Clobbers: A, Y. X is preserved (saved/restored).
//
//------------------------------------------------------------------------------

add_score:

    sta score_pts
    txa
    pha                                         // Save caller's X.

    lda SCORE_DIG + 5                           // Units += points (points small, no byte overflow).
    clc
    adc score_pts
    sta SCORE_DIG + 5

    ldx #5

!digit:

    ldy #$00                                    // Carry (count of 10s) into the next-higher digit.

!norm:

    lda SCORE_DIG, x
    cmp #10
    bcc !donedigit+
    sec
    sbc #10
    sta SCORE_DIG, x
    iny
    bne !norm-                                  // (Always; INY effectively never wraps here.)

!donedigit:

    cpx #$00
    beq !msb+                                   // X = 0: no higher digit. check overflow.
    tya
    beq !nextdigit+                             // No carry.
    clc
    adc SCORE_DIG - 1, x
    sta SCORE_DIG - 1, x

!nextdigit:

    dex
    jmp !digit-

!msb:

    cpy #$00
    beq !refresh+                               // No carry out of the MSB.
    ldx #5                                      // Overflow → freeze at 999999.

!freeze:

    lda #9
    sta SCORE_DIG, x
    dex
    bpl !freeze-

!refresh:

    ldx #5                                      // Mirror digits to the row-0 score field
                                                //   (digit + 1 = screen code).

!disp:

    lda SCORE_DIG, x
    clc
    adc #1
    sta SCORE_DISP, x
    dex
    bpl !disp-

    jsr update_high                             // High score tracks current once current overtakes it.
    jsr update_difficulty                       // F6: scale the active UAP count to the new score.

    pla
    tax                                         // Restore caller's X.
    rts
