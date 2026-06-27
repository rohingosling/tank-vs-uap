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
//   collide.asm. Collision detection.
//
//   Runs one pass over the projectile pool, testing each in-flight projectile:
//
//     - Bullet → UAP:  destroy the UAP (erase + respawn off-screen), erase and
//                      free the bullet, and play the air-explosion.
//
//     - Bomb → tank:   erase and free the bomb, lose a life, and start the
//                      tank-burn dwell; at 0 lives the dwell ends in game-over
//                      (red border + jingle + the game-over screen / menu via
//                      prepare_gameover in overlay3).
//
//   Overlap tests are AABB (axis-separated, unsigned byte compares), and an
//   edge-touch counts as a hit. dropping the equality test saves bytes and
//   gives a 1 px generous, player-friendly box. The module reuses the
//   projectile bomb-aim scratch (bd_*): collisions and bomb firing never run
//   at the same point in the frame.
//
//*******************************************************************************

#importonce

#import "constants.asm"
#import "proj-defs.asm"

// ch_px / ch_py / ch_slot are declared in proj-defs.asm (shared with the
// overlay's check_bullet_bombs).

.const LIVES_ROW_BASE           = SCREEN_RAM + 22 * SCREEN_COLUMNS  // Row 22 lives-icon cells.
.const GAMEOVER_BORDER          = ( COLOUR_BLACK << 4 ) | ( 1 << 3 ) | COLOUR_RED  // Red border on game-over.

//------------------------------------------------------------------------------
//
// Subroutine: check_hits
//
// Description:
//
//   Runs one pass over the projectile pool. Bullets test against every flying
//   UAP; bombs test against the tank. X is the projectile slot throughout
//   (the bullet inner loop reuses X for the UAP slot, saving and restoring
//   the projectile slot in ch_slot).
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

check_hits:

    ldx #PROJ_MAX - 1

!pj:

    lda proj_kind, x
#if BOMBTANK
    bmi !bomb+                                  // Bit 7 set → bomb.
    beq !pjnext+                                // Free slot ($00): bmi already took every bomb
                                                //   ($80|owner), so the only other non-zero kind
                                                //   is $01 = bullet. The lda's Z flag survives bmi.
#else
    cmp #PROJ_BULLET
    bne !pjnext+                                // Free slot.
#endif

    //--- Bullet → UAP. ---

    lda proj_x, x
    sta ch_px
    lda proj_y, x
    sta ch_py
    stx ch_slot
    ldx uap_top                                 // Test against the active UAPs only (difficulty-scaled).

!uap:

    lda uap_state, x
    cmp #UAP_STATE_FLYING
    bne !uapnext+
    lda ch_px                                   // Bullet right edge vs UAP inset left.
    clc
    adc #BULLET_WIDTH - 1                       // -1 folds in the UAP box's 1 px left inset.
    cmp uap_x_hi, x
    bcc !uapnext+
    lda uap_x_hi, x                             // UAP inset right edge vs bullet left.
    clc
    adc #UAP_HIT_FAR_X
    cmp ch_px
    bcc !uapnext+
    lda ch_py                                   // Bullet bottom vs UAP inset top.
    clc
    adc #BULLET_HEIGHT - 1                      // -1 folds in the UAP box's 1 px top inset.
    cmp uap_y_hi, x
    bcc !uapnext+
    lda uap_y_hi, x                             // UAP inset bottom edge vs bullet top.
    clc
    adc #UAP_HIT_FAR_Y
    cmp ch_py
    bcc !uapnext+
    jsr hit_uap                                 // X = UAP, ch_slot = bullet.
    jmp !pjrestore+

!uapnext:

    dex
    bpl !uap-
    jsr check_bullet_bombs                      // No UAP hit → try bombs (overlay; kills both on overlap).

!pjrestore:

    ldx ch_slot                                 // Restore X = projectile slot.
    jmp !pjnext+

