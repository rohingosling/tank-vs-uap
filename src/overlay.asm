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
//   Disk code overlay, resident at $033C-$03FB (the cassette buffer; 192 B of
//   free RAM, never used since the game is disk-only). Assembled into the
//   Overlay segment and written to a separate overlay.prg, loaded from the
//   .d64 at boot by load_overlay (tank-vs-uap.asm). It is part of the SAME
//   assembly as the main program, so it calls into the $1xxx blocks freely
//   (cross-segment symbols resolve at assembly time).
//
//   Holds code relocated out of the full $1xxx blocks. Currently:
//   proj_update_render. the per-frame projectile integrate + draw loop
//   (moved from proj.asm to free charset-tail room for collisions).
//
//*******************************************************************************

#importonce

#import "proj-defs.asm"

//------------------------------------------------------------------------------
//
// Subroutine: proj_update_render
//
// Description:
//
//   One loop over the projectile pool: erase at the drawn position, integrate
//   (x += vx, y += vy) with byte adds, expire by kind (bullet above row 1;
//   bomb at the ground or a screen edge), else re-plot. set_proj_ptr /
//   erase_bitmap / plot_bitmap live in the $1xxx blocks; jsr reaches them
//   across the segment boundary.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

proj_update_render:

    ldx #PROJ_MAX - 1

!loop:

    lda proj_kind, x
    beq !next+                                  // free slot.

    jsr set_proj_ptr                            // ZP_BITMAP_PTR + bv_height by kind.
    lda proj_drawn_x, x
    sta bv_x
    lda proj_drawn_y, x
    sta bv_y
    jsr erase_bitmap                            // (erase/plot_bitmap preserve X = the slot.)

    // Integrate (signed byte steps).

    lda proj_x, x
    clc
    adc proj_vx, x
    sta proj_x, x
    lda proj_y, x
    clc
    adc proj_vy, x
    sta proj_y, x

    // Expire by kind.

    lda proj_kind, x
    bmi !bombexp+
    lda proj_y, x                               // bullet: above row 1?
    cmp #BULLET_Y_EXPIRE
    bcc !expire+
    bcs !plot+                                  // always taken (bcc above fell through, so C = 1).

!bombexp:

    // Bomb: off either side expires silently (underflow wraps high; checked
    // FIRST so an off-screen bomb never spawns a puff). Reaching the ground
    // spawns the ground puff. the top half of the explosion bitmap, drawn as
    // a dome on the ground line for the same FX_LIFE_FRAMES as an air burst.
    // then expires. No score and no sound (the old +1 trickle was removed: it
    // broke the all-scores-are-multiples-of-5 property for no real value).

    lda proj_x, x
    cmp #BOMB_X_MAX
    bcs !expire+
    lda proj_y, x
    cmp #BOMB_Y_EXPIRE
    bcc !plot+
    lda proj_x, x                               // ground hit: puff at the bomb's x, on the
    ldy #FX_GROUND_PUFF_Y                       //   puff line (drop-if-busy; X survives.
    jsr fx_spawn                                //   fx_spawn / plot_bitmap preserve it).
    jmp !expire+

!plot:

    // ZP_BITMAP_PTR + bv_height are still set from the erase pass above (the
    // blitter only reads them. bv_height is copied to bv_remaining; neither
    // is written), and the kind is unchanged, so no second set_proj_ptr is
    // needed here.

    lda proj_x, x
    sta bv_x
    lda proj_y, x
    sta bv_y

    // Bomb animation: PLOT with the current frame (bomb_frame_lo). The erase
    // above used frame 1 (set_proj_ptr's default = the full-diamond
    // superset), so it cleared whatever frame was last drawn; here we just
    // swap the low byte (both frames share a page). X still = slot.

    lda proj_kind, x
    bpl !plotnow+                               // bullet → keep its bitmap.
    lda bomb_frame_lo
    sta ZP_BITMAP_PTR

!plotnow:

    jsr plot_bitmap                             // (plot_bitmap preserves X = the slot.)
    lda proj_x, x
    sta proj_drawn_x, x
    lda proj_y, x
    sta proj_drawn_y, x
    jmp !next+

!expire:

    lda #PROJ_FREE                              // free the slot (already erased above).
    sta proj_kind, x

!next:

    dex
    bpl !loop-
    rts

//------------------------------------------------------------------------------
//
// Subroutine: check_bullet_bombs
//
// Description:
//
//   Scan the pool for a bomb overlapping the bullet; on the first overlap
//   tail-call hit_bullet_bomb ($1xxx) which kills both and returns. Lives
//   here in the overlay to keep collide.asm within the charset tail.
//   (Edge-touch counts as a hit. the bcc-only tests, the same 1px-generous
//   box as the other AABBs.)
//
// Inputs:
//
//   ch_px, ch_py - Bullet box position.
//   ch_slot      - Bullet slot.
//
// Clobbers: A, X (plus whatever hit_bullet_bomb clobbers when a bomb is hit).
//
//------------------------------------------------------------------------------

check_bullet_bombs:

    ldx #PROJ_MAX - 1

!bmb:

    lda proj_kind, x
    bpl !bmbnext+                               // not a bomb (free or bullet; bit 7 clear).
    lda ch_px                                   // bullet right edge vs bomb left.
    clc
    adc #BULLET_WIDTH
    cmp proj_x, x
    bcc !bmbnext+
    lda proj_x, x                               // bomb right edge vs bullet left.
    clc
    adc #BOMB_WIDTH
    cmp ch_px
    bcc !bmbnext+
    lda ch_py                                   // bullet bottom vs bomb top.
    clc
    adc #BULLET_HEIGHT
    cmp proj_y, x
    bcc !bmbnext+
    lda proj_y, x                               // bomb bottom vs bullet top.
    clc
    adc #BOMB_HEIGHT
    cmp ch_py
    bcc !bmbnext+
    jmp hit_bullet_bomb                         // X = bomb, ch_slot = bullet; kills both,
                                                // rts to our caller.

!bmbnext:

    dex
    bpl !bmb-
    rts

//------------------------------------------------------------------------------
//
// Subroutine: set_proj_ptr
//
// Description:
//
//   Point ZP_BITMAP_PTR at the slot's bitmap and set bv_height by kind.
//   Resident here in the overlay (called by proj_update_render above and,
//   cross-region, by kill_proj in collide.asm). moved off the full charset
//   tail. bullet_bitmap (lower block) and bomb_bitmap (charset tail) resolve
//   globally at assembly time.
//
// Parameters:
//
//   X - Projectile slot index.
//
// Outputs:
//
//   ZP_BITMAP_PTR - Points at the slot's bitmap.
//   bv_height     - Bitmap height for the slot's kind.
//
// Clobbers: A (X is preserved).
//
//------------------------------------------------------------------------------

set_proj_ptr:

    lda proj_kind, x
    bmi !bomb+
    lda #<bullet_bitmap
    sta ZP_BITMAP_PTR
    lda #>bullet_bitmap
    sta ZP_BITMAP_PTR + 1
    lda #BULLET_HEIGHT
    sta bv_height
    rts

!bomb:

    // Animation deferred: a correct, residue-free two-frame bomb
    // needs per-bomb phase tracking, which needs ~19 B of overlay
    // restructuring this full overlay can't hold.

    lda #<bomb_bitmap_1
    sta ZP_BITMAP_PTR
    lda #>bomb_bitmap_1
    sta ZP_BITMAP_PTR + 1
    lda #BOMB_HEIGHT
    sta bv_height
    rts
