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
//   Shared explosion FX engine (air + ground + muzzle flash), pool-of-1,
//   single frame. The burst bitmap serves three events: air explosion
//   (bullet hits a UAP or a bomb, full 13 rows), the UAP crash burn (full
//   height at the ground), and the bomb ground puff (a bomb reaches the
//   ground: TOP HALF of the bitmap only, spawned at FX_GROUND_PUFF_Y by
//   proj_update_render). A second kind. the 8 x 5 tank-gun muzzle flash
//   (fx_spawn_muzzle, fired from fire_bullets). shares the engine, timer,
//   and FX_LIFE_FRAMES duration; fx_kind selects the bitmap + height.
//
//   Pool-of-1 trade-offs (accepted): firing while a burst is on screen shows
//   no flash, and a burst spawning within FX_LIFE_FRAMES of a shot is
//   dropped. (The bullet spawns ABOVE the flash window. BULLET_SPAWN_Y in
//   proj-defs.asm. so its per-frame erase can never punch through the
//   flash's centre pixels.)
//
//   CONTRACT: the whole engine PRESERVES X. proj_update_render's ground-puff
//   spawn runs mid-loop with X = the projectile slot and frees that slot
//   right after. clobbering X there frees slot 0 instead, leaving a zombie
//   bomb at the ground (lingering puff) whose y then wraps into the sky.
//
//   One shared bitmap source for air and ground; FX richness is the first
//   thing to shrink under RAM pressure. Reduced to a
//   single static frame (no animation). the explosion appears at (x, y) for
//   ~1 s and then is erased on timer expiry.
//
//   Pool of 1, "drop if busy": a new spawn during an active FX is IGNORED
//   (the existing burst finishes its display). This avoids the cost of
//   erase-on-overwrite. the rapid-fire UAP-kill case is the one place this
//   could matter, and missing the second-of-two FX visuals reads as fine.
//
//   State lives at ZP $98-$9A (just past the score digits). init_zp_state's
//   ZP_GAME_LAST_PLUS_ONE has been extended to $9C, so this state starts as
//   0 (free) automatically. no fx_init needed. (fx_kind at $A4 sits outside
//   the wipe; see its declaration for why that is safe.)
//
//   Placement: in the charset tail with the bitmap data + projectile tail
//   code (lands wherever the includer sets .pc).
//
//*******************************************************************************

#importonce

#import "constants.asm"
#import "sprites/fx.asm"                        // fx_bitmap + FX_HEIGHT,
                                                // muzzle_flash_bitmap +
                                                // MUZZLE_FLASH_HEIGHT (data
                                                // already emitted in the
                                                // upper block; #importonce).

//==============================================================================
// Constants
//==============================================================================

// Zero-page FX state, at $98-$9A (just past the score digits).

.const fx_x                     = $98           // Current FX x (pixel).
.const fx_y                     = $99           // Current FX y (pixel).
.const fx_timer                 = $9a           // Ticks remaining (0 = free / no FX active).

// Active-FX kind. Lives at $A4 (after bomb_frame_lo $A3), OUTSIDE
// init_zp_state's $02-$9B wipe. safe uninitialised, because fx_setup only
// reads it while fx_timer != 0, and every spawn that claims the (cold-started)
// timer latches the kind first.

.const fx_kind                  = $a4           // FX_KIND_BURST / FX_KIND_MUZZLE.

.const FX_KIND_BURST            = $00           // Explosion burst (air / ground / puff).
.const FX_KIND_MUZZLE           = $01           // Tank-gun muzzle flash.

// FX lifetimes. One timer, one lifetime per KIND: every burst (air
// explosion, ground puff, crash / tank fire) shares FX_LIFE_FRAMES; the
// muzzle flash is a quicker blink of its own.

.const FX_LIFE_FRAMES           = msToFrames( 100 )  // Bursts: ~100 ms at 50 Hz PAL (5 frames).
.const MUZZLE_FLASH_LIFE_FRAMES = msToFrames( 50 )   // Muzzle flash: ~50 ms (2 frames = 40 ms).

// Ground-puff spawn line. A puff spawned AT this y is drawn (and erased) as the
// TOP HALF of the bitmap only. fx_setup derives the height from fx_y, so plot
// and erase always agree. 168 = the first static-glyph row (row 21 * 8); the
// 7-row half bitmap then spans pixels 161-167, entirely inside canvas row 20,
// so it can never erode the static ground line.

.const FX_GROUND_PUFF_Y         = 168 - FX_HEIGHT_HALF  // = 161.

