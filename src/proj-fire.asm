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
//   Unified projectile pool: the per-frame bomb-roll pass (the lower-block
//   part). Split out of proj.asm to fit fragmented free RAM. Calls
//   bomb_total_count / bomb_aim_decide (proj-bomb.asm) and bomb_launch
//   (proj.asm). See proj-defs.asm.
//
//*******************************************************************************

#importonce

#import "proj-defs.asm"

// UAP_COUNT / UAP_STATE_FLYING / uap_state are resolved globally from uap.asm
// (imported in the upper block). We must NOT #import uap.asm here. this file
// lands in the lower block, and the import would place the whole UAP module
// here.

//------------------------------------------------------------------------------
//
// Subroutine: try_fire_bombs
//
// Description:
//
//   Every BOMB_ROLL_FRAMES, each flying and aligned UAP rolls to drop a bomb,
//   subject to the global MAX_ACTIVE_BOMBS cap.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

try_fire_bombs:

    dec bomb_roll_timer
    bne !skip+                                  // Not time to roll yet → share the final rts.
    lda #BOMB_ROLL_FRAMES
    sta bomb_roll_timer
    lda tank_dwell                              // F2: no bombs while the tank is destroyed (UAPs still fly).
    bne !skip+
    ldx uap_top                                 // Only the active UAPs roll to fire (difficulty-scaled).

!loop:

    lda uap_state, x
    cmp #UAP_STATE_FLYING
    bne !next+
    jsr random_next
    cmp #BOMB_FIRE_CHANCE
    bcs !next+                                  // No fire this roll.
    jsr bomb_total_count                        // A = total active bombs across the pool.
    cmp #MAX_ACTIVE_BOMBS
    bcs !next+                                  // At the global cap → keep the canvas pool from exhausting.
    jsr bomb_aim_decide                         // X = UAP; carry set = aligned (bd_vx = step).
    bcc !next+
    jsr bomb_launch                             // X = UAP (preserved); uses bd_vx.

!next:

    dex
    bpl !loop-

!skip:

    rts
