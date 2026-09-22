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
//   UAP billiard-bounce flight, spawn, and (later) death dive + bomb aiming.
//
//   Contract. Each UAP carries an 8.8 position and an 8.8
//   velocity drawn from an 8-direction (45°) assembly-time table that is
//   closed under reflection. so a bounce just negates the crossed axis and
//   stays a table entry, no renormalisation. Per frame: integrate, CLAMP to
//   the flight region AFTER integrating (avoids v1's edge-underflow wrap),
//   then bounce. Integer-only, no per-frame divide.
//
//   State is parallel zero-page arrays indexed by slot (SoA). Rendering goes
//   through the canvas and is driven by the budgeted render scheduler in
//   tank-vs-uap.asm.
//
//*******************************************************************************

#importonce

#import "constants.asm"
#import "uap-defs.asm"                          // UAP zero-page SoA map + state enum
                                                // (shared, zero bytes).
#import "sprites/uap.asm"                       // uap_bitmap, UAP_HEIGHT.

//==============================================================================
// Constants — Tuning
//==============================================================================

// UAP_MAX / UAP_COUNT live in constants.asm. the scheduler needs them early.

.const UAP_SPEED                = pxPerSecToDelta( 66 )               // cardinal component, 8.8 (~337).
.const UAP_SPEED_DIAG           = floor( UAP_SPEED * 7071 / 10000 )   // diagonal component (~238).

.const UAP_X_MIN                = 0
.const UAP_X_MAX                = SCREEN_COLUMNS * 8 - 16   // 160 (16-px blitter width).
.const UAP_Y_MIN                = CANVAS_ROW_TOP * 8        // row 1 → 8.
.const UAP_Y_MAX                = 16 * 8                    // row 16 → 128 (flight rows 1-16).

// UAP_STATE_* and the SoA zero-page map live in uap-defs.asm (imported above;
// shared with proj-*).

// Random re-vector interval. the *primary* motion. Each UAP counts this many
// frames down, then picks a new random direction. Expressed in wall-clock ms
// and resolved to frames at assembly time so PAL/NTSC match. The runtime
// reduction folds a 7-bit random byte into the span, so the span must fit
// 7 bits.

.const REVEC_MIN_FRAMES         = msToFrames( 200 )         // interval floor (10 PAL / 12 NTSC).
.const REVEC_MAX_FRAMES         = msToFrames( 2000 )        // interval ceiling (100 PAL / 120).
.const REVEC_SPAN_FRAMES        = REVEC_MAX_FRAMES - REVEC_MIN_FRAMES

.errorif (REVEC_SPAN_FRAMES > 127), "re-vector span must fit the 7-bit random reduction"

//==============================================================================
// Data — UAP Velocity Table
//==============================================================================

//------------------------------------------------------------------------------
// 8-direction velocity table (8.8 signed vx, vy).
//
// 45° steps; closed under axis negation: negating vx maps E ↔ W, SE ↔ SW,
// NE ↔ NW (N, S fixed); negating vy maps N ↔ S etc.
//------------------------------------------------------------------------------

uap_velocity_table:

    .word  UAP_SPEED,       0                   // 0: E
    .word  UAP_SPEED_DIAG,  UAP_SPEED_DIAG      // 1: SE
    .word  0,               UAP_SPEED           // 2: S
    .word -UAP_SPEED_DIAG,  UAP_SPEED_DIAG      // 3: SW
    .word -UAP_SPEED,       0                   // 4: W
    .word -UAP_SPEED_DIAG, -UAP_SPEED_DIAG      // 5: NW
    .word  0,              -UAP_SPEED           // 6: N
    .word  UAP_SPEED_DIAG, -UAP_SPEED_DIAG      // 7: NE

//==============================================================================
// Subroutines — Spawn and Re-vector
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: uap_set_random_velocity
//
// Description:
//
//   Loads (vx, vy) for the UAP in slot X from a random direction in
//   uap_velocity_table.
//
// Parameters:
//
//   X - UAP slot. Preserved (random_next preserves X and Y; Y is used here
//       only as the table index).
//
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

uap_set_random_velocity:

    jsr random_next
    and #$07
    asl
    asl                                         // dir * 4 bytes.
    tay
    lda uap_velocity_table + 0, y
    sta uap_vx_lo, x
    lda uap_velocity_table + 1, y
    sta uap_vx_hi, x
    lda uap_velocity_table + 2, y
    sta uap_vy_lo, x
    lda uap_velocity_table + 3, y
    sta uap_vy_hi, x
    rts

//------------------------------------------------------------------------------
//
// Subroutine: uap_set_random_revec_timer
//
// Description:
//
//   Re-arms the re-vector timer for the UAP in slot X to a random frame
//   count in [REVEC_MIN_FRAMES, REVEC_MAX_FRAMES]. A 7-bit random byte is
//   folded back into the span (one conditional subtract) so the result is
//   always in range. no per-event divide.
//
// Parameters:
//
//   X - UAP slot. Preserved.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