//==============================================================================
// Subroutines — FX Engine
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: fx_spawn / fx_spawn_muzzle
//
// Description:
//
//   Begins an FX at (x, y) if none is active. Pool of 1, "drop if busy": if
//   an FX is already active, the new spawn is dropped and the existing one
//   finishes its display. fx_spawn draws the explosion burst;
//   fx_spawn_muzzle the tank-gun muzzle flash (same engine; the kind rides
//   in the CARRY flag so X stays untouched. proj_update_render's
//   ground-puff expiry NEEDS X = the projectile slot to survive this call).
//   The kind is latched only AFTER the busy check. a dropped spawn must
//   never repoint the active FX, or its erase pass would use the wrong
//   bitmap / height and leave residue.
//
// Parameters:
//
//   A - FX x position (pixel).
//   Y - FX y position (pixel).
//
// Preserves: X (plot_bitmap preserves it too).
//
// Clobbers: A, Y (via fx_setup / plot_bitmap).
//
//------------------------------------------------------------------------------

fx_spawn_muzzle:

    sec                                         // C = the kind: 1 = muzzle flash.
    .byte $24                                   // BIT zp: swallow the next 1-byte
                                                //   instruction (clc); reads ZP $18,
                                                //   harmless. BIT never touches C.
fx_spawn:

    clc                                         // C = the kind: 0 = burst.
    pha                                         // Save x while we peek at the timer
                                                //   (pha / lda / bne all leave C alone).
    lda fx_timer
    bne !busy+                                  // Already active → drop the new spawn.
    rol                                         // A is already 0 here (fx_timer == 0 fell through
                                                //   the bne), so rol A = C = the kind
                                                //   (FX_KIND_BURST = 0 / FX_KIND_MUZZLE = 1).
    sta fx_kind                                 // Claimed: latch the kind.
    pla
    sta fx_x
    sty fx_y
    lda #FX_LIFE_FRAMES                         // Lifetime by kind: bursts get the
    ldy fx_kind                                 //   full ~100 ms display, the muzzle
    beq !burst_life+                            //   flash a quicker ~50 ms blink.
    lda #MUZZLE_FLASH_LIFE_FRAMES

!burst_life:

    sta fx_timer
    jsr fx_setup
    jmp plot_bitmap                             // Tail call: paint the frame.

!busy:

    pla
    rts

// The carry-rides-the-kind trick above requires these exact values.

.errorif (FX_KIND_BURST != 0 || FX_KIND_MUZZLE != 1), "fx_spawn encodes the kind in carry: FX_KIND_BURST must be 0 and FX_KIND_MUZZLE 1"

// fx_update (the per-frame timer tick + expiry erase) lives in the UPPER
// block. tank-vs-uap.asm places it after the projectile_resume point, where
// this file's constants are already parsed. Moved off this full charset tail
// to fund the per-kind lifetime select above.

//------------------------------------------------------------------------------
//
// Subroutine: fx_setup
//
// Description:
//
//   Loads the blitter variables for the FX frame: ZP_BITMAP_PTR + bv_height
//   by fx_kind (burst vs muzzle flash), bv_x / bv_y from fx_x / fx_y. A
//   burst's height comes from its spawn line. FX_HEIGHT_HALF (the top half
//   of the bitmap) when fx_y is at FX_GROUND_PUFF_Y, FX_HEIGHT otherwise; a
//   muzzle flash is always MUZZLE_FLASH_HEIGHT. Everything is derived from
//   fx_kind / fx_y on BOTH the plot and the erase pass, so the erase always
//   matches what was drawn.
//
// Preserves: X (the fx engine's callers carry pool slots in it).
//
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

fx_setup:

    lda #<fx_bitmap                             // Bitmap by kind. The two
    ldy fx_kind                                 //   bitmaps share a page
    beq !burst+                                 //   (errorif below), so only
    lda #<muzzle_flash_bitmap                   //   the low byte selects.

!burst:

    sta ZP_BITMAP_PTR
    lda #>fx_bitmap
    sta ZP_BITMAP_PTR + 1
    lda fx_x
    sta bv_x
    lda fx_y
    sta bv_y

    // Burst height by spawn line: a burst at the ground-puff y gets the TOP
    // HALF of the bitmap (dome on the ground line); everything else gets the
    // full burst (an over-tall erase would walk past pixel 167 into the
    // static ground row). A muzzle flash (Y = fx_kind, still loaded)
    // overrides with its fixed 5-row height.

    cmp #FX_GROUND_PUFF_Y                       // C set iff fx_y >= the puff line.
    lda #FX_HEIGHT
    bcc !full+
    lda #FX_HEIGHT_HALF

!full:

    dey                                         // Y = fx_kind: burst (0) → negative,
    bmi !store+                                 //   muzzle (1) → zero/positive.
    lda #MUZZLE_FLASH_HEIGHT

!store:

    sta bv_height
    rts

// The low-byte-only bitmap select above requires both FX bitmaps in one page
// (they are emitted back-to-back in the upper block by tank-vs-uap.asm).

.errorif ((>fx_bitmap) != (>muzzle_flash_bitmap)), "fx_bitmap and muzzle_flash_bitmap must share a page (fx_setup selects by low byte only) -- nudge their import position"