#if BOMBTANK

    //--- Bomb → tank. ---

!bomb:

    lda proj_x, x                               // Bomb right edge vs tank inset left.
    clc
    adc #BOMB_WIDTH - 1                         // -1 folds in the tank box's 1 px left inset.
    cmp tank_x_hi
    bcc !pjnext+
    lda tank_x_hi                               // Tank inset right edge vs bomb left.
    clc
    adc #TANK_HIT_FAR_X
    cmp proj_x, x
    bcc !pjnext+
    lda proj_y, x                               // Bomb bottom vs tank inset top.
    clc
    adc #BOMB_HEIGHT - 1                        // -1 folds in the tank box's 1 px top inset.
    cmp #TANK_Y
    bcc !pjnext+
    lda #TANK_Y + TANK_HIT_FAR_Y                // Tank inset bottom vs bomb top.
    cmp proj_y, x
    bcc !pjnext+
    stx ch_slot
    jsr hit_tank                                // X = bomb slot.
    ldx ch_slot
#endif

!pjnext:

    dex
    bpl !pj-
    rts

//------------------------------------------------------------------------------
//
// Subroutine: kill_proj
//
// Description:
//
//   Erases the projectile at its drawn position and frees the slot. Shared by
//   hit_uap (bullet) and hit_tank (bomb).
//
// Parameters:
//
//   X - Projectile slot.
//
// Clobbers: A, X (the canvas calls clobber X).
//
//------------------------------------------------------------------------------

kill_proj:

    jsr set_proj_ptr                            // Bitmap + height by kind (still set).
    lda proj_drawn_x, x
    sta bv_x
    lda proj_drawn_y, x
    sta bv_y
    jsr erase_bitmap                            // erase_bitmap preserves X = the slot.
    lda #PROJ_FREE
    sta proj_kind, x
    rts

//------------------------------------------------------------------------------
//
// Subroutine: hit_uap
//
// Description:
//
//   Handles a bullet → UAP hit: erase + respawn the UAP, kill the bullet, and
//   play the air-explosion.
//
// Parameters:
//
//   X - UAP slot.
//
// Inputs:
//
//   ch_slot - Bullet slot.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

hit_uap:

    lda uap_y_hi, x                             // Altitude band at the moment of the hit.
    jsr band_index                              // Y = band (preserves X). band_index is in proj-lower.asm.
    lda uap_band_points, y
    sta score_pts                               // Stash the points across the calls below.
    lda #UAP_STATE_DIVING                       // Start the death dive: the wreck keeps its position
    sta uap_state, x                            // and falls (advance_uaps → uap_dive_step). No erase
                                                // here. the render scheduler moves it down as it dives.

    // Seed the RISING dive beep (event 10): pitch accumulator :=
    // DIVE_BEEP_PITCH_INIT (one step below $40, so the first beep's off->on edge
    // bumps it to $40), last-gate := $00. X is still the UAP slot here (ch_slot
    // is not reloaded until below); uap_vx_lo/hi are free scratch during the
    // dive (see uap_dive_pitch_step).

    lda #DIVE_BEEP_PITCH_INIT
    sta uap_vx_lo, x
    lda #$00
    sta uap_vx_hi, x

    lda uap_x_hi, x                             // FX at the UAP's last position (X still = UAP slot).
    ldy uap_y_hi, x
    jsr fx_spawn                                // Pool-of-1 explosion (drops if already busy).
    ldx ch_slot
    jsr kill_proj                               // Erase + free the bullet.
    jsr sound_air_explosion
    lda score_pts                               // Award the UAP-kill points.
    jsr add_score
    rts

//------------------------------------------------------------------------------
//
// Subroutine: hit_bullet_bomb
//
// Description:
//
//   Handles a bullet → bomb intercept: erase + free both projectiles and play
//   the air-explosion. (check_bullet_bombs, which scans the pool for an
//   overlapping bomb, lives in the overlay.)
//
// Parameters:
//
//   X - Bomb slot.
//
// Inputs:
//
//   ch_slot - Bullet slot.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