uap_set_random_revec_timer:

    jsr random_next
    and #$7f                                    // 0..127.
    cmp #REVEC_SPAN_FRAMES + 1
    bcc !add_min+                               // already ≤ span: use as-is.
    sbc #REVEC_SPAN_FRAMES                      // carry set from cmp → subtract
                                                // exactly the span (fold).

!add_min:

    clc
    adc #REVEC_MIN_FRAMES
    sta uap_revec, x
    rts

//------------------------------------------------------------------------------
//
// Subroutine: uap_init
//
// Description:
//
//   Spawns all active UAPs.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

uap_init:

    // Start with 1 active UAP (slot 0); difficulty raises uap_top.

    ldx #UAP_START_TOP
    stx uap_top                                 // X = uap_top = the start slot for the loop.

!loop:

    jsr uap_spawn
    dex
    bpl !loop-
    rts

//------------------------------------------------------------------------------
//
// Subroutine: uap_spawn
//
// Description:
//
//   Re-arms an off-screen entry (uap_reset_offscreen) AND draws it once at
//   the spawn point. Used at game start, when there is nothing on screen yet
//   to erase.
//
// Parameters:
//
//   X - UAP slot. Preserved.
//
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

uap_spawn:

    jsr uap_reset_offscreen
    lda uap_x_hi, x
    sta uap_drawn_x, x
    lda uap_y_hi, x
    sta uap_drawn_y, x

    // Plot at the spawn point (shared helper; tail call. plot_bitmap's rts
    // returns to uap_spawn's caller).

    jmp uap_plot_current

//------------------------------------------------------------------------------
//
// Subroutine: uap_reset_offscreen
//
// Description:
//
//   Re-arms a UAP to fly in from a random screen edge: random velocity +
//   re-vector timer, off-screen x, random flight-region y, state = FLYING.
//   Does NOT touch the draw cache or plot, so the death-dive crash path can
//   call it and let the render scheduler erase the wreck at its old (drawn)
//   position and plot the fly-in next refresh.
//
// Parameters:
//
//   X - UAP slot. Preserved.
//
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

uap_reset_offscreen:

    // Velocity from a random table direction, and arm the first re-vector
    // timer.

    jsr uap_set_random_velocity
    jsr uap_set_random_revec_timer

    // Enter from the left or right edge (table-driven: 1 random bit → table
    // index).

    jsr random_next
    and #$01
    tay
    lda uap_spawn_x_edges, y
    sta uap_x_hi, x
    lda #$00
    sta uap_x_lo, x

    // Random y within the flight region.

    jsr random_next
    and #$7f
    clc
    adc #UAP_Y_MIN
    cmp #UAP_Y_MAX + 1
    bcc !set_y+
    lda #UAP_Y_MAX

!set_y:

    sta uap_y_hi, x
    lda #$00
    sta uap_y_lo, x

    lda #UAP_STATE_FLYING
    sta uap_state, x
    rts

//==============================================================================
// Subroutines — Flight Integration
//==============================================================================

//------------------------------------------------------------------------------
//
// Macro: integrate_axis
//
// Description:
//
//   Integrates one 8.8 axis for the UAP in X, clamps to
//   [axis_min, axis_max], and on a clamp negates the velocity (bounce). The
//   velocity sign selects which edge to test: moving toward max, clamp when
//   pos_hi > axis_max; moving toward min, clamp when pos_hi < axis_min OR
//   (an underflow wrap) pos_hi > axis_max. Checking BOTH bounds is required
//   because axis_min is not always 0 (the Y minimum is row 1 = 8); a
//   max-only test let UAPs slip up into row 0.
//
// Parameters:
//
//   pos_lo, pos_hi - 8.8 position array pair (indexed by X).
//   vel_lo, vel_hi - 8.8 signed velocity array pair (indexed by X).
//   axis_min       - inclusive minimum for pos_hi.
//   axis_max       - inclusive maximum for pos_hi.
//   negate         - subroutine that negates this axis's velocity.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

.macro integrate_axis( pos_lo, pos_hi, vel_lo, vel_hi, axis_min, axis_max, negate )
{
    clc
    lda pos_lo, x
    adc vel_lo, x
    sta pos_lo, x
    lda pos_hi, x
    adc vel_hi, x
    sta pos_hi, x

    // Decide which extreme to clamp to. Both axes have axis_max > 0 so
    // `lda #axis_max` always sets Z = 0. the bne to !clamp is unconditional,
    // letting the two clamp paths share their tail.

    lda vel_hi, x
    bmi !neg+

    // Moving toward max: clamp if pos_hi > axis_max.

    lda pos_hi, x
    cmp #axis_max + 1
    bcc !ok+
    lda #axis_max
    bne !clamp+                                 // always (axis_max != 0).

!neg:

    // Moving toward min: clamp if pos_hi < axis_min, or pos_hi > axis_max
    // (underflow wrap).

    lda pos_hi, x
    cmp #axis_min
    bcc !to_min+
    cmp #axis_max + 1
    bcc !ok+                                    // in [axis_min, axis_max].

!to_min:

    lda #axis_min

!clamp:

    sta pos_hi, x
    lda #$00
    sta pos_lo, x
    jsr negate

!ok:

}

