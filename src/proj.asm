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
//   Unified integer projectile pool (tank bullets + UAP bombs). the
//   charset-tail part. One pool, one update/render loop, and integer
//   kinematics (no 8.8 fixed-point). the unified projectile pool. Replaces
//   the old separate 8.8 bullet pool and the standalone bomb
//   module so aimed bombs fit in RAM. Bullets travel an integer 2 px/frame
//   (~100 px/s, vs the old 88). tunable. Slot kind: $00 free, $01 bullet,
//   $80|owner bomb (bit 7 = bomb, low bits = owner UAP).
//
//   The pool is split across three free holes (the project is at its RAM
//   ceiling): this file holds the bulk (render + bullet fire + launch);
//   proj-bomb.asm (bomb aim + cap count + proj_init) lands in the upper
//   block and proj-fire.asm (the bomb-roll pass) in the lower block. Shared
//   declarations are in proj-defs.asm (zero bytes).
//
//*******************************************************************************

#importonce

#import "proj-defs.asm"
#import "input.asm"                             // input_flags, INPUT_FIRE.
#import "sprites/bullet.asm"                    // bullet_bitmap.

// bomb_bitmap was moved to sprites/bomb.asm (imported into the upper block) so
// the charset tail has room for the FX engine. Resolved here as a cross-region
// symbol.

// proj_init lives in proj-bomb.asm (upper block). moved off this charset
// tail to fund the pool's growth to 46 slots (the tail base moved $1610 →
// $1618 when the retired sentinel cell + one more slot joined the pool).

//------------------------------------------------------------------------------
//
// Subroutine: fire_bullets
//
// Description:
//
//   Ticks the gun reload timer; on the fire button (B) with a free slot,
//   spawns a bullet from the muzzle (x by facing. east +3 / west +11), plus
//   the muzzle-flash FX over the barrel. No bullet plot here;
//   proj_update_render draws it next frame (the flash plots at spawn).
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

fire_bullets:

    lda reload_timer
    beq !ready+
    dec reload_timer
    rts

!ready:

#if !AUTOFIRE
    lda input_flags                             // The AUTOFIRE headless build skips the input check →
    and #INPUT_FIRE                             // always fires, subject to reload + a free slot.
    beq !done+                                  // Tail-resident, so no upper-block stub needed.
#endif
    ldx #PROJ_MAX - 1                           // Find a free slot.

!find:

    lda proj_kind, x
    beq !spawn+
    dex
    bpl !find-
    rts                                         // Pool full.

!spawn:

    lda tank_facing                             // Muzzle x by facing.
    bne !left+
    lda #GUN_X_OFFSET
    bne !setx+                                  // Always taken (GUN_X_OFFSET = 3, nonzero). 1 B
                                                //   cheaper than jmp; funds the fx_setup height select.

!left:

    lda #GUN_X_OFFSET_LEFT

!setx:

    clc
    adc tank_x_hi
    sta proj_x, x
    sta proj_drawn_x, x
    lda #BULLET_SPAWN_Y
    sta proj_y, x
    sta proj_drawn_y, x
    lda #$00
    sta proj_vx, x                              // Straight up.
    lda #BULLET_VY_UP
    sta proj_vy, x
    lda #PROJ_BULLET
    sta proj_kind, x
    lda #RELOAD_FRAMES
    sta reload_timer

    // Muzzle flash over the barrel: flash x = bullet x - MUZZLE_FLASH_GUN_X
    // (works for both facings. the art is symmetric). X (the slot) is dead
    // from here on, so the FX / sound clobbers are fine.

    lda proj_x, x
    sec
    sbc #MUZZLE_FLASH_GUN_X
    ldy #MUZZLE_FLASH_Y
    jsr fx_spawn_muzzle

    jsr sound_gun                               // Gun-shot crack (noise voice).

!done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: bomb_launch
//
// Description:
//
//   Claims a free pool slot and places a bomb at the UAP. No plot here;
//   proj_update_render draws it next frame. X is reused as the slot index
//   during the claim; the UAP index is carried in the kind byte (bd_sign) and
//   on the stack, then restored for the caller.
//
// Parameters:
//
//   X     - Owner UAP slot (preserved).
//   bd_vx - Chosen bomb x step.
//
// Clobbers: A, Y (Y via sound_bomb_drop; X is saved and restored).
//
//------------------------------------------------------------------------------

bomb_launch:

    lda uap_x_hi, x                             // Launch x = UAP centre.
    clc
    adc #BOMB_LAUNCH_X_OFF
    sta bd_dx
    lda uap_y_hi, x                             // Launch y = UAP underside.
    clc
    adc #BOMB_LAUNCH_Y_OFF
    sta bd_dy
    txa
    pha                                         // UAP for the final restore (pushed
                                                //   before the ora so one txa serves both).
    ora #PROJ_BOMB                              // Kind = $80 | owner.
    sta bd_sign

    ldx #PROJ_MAX - 1                           // Find a free slot.

!find:

    lda proj_kind, x
    beq !found+
    dex
    bpl !find-
    pla                                         // Pool full. restore X, give up.
    tax
    rts

!found:

    lda bd_sign                                 // Claim slot X for the UAP.
    sta proj_kind, x
    lda bd_dx
    sta proj_x, x
    sta proj_drawn_x, x
    lda bd_dy
    sta proj_y, x
    sta proj_drawn_y, x
    lda bd_vx
    sta proj_vx, x
    lda #BOMB_VY_DOWN
    sta proj_vy, x
    jsr sound_bomb_drop                         // Bomb-drop blip (tenor voice); clobbers X, restored below.
    pla                                         // Restore X = UAP for the caller.
    tax
    rts

//------------------------------------------------------------------------------
// Relocated subroutines — disk overlay ($033C).
//
// proj_update_render lives in the disk overlay ($033C). see overlay.asm. It is
// the per-frame projectile integrate + draw pass: one loop over the pool.
// erase at the drawn position, integrate (x += vx, y += vy) with byte adds,
// expire by kind (bullet above row 1; bomb at ground or a screen edge), else
// re-plot. Drawn directly each frame; X = slot, saved across the canvas calls.
// It was relocated there to free charset-tail room for the collision code.
//
// set_proj_ptr lives in the disk overlay ($033C) alongside proj_update_render.
// see overlay.asm. (X = slot → ZP_BITMAP_PTR + bv_height by kind.) Called from
// the overlay and from kill_proj / bomb_launch in the $1xxx blocks via
// cross-segment jsr.
//------------------------------------------------------------------------------