hit_bullet_bomb:

    lda proj_y, x                               // Bomb altitude band (X = bomb).
    jsr band_index
    lda bomb_band_points, y
    sta score_pts
    jsr kill_proj                               // Erase + free the bomb (X = bomb, preserved).
    lda proj_x, x                               // FX at the bomb's last position.
    ldy proj_y, x
    jsr fx_spawn
    ldx ch_slot
    jsr kill_proj                               // Erase + free the bullet.
    jsr sound_ping                              // Soprano metal ping (intercept cue).
    lda score_pts                               // Award the bomb-intercept points.
    jsr add_score
    rts

//------------------------------------------------------------------------------
//
// Subroutine: tank_lose_life
//
// Description:
//
//   The tank takes a hit: impact FX, lose a life, blank the right-most lives
//   icon, then ALWAYS begin the destroyed / burning dwell (F2). The dwell's
//   expiry (tank_exit_dwell) decides revive vs game-over by the remaining
//   lives, so the tank burns even on the final life. Guarded so a re-hit
//   while already destroyed (an in-flight bomb, or a diving wreck) is
//   ignored. not a second life lost. Shared by hit_tank (bomb → tank) and
//   the death-dive wreck → tank crash (uap-dive.asm). (No sound_bomb_tank:
//   tank_enter_dwell immediately starts the burn noise on the same voice.)
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

tank_lose_life:

    // A diving wreck may have just crashed in with its beep still sounding;
    // silence the UAP dive beep (Soprano). Unconditional. BEFORE the re-hit
    // guard. so an ignored re-hit still clears a stuck beep. (Harmless on a
    // bomb-hit, where Soprano is idle.)

    lda #$00
    sta VIC_SOUND_BASE + VOICE_SOPRANO

    lda tank_dwell                              // Already destroyed/burning → ignore this hit.
    bne !ignore+
    lda tank_x_hi                               // Impact FX at the tank's position (tank_y fixed at TANK_Y).
    ldy #TANK_Y
    jsr fx_spawn
    dec lives
    ldx lives                                   // Blank the lives icon at col = remaining lives.
    lda #BLANK_CELL
    sta LIVES_ROW_BASE, x
    jmp tank_enter_dwell                        // Burn for 2 s; expiry → revive (lives > 0) or game over.

!ignore:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: tank_game_over
//
// Description:
//
//   Reached from tank_exit_dwell when the burn ends with no lives left: red
//   border + game-over jingle, then jmp into overlay3's prepare_gameover,
//   which lets the jingle finish, saves the live high score (before the
//   restart's ZP wipe clobbers HIGH_DIG), and shows the ZERO-DISK game-over
//   screen from the page-1 resident overlay (page1_gameover, resident.asm).
//   no KERNAL LOAD anywhere on this path. Never returns: the chain ends
//   in enter_play. (tank_exit_dwell already restored the burn audio, so the
//   jingle plays at normal volume.)
//
// Clobbers: Not applicable. never returns.
//
//------------------------------------------------------------------------------

tank_game_over:

    lda #GAMEOVER_BORDER
    sta VIC_SCREEN_BORDER_COLOUR
    jsr sound_game_over
    jmp prepare_gameover

//------------------------------------------------------------------------------
//
// Subroutine: hit_tank
//
// Description:
//
//   Handles a bomb → tank hit: kill the bomb, then lose a life and start the
//   tank-burn dwell (tail-call to tank_lose_life); on the last life the
//   dwell ends in game-over (red border + jingle + the game-over screen /
//   menu).
//
// Parameters:
//
//   X - Bomb slot.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

#if BOMBTANK

hit_tank:

    jsr kill_proj                               // Erase + free the bomb...
    jmp tank_lose_life                          // ...then the tank takes the hit (tail-call).

#endif
