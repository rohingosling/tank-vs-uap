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
//   Unified projectile pool: the bomb aim + cap-count helpers (the upper-block
//   part). Split out of proj.asm to fit fragmented free RAM. See proj.asm /
//   proj-defs.asm.
//
//*******************************************************************************

#importonce

#import "proj-defs.asm"

// uap_x_hi / uap_y_hi are resolved globally from uap.asm (imported in the
// upper block); do not #import it here.

//------------------------------------------------------------------------------
//
// Subroutine: proj_init
//
// Description:
//
//   Arms the bomb roll timer and sets the starting lives count (the
//   HUD icons are drawn by draw_hud). init_zp_state has already zeroed the
//   zero page, so all slot kinds are PROJ_FREE and reload_timer is 0. no
//   clear loop is needed. Lives here (upper block, not proj.asm's charset
//   tail) since the pool grew to 46 slots and took the tail's last bytes;
//   called cross-region from enter_play (overlay3).
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

proj_init:

    lda #BOMB_ROLL_FRAMES
    sta bomb_roll_timer
    lda #LIVES_START                            // full lives.
    sta lives
    rts

//------------------------------------------------------------------------------
//
// Subroutine: bomb_total_count
//
// Description:
//
//   Counts the active bombs across the whole pool (kind bit 7 set).
//   try_fire_bombs uses the count to enforce MAX_ACTIVE_BOMBS. a GLOBAL
//   concurrent-bomb cap (replacing the old per-UAP cap) that bounds the canvas
//   pool's peak cell demand so it is not exhausted under heavy fire. The cap
//   is global rather than per-UAP because the canvas pool is a shared, global
//   resource. Preserving X costs nothing extra: the caller (a UAP-slot loop)
//   needs X back for bomb_aim_decide.
//
// Outputs:
//
//   A - Total active bombs across the whole pool.
//
// Clobbers: A, Y (X is saved and restored).
//
//------------------------------------------------------------------------------

bomb_total_count:

    stx bd_dx                                   // Stash the caller's X (UAP slot).
    ldy #$00
    ldx #PROJ_MAX - 1

!loop:

    lda proj_kind, x
    bpl !skip+                                  // Bit 7 clear → free or bullet, not a bomb.
    iny

!skip:

    dex
    bpl !loop-
    ldx bd_dx                                   // Restore X.
    tya
    rts

//------------------------------------------------------------------------------
//
// Subroutine: bomb_aim_decide
//
// Description:
//
//   Decides whether UAP X is aligned to drop a bomb on the tank, and with what
//   x step. dx = tank_x - uap_x (the centres cancel. both are 16 wide);
//   dy = target_y - uap_y.
//
// Parameters:
//
//   X - UAP slot (preserved).
//
// Outputs:
//
//   Carry set   - Aligned; bd_vx = x step (0 overhead / ±BOMB_VX_DIAG diagonal).
//   Carry clear - Not aligned.
//
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

bomb_aim_decide:

    lda tank_x_hi
    sec
    sbc uap_x_hi, x                             // dx (signed).
    sta bd_dx
    lda #BOMB_TARGET_Y
    sec
    sbc uap_y_hi, x                             // dy (> 0 in normal play).
    sta bd_dy

    lda bd_dx                                   // |dx| + sign (Y so X = UAP survives).
    bpl !pos+
    eor #$ff
    clc
    adc #1
    ldy #$ff
    sty bd_sign
    jmp !abs+

!pos:

    ldy #$00
    sty bd_sign

!abs:

    cmp #BOMB_ALIGN_TOL + 1                     // Overhead? |dx| ≤ TOL.
    bcs !chkdiag+
    lda #$00                                    // Straight down.
    sta bd_vx
    sec
    rts

!chkdiag:

    sec                                         // Diagonal? | |dx| - dy | ≤ TOL.
    sbc bd_dy
    bpl !d1+
    eor #$ff
    clc
    adc #1

!d1:

    cmp #BOMB_ALIGN_TOL + 1
    bcs !nofire+
    lda bd_sign                                 // 45° toward the tank.
    beq !right+
    lda #BOMB_VX_LEFT
    jmp !setvx+

!right:

    lda #BOMB_VX_RIGHT

!setvx:

    sta bd_vx
    sec
    rts

!nofire:

    clc
    rts
