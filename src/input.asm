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
//   input.asm. direct VIA2 keyboard matrix scan (no KERNAL keyboard
//   handler).
//
//   The sound IRQ replaced the KERNAL IRQ, so the KERNAL keyboard scanner no
//   longer runs and $F5/$F6 are never clobbered. We
//   scan the matrix ourselves: drive a keyboard column low on Port B, read
//   the rows on Port A (0 = pressed). The game keys are all in column 4:
//   Z (row 1) = left, C (row 2) = right, B (row 3) = fire.
//
//   Placement-agnostic CODE; input_flags is a zero-page byte owned here.
//
//*******************************************************************************

#importonce

#import "constants.asm"

//==============================================================================
// Constants
//==============================================================================

//------------------------------------------------------------------------------
// Input flag bits and the zero-page state byte.
//------------------------------------------------------------------------------

.const INPUT_LEFT               = %00000001
.const INPUT_RIGHT              = %00000010
.const INPUT_FIRE               = %00000100

.const input_flags              = $08           // ZP: current frame's key state.

//------------------------------------------------------------------------------
// Keyboard matrix positions (column driven low on Port B, rows on Port A).
//------------------------------------------------------------------------------

.const KEYBOARD_COLUMN_4        = %11101111     // Drive column 4 low ($EF).
.const KEY_Z_BIT                = %00000010     // Column 4, row 1.
.const KEY_C_BIT                = %00000100     // Column 4, row 2.
.const KEY_B_BIT                = %00001000     // Column 4, row 3.

//==============================================================================
// Subroutines — Keyboard Input
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: input_init
//
// Description:
//
//   Sets the keyboard port directions — Port B all output (columns), Port A
//   all input (rows) — and clears input_flags.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

input_init:

    lda #$ff
    sta VIA2_DDRB                               // Port B all output (columns).
    lda #$00
    sta VIA2_DDRA                               // Port A all input (rows).
    sta input_flags
    rts

//------------------------------------------------------------------------------
//
// Subroutine: scan_keys
//
// Description:
//
//   Reads keyboard column 4 and builds input_flags (LEFT / RIGHT / FIRE).
//   Also ticks the tank-destruction dwell timer (F2), which suppresses
//   player control while the tank is destroyed.
//
// Outputs:
//
//   A           - input_flags (the flags are returned in A).
//   input_flags - Current frame's key state.
//
// Clobbers: A, X (plus anything clobbered by tank_fire_step /
//           tank_exit_dwell during the destruction dwell).
//
//------------------------------------------------------------------------------

scan_keys:

    lda #KEYBOARD_COLUMN_4
    sta VIA2_PORTB
    lda VIA2_PORTA                              // Rows: 0 = pressed.
    eor #$ff                                    // Invert so 1 = pressed.
    tax                                         // X = pressed-row mask for column 4.

    // Z → LEFT (the first key writes input_flags fresh; later keys OR onto
    // it). A already holds the pressed-row mask (the tax above left A
    // unchanged), so the first txa is omitted; the LATER txa's are needed
    // (the lda/ora/sta between them clobber A).

    and #KEY_Z_BIT
    beq !no_left+
    lda #INPUT_LEFT

!no_left:

    sta input_flags

    // C → RIGHT.

    txa
    and #KEY_C_BIT
    beq !no_right+
    lda input_flags
    ora #INPUT_RIGHT
    sta input_flags

!no_right:

    // B → FIRE.

    txa
    and #KEY_B_BIT
    beq !no_fire+
    lda input_flags
    ora #INPUT_FIRE
    sta input_flags

!no_fire:

    // Tank-destruction dwell (F2): tick the timer and suppress player
    // control. Lives in the keyboard scan because it runs every frame and
    // gates the same input_flags. The audio restore (which needs the sound
    // consts) is tank_exit_dwell, placed after sound.asm.

    lda tank_dwell
    beq !ready+                                 // Tank alive → normal control.
    dec tank_dwell
    beq !expired+                               // Dwell just hit 0 this frame.
    jsr tank_fire_step                          // Still destroyed: flash the tank-burn fire (F4).
    jmp !muted+

!expired:

    jsr tank_exit_dwell                         // Restore audio + force a clean tank re-plot.

!muted:

    lda #$00
    sta input_flags                             // No player control while destroyed.

!ready:

    lda input_flags
    rts