//------------------------------------------------------------------------------
//
// Subroutine: advance_uaps
//
// Description:
//
//   Integrates every UAP one frame, clamps to the flight region, and
//   bounces.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

advance_uaps:

    // Iterate only the active slots (0..uap_top); difficulty-scaled.

    ldx uap_top

!loop:

    lda uap_state, x
    bpl !flying+                                // FLYING / INACTIVE (bit 7 clear) →
                                                // flight path (short skip).
    jsr uap_dive_step                           // UAP_STATE_DIVING ($80): descent +
                                                // crash/respawn + wreck → tank.
    jmp !next+

!flying:

    // Re-vector. the primary motion.
    // Count the per-UAP timer down; when it expires, choose a new random
    // direction and re-arm. Without this a cardinal spawn (E/W has vy = 0,
    // N/S has vx = 0) stays axis-locked, bouncing on one axis forever.
    // exactly the "stuck horizontal / stuck vertical" UAP bug.

    dec uap_revec, x
    bne !no_revec+
    jsr uap_set_random_velocity
    jsr uap_set_random_revec_timer

!no_revec:

    integrate_axis( uap_x_lo, uap_x_hi, uap_vx_lo, uap_vx_hi, UAP_X_MIN, UAP_X_MAX, negate_vx )
    integrate_axis( uap_y_lo, uap_y_hi, uap_vy_lo, uap_vy_hi, UAP_Y_MIN, UAP_Y_MAX, negate_vy )

!next:

    dex
    bmi !done+                                  // loop body exceeds branch range →
                                                // bmi/jmp, not bpl.
    jmp !loop-

!done:

    rts

//------------------------------------------------------------------------------
// Spawn-edge table, indexed by 1 random bit (0 → left, 1 → right).
//------------------------------------------------------------------------------

uap_spawn_x_edges:

    .byte UAP_X_MIN, UAP_X_MAX

//------------------------------------------------------------------------------
//
// Subroutine: negate_vx
//
// Description:
//
//   vx[X] = -vx[X] (16-bit two's complement).
//
// Parameters:
//
//   X - UAP slot. Preserved.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

negate_vx:

    sec
    lda #$00
    sbc uap_vx_lo, x
    sta uap_vx_lo, x
    lda #$00
    sbc uap_vx_hi, x
    sta uap_vx_hi, x
    rts

//------------------------------------------------------------------------------
//
// Subroutine: negate_vy
//
// Description:
//
//   vy[X] = -vy[X] (16-bit two's complement).
//
// Parameters:
//
//   X - UAP slot. Preserved.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

negate_vy:

    sec
    lda #$00
    sbc uap_vy_lo, x
    sta uap_vy_lo, x
    lda #$00
    sbc uap_vy_hi, x
    sta uap_vy_hi, x
    rts

//==============================================================================
// Subroutines — Rendering
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: uap_render
//
// Description:
//
//   Redraws the UAP in slot X only if the drawn position changed:
//   overlap-safe erase at the previous (drawn) position, then plot at the
//   current one. Preserves the slot in X across the canvas calls (which
//   clobber X).
//
// Parameters:
//
//   X - UAP slot. Preserved.
//
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

uap_render:

    lda uap_x_hi, x
    cmp uap_drawn_x, x
    bne !redraw+
    lda uap_y_hi, x
    cmp uap_drawn_y, x
    bne !redraw+
    rts

!redraw:

    // Erase at the previous (drawn) position.

    jsr set_uap_bitmap_ptr
    lda uap_drawn_x, x
    sta bv_x
    lda uap_drawn_y, x
    sta bv_y
    lda #UAP_HEIGHT
    sta bv_height
    jsr erase_bitmap                            // erase/plot_bitmap preserve X = the slot.

    // Plot at the current position (shared helper). erase_bitmap above only
    // READS ZP_BITMAP_PTR + bv_height (blit_run never writes them), so the
    // helper re-setting them is harmless and correct.

    jsr uap_plot_current

    // Update the draw cache.

    lda uap_x_hi, x
    sta uap_drawn_x, x
    lda uap_y_hi, x
    sta uap_drawn_y, x
    rts

//------------------------------------------------------------------------------
//
// Subroutine: uap_plot_current
//
// Description:
//
//   Plots the UAP in slot X at its CURRENT (uap_x_hi, uap_y_hi) position via
//   the canvas blitter. Factored out of uap_spawn and uap_render (their plot
//   blocks were byte-identical). Tail-calls plot_bitmap, so plot_bitmap's rts
//   returns to uap_plot_current's caller; X is preserved throughout
//   (set_uap_bitmap_ptr is A-only; plot_bitmap / blit_run save+restore X).
//
// Parameters:
//
//   X - UAP slot. Preserved.
//
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

uap_plot_current:

    jsr set_uap_bitmap_ptr
    lda uap_x_hi, x
    sta bv_x
    lda uap_y_hi, x
    sta bv_y
    lda #UAP_HEIGHT
    sta bv_height
    jmp plot_bitmap                             // tail call (rts there); X preserved.

// set_uap_bitmap_ptr lives in uap-tail.asm (now imported in the upper block,
// directly after this file); it is called from uap_plot_current above.
