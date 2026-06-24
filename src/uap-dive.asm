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
//   The UAP death-dive descent step (simplified to a straight-down dive to
//   save code space and cycles). A shot-down UAP (state
//   DIVING) falls each frame; if its base reaches the tank while overlapping
//   in x it crashes INTO the tank (-1 life), otherwise it crashes at the
//   ground (row 20). Either outcome respawns it off-screen via
//   uap_reset_offscreen and lets the render scheduler erase the wreck at its
//   old (drawn) position.
//
//   Resident in the free RAM gap in the $1800 page (CANVAS_RAM_END ..
//   SOUND_RAM_BASE). the only sizeable free area left at the RAM ceiling.
//   The includer sets .pc = CANVAS_RAM_END and guards the tail against
//   SOUND_RAM_BASE. Called by advance_uaps (cross-region); calls
//   uap_reset_offscreen (uap.asm, upper block) and tank_lose_life
//   (collide.asm, charset tail).
//
//*******************************************************************************

#importonce

#import "constants.asm"
#import "uap-defs.asm"

//==============================================================================
// Constants
//==============================================================================

//------------------------------------------------------------------------------
// VIC Soprano voice register. for silencing the dive beep when the dive ends.
//
// Derived from VIC_SOUND_BASE (constants.asm, available early) NOT from
// sound.asm's VOICE_SOPRANO: this file is imported into the LOWER block BEFORE
// sound.asm, so VOICE_SOPRANO is not yet defined when Kick Assembler sizes this
// absolute store (it would error "Reference to not yet defined symbol"). The
// ground-burn hiss (Noise) is written by uap_burn_noise, which lives in the
// $1800 ceiling gap (tank-vs-uap.asm) because this file fills the lower block.
//------------------------------------------------------------------------------

.const VIC_SOUND_SOPRANO        = VIC_SOUND_BASE + 2  // $900C: the dive beep voice.

//==============================================================================
// Subroutines — Death Dive
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: uap_dive_step
//
// Description:
//
//   One frame of the death dive for the UAP in slot X: descend straight
//   down, then crash into the tank (-1 life) or park as a burning wreck at
//   the ground (row 20). A UAP already in state CRASHED is routed to
//   uap_crash_dwell instead.
//
// Parameters:
//
//   X - Diving UAP slot. Preserved (saved across tank_lose_life, which
//       clobbers it).
//
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

uap_dive_step:

    // A burning wreck (CRASHED) is parked on the ground: count its dwell, do
    // not descend.

    lda uap_state, x
    cmp #UAP_STATE_CRASHED
    beq uap_crash_dwell

    // High metallic beep while the wreck DIVES (gated ~46 ms on/off, Soprano;
    // uap_dive_beep, overlay3). Silenced when the dive ends. ground crash or
    // tank crash, below. Clobbers A only (X / Y preserved).

    jsr uap_dive_beep

    // Descend: y += UAP_DIVE_VY (8.8); x is unchanged (straight down).

    clc
    lda uap_y_lo, x
    adc #<UAP_DIVE_VY
    sta uap_y_lo, x
    lda uap_y_hi, x
    adc #>UAP_DIVE_VY
    sta uap_y_hi, x

    // Has the wreck fallen to the tank's level?
    // (A still holds the just-stored hi byte. no reload needed.)

    cmp #UAP_WRECK_TANK_Y
    bcc !ground+                                // still above the tank → only the
                                                // ground can catch it.

    // x overlap with the tank? (AABB; both boxes inset 1 px/side, so each
    // far offset is -1 to fold in the opposing box's near inset. see
    // uap-defs.asm.)

    lda uap_x_hi, x                             // wreck inset right edge vs tank inset left.
    clc
    adc #UAP_HIT_FAR_X - 1
    cmp tank_x_hi
    bcc !ground+
    lda tank_x_hi                               // tank inset right edge vs wreck inset left.
    clc
    adc #TANK_HIT_FAR_X - 1
    cmp uap_x_hi, x
    bcc !ground+

    // Wreck crashes into the tank: respawn the wreck, then the tank loses a
    // life. tank_lose_life silences the dive beep (Soprano) for us, so the
    // dive's end is handled there even on an ignored re-hit.

    jsr uap_reset_offscreen
    txa
    pha                                         // tank_lose_life clobbers X (the UAP slot).
    jsr tank_lose_life
    pla
    tax
    rts

!ground:

    // Reached the ground (row 20)? Become a burning wreck for
    // CRASH_DWELL_FRAMES.

    lda uap_y_hi, x
    cmp #UAP_GROUND_Y
    bcc !done+

    // Dive over: silence the beep (Soprano); the steady ground-burn hiss
    // (Noise) takes over in uap_crash_dwell from next frame.

    lda #$00
    sta VIC_SOUND_SOPRANO

    // Freeze at the crash line so the wreck stays drawn (the render
    // scheduler leaves an unmoving sprite in place).

    lda #UAP_GROUND_Y
    sta uap_y_hi, x
    lda #UAP_STATE_CRASHED
    sta uap_state, x
    lda #CRASH_DWELL_FRAMES
    sta uap_revec, x                            // reuse the idle re-vector timer as
                                                // the dwell countdown.

!done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: uap_crash_dwell
//
// Description:
//
//   Counts the ground-burn dwell down for the crashed UAP in slot X; on
//   expiry fly a fresh UAP in (uap_reset_offscreen sets FLYING). While
//   dwelling, y is frozen so the wreck stays on the ground. Preserves X.
//
// Parameters:
//
//   X - Crashed UAP slot.
//
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

uap_crash_dwell:

    dec uap_revec, x
    beq !respawn+

    // No burn audio: the wreck smolders SILENTLY on the ground. The single
    // explosion already played when the bullet hit the UAP (sound_air_explosion
    // in hit_uap, collide.asm); the old per-frame white-noise burn hiss
    // (uap_burn_noise) is no longer driven. The high beep plays during the DIVE
    // (uap_dive_beep, overlay3); uap_crash_end still silences the Noise voice.

    // F3 crash fire: flash an explosion at a random x along the wreck's top
    // edge each frame. The fx engine is pool-of-1 + auto-erasing, so this
    // self-paces (~100 ms) and erodes the wreck as it burns. fx_spawn
    // (A = x, Y = y) may clobber X (the slot), but we no longer need it.

    ldy #UAP_FIRE_Y                             // y = in-bounds burn line over the wreck
                                                // (NOT the wreck's own y = 160, whose
                                                // 13-px fx would erode the static ground
                                                // row 21).
    jsr random_next                             // preserves Y.
    and #UAP_FIRE_XMASK
    clc
    adc uap_drawn_x, x                          // A = wreck x + random jitter.
    jmp fx_spawn                                // tail-call (rts there); drops if an fx
                                                // is already showing.

!respawn:

    jmp uap_crash_end                           // silence the burn hiss, then respawn
                                                // off-screen (overlay3).
