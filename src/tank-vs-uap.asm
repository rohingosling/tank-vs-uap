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
//   Main module of Tank vs UAP 2 for the Commodore VIC-20 (Kick Assembler
//   v5.x): the BASIC autostart stub, cold-start, the HUD, the player tank,
//   the UAP swarm, the budgeted render scheduler, and the raster-synced game
//   loop. The tank drives under keyboard control (8.8 motion, edge clamp,
//   engine blip on a movement-key press); UAPs fly with billiard-bounce
//   motion; the scheduler frame-spreads redraws under a per-frame budget.
//   Projectiles,
//   collisions, FX, and screens arrive later.
//
//   Loop-cost / 50 Hz was measured during development (the shipping game now
//   nearly fills the upper block, so the measurement does not ride along in a
//   DEMO build).
//
//   Target: stock unexpanded VIC-20 (~3.5 KB), disk only, PAL primary /
//   NTSC secondary.
//
// BUILD:
//
//   Assemble with Kick Assembler, then pack the main program, code overlays,
//   and banner files into the bootable tank-vs-uap.d64 disk image with c1541.
//
// RUN IN VICE:
//
//   Run the .d64 in the VICE VIC-20 emulator (xvic):
//   xvic -memory none -autostart dist\tank-vs-uap.d64
//
//*******************************************************************************

// Bomb → tank collision + lives + game-over (collide.asm). Enabled
// now that the disk overlay ($033C) freed charset-tail room. Defined before
// any module is imported so all #if BOMBTANK guards see it.

#define BOMBTANK

#import "constants.asm"

//==============================================================================
// Constants
//==============================================================================

//------------------------------------------------------------------------------
// Zero page ($02-$0E scalars; input_flags at $08 from input.asm).
//------------------------------------------------------------------------------

.const tank_x_lo                = $02           // Tank x, 8.8 fixed-point:
                                                // lo = fraction.
.const tank_x_hi                = $03           // hi = integer pixel.
.const tank_drawn_x             = $04           // Last rendered integer x.
.const tank_facing              = $05           // 0 = right, 1 = left.
.const tank_drawn_facing        = $06           // Last rendered facing.
.const move_keys_prev           = $07           // Movement-key bits (Z / C)
                                                // last frame. the engine-blip
                                                // press edge.

// $08: input_flags (input.asm).

.const sched_cursor             = $09           // Persistent round-robin
                                                // cursor.
.const sched_budget_start       = $0a           // IRQ tick at scheduler entry.
.const sched_vec                = $0b           // Render-dispatch indirect
                                                // vector (+$0C).
.const sched_remaining          = $0d           // Entities left to consider
                                                // this frame.
.const reload_timer             = $0e           // Frames until the tank can
                                                // fire again.

// $0F-$3E: UAP SoA arrays (uap.asm), ending at UAP_ZP_END.
// $3F-$89: unified projectile pool + bomb scratch (proj.asm; PROJ_ZP_BASE =
// $3F = BULLET_ZP_END equivalent). Asserted against UAP_ZP_END after proj.asm
// is imported.

.const lives                    = $8a           // Remaining player lives
                                                // (collide.asm
                                                // decrements it).
.const LIVES_START              = 3

// $8B score_pts, $8C-$91 SCORE_DIG, $92-$97 HIGH_DIG (all in constants.asm).
// The cold-start zero range below is extended to $98 so both score counters
// (and the high score) start at 000000.

// F2: frames left in the tank-destroyed dwell (0 = controllable). Inside the
// init_zp_state zeroed range, so it cold-starts to 0.

.const tank_dwell               = $9b

// Bomb animation: the low byte of the current bomb frame (<bomb_bitmap_1 or
// <bomb_bitmap_2), refreshed each frame in game_loop and read by
// proj_update_render's plot. Set before any bomb is drawn each frame → no
// cold-start.

.const bomb_frame_lo            = $a3

.const ZP_GAME_FIRST            = $02
.const ZP_GAME_LAST_PLUS_ONE    = $9c           // Covers SCORE_DIG / HIGH_DIG
                                                // + FX ($98-$9A) +
                                                // tank_dwell ($9B).

// KERNAL message-mode flag. 0 = suppress the SEARCHING / LOADING text. the
// boot menu LOADs banners straight onto the custom charset, where that text
// would garble the screen. Cleared in init_video (run before every screen).
// (high_save no longer aliases $9D. it moved to upper-block RAM.)

.const MSGFLG                   = $9d

//------------------------------------------------------------------------------
// Tank tuning.
//------------------------------------------------------------------------------

.const TANK_Y                   = CANVAS_ROW_BOTTOM * 8 - TANK_HEIGHT + 8
                                                // Top edge on row 19 = 152.
.const TANK_X_MIN               = 0
.const TANK_X_MAX               = SCREEN_COLUMNS * 8 - TANK_WIDTH
                                                // 176 - 16 = 160.
.const TANK_X_START             = ( TANK_X_MAX - TANK_X_MIN ) / 2  // 80.
.const TANK_DELTA               = pxPerSecToDelta( 44 )
                                                // 44 px/s → 225 ($00E1) =
                                                // 0.88 px/frame PAL.
.const TANK_FACING_RIGHT        = 0
.const TANK_FACING_LEFT         = 1

// Bullet + bomb tuning now lives in proj.asm (the unified projectile pool).

.const ENTITY_COUNT             = 1 + UAP_COUNT  // Tank + UAPs.

// Render budget per frame, in IRQ ticks (of SLOTS_PER_FRAME = 7). The
// scheduler charges after each entity, so worst-case render = BUDGET + one
// entity (~3 ticks); 3 keeps the whole loop (motion + render) under one
// frame so the 50 Hz loop holds while per-entity refresh degrades.

.const RENDER_BUDGET_TICKS      = 3
.const RASTER_SYNC_LINE         = $73           // Lower border, both regions
                                                // (PAL and NTSC).

// Tank destruction (F2): when a bomb (or wreck) hits the tank but lives
// remain, the tank sits destroyed and uncontrollable for
// DESTROY_DWELL_FRAMES, the engine hum off and a low white-noise burn
// playing, before the player regains control. (Last life → game-over, no
// dwell.)

.const DESTROY_DWELL_FRAMES     = msToFrames( 2000 )  // 2000 ms destroyed
                                                      // dwell (100 PAL).
.const TANK_BURN_NOISE          = $80           // Noise voice on, colour 0 =
                                                // lowest frequency (deepest
                                                // burn).
.const TANK_BURN_VOLUME         = $05           // Global volume during the
                                                // burn (one global VIC
                                                // volume nibble).

// Tank destruction fire (F4): the burn sprite is dropped along a line through
// the tank body, lowered from the sprite-rect top (TANK_Y) so it sits on the
// body, not floating above on the protruding gun. Kept above row 21 (static
// ground): fx is 13 px tall, so the top y stays ≤ 155.

.const TANK_FIRE_CENTRE_Y       = TANK_Y + 2    // 154: burn-sprite top y over
                                                // the tank body.
.const TANK_FIRE_XMASK          = $03           // Random x jitter (0-3 px)
                                                // across the 16-px tank.

//==============================================================================
// BASIC Autostart Stub — "10 SYS 4110"
//==============================================================================

.pc = BASIC_STUB_BASE "BASIC stub"

    .word basic_program_end
    .word 10
    .byte $9e
    .text "4110"
    .byte $00

basic_program_end:

    .word $0000
    .byte $00

//==============================================================================
// Trampoline + Lower-Block Modules
//==============================================================================

.pc = MAIN_ENTRY "entry"
.assert "entry must be $100E (SYS 4110)", *, MAIN_ENTRY

    jmp main

#import "canvas.asm"
#import "input.asm"
#import "sprites/tank.asm"
#import "sprites/bullet.asm"
#import "random.asm"                            // Small, self-contained →
                                                // kept in the lower block.

//------------------------------------------------------------------------------
// Per-cell row-0 HUD char + colour tables (one byte per column, cols 0-21).
//
// draw_hud writes rows 0 and 21 from these in a single loop (chars + colours
// together), far smaller than unrolled pokes. Placed HERE in the lower-block
// tail gap because the upper block (which holds draw_hud) is nearly full.
// Both the score (cols 5-10) and high score (cols 16-21) are zero-padded to
// six digits ($01 = "0"); their cells are pre-coloured cyan so the
// score-update routine only rewrites digit values.
//
// Layout: "SSSS:000000 HHH:000000". exactly 22 columns (SCORE = $0E-$11,
// HIGH = $12-$14, colon = $0D).
//------------------------------------------------------------------------------

hud_row_0_chars:

    .byte $0e, $0f, $10, $11                    // 0-3   "SCORE"
    .byte $0d                                   // 4     ":"
    .byte $01, $01, $01, $01, $01, $01          // 5-10  score "000000"
    .byte $00                                   // 11    gap
    .byte $12, $13, $14                         // 12-14 "HIGH"
    .byte $0d                                   // 15    ":"
    .byte $01, $01, $01, $01, $01, $01          // 16-21 high  "000000"

hud_row_0_colours:

    .byte SCORE_LABEL_COLOUR, SCORE_LABEL_COLOUR, SCORE_LABEL_COLOUR, SCORE_LABEL_COLOUR  // 0-3   "SCORE"
    .byte LABEL_COLON_COLOUR                                                              // 4     ":"
    .byte SCORE_DIGIT_COLOUR, SCORE_DIGIT_COLOUR, SCORE_DIGIT_COLOUR                      // 5-10  score digits
    .byte SCORE_DIGIT_COLOUR, SCORE_DIGIT_COLOUR, SCORE_DIGIT_COLOUR
    .byte CANVAS_COLOUR                                                                   // 11    gap
    .byte HIGH_LABEL_COLOUR, HIGH_LABEL_COLOUR, HIGH_LABEL_COLOUR                         // 12-14 "HIGH"
    .byte LABEL_COLON_COLOUR                                                              // 15    ":"
    .byte HIGH_DIGIT_COLOUR, HIGH_DIGIT_COLOUR, HIGH_DIGIT_COLOUR                         // 16-21 high digits
    .byte HIGH_DIGIT_COLOUR, HIGH_DIGIT_COLOUR, HIGH_DIGIT_COLOUR

//------------------------------------------------------------------------------
//
// Subroutine: init_lives
//
// Description:
//
//   Paints the three lives icons on the status row (row 22, cols 0-2): char
//   $0C, cyan. The rest of row 22 stays blank ($00 from init_video) and
//   white. a blank cell shows nothing, so no black-painting is needed now
//   that the score digits live in zero page (not in hidden row-22 cells).
//   Lower-block resident; called once from main after draw_hud.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

init_lives:

    ldx #$02

!loop:

    lda #$0c
    sta SCREEN_RAM + 22 * SCREEN_COLUMNS, x
    lda #LIVES_ICON_COLOUR
    sta COLOUR_RAM + 22 * SCREEN_COLUMNS, x
    dex
    bpl !loop-
    rts

//------------------------------------------------------------------------------
//
// Subroutine: update_high
//
// Description:
//
//   If the current score (SCORE_DIG) now exceeds the high score (HIGH_DIG),
//   copies it over and refreshes the row-0 high-score display (HIGH_DISP,
//   digit + 1 = screen code). Called by add_score (in the $0200 overlay)
//   after every score change. a cross-region jsr. The score only ever
//   rises, so once it overtakes the high score the two stay locked together.
//   6-digit MSB-first compare.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

update_high:

    ldx #$00

!cmp:

    lda SCORE_DIG, x
    cmp HIGH_DIG, x
    bcc !done+                                  // Current digit < high digit
                                                // → current < high: stop.
    bne !copy+                                  // Current digit > high digit
                                                // → current > high: track it.
    inx
    cpx #$06
    bne !cmp-

!done:

    rts                                         // All six digits equal →
                                                // not greater.

!copy:

    ldx #$05

!u:

    lda SCORE_DIG, x
    sta HIGH_DIG, x
    clc
    adc #$01                                    // digit + 1 = screen code.
    sta HIGH_DISP, x
    dex
    bpl !u-
    rts

// Unified projectile pool: the bomb-roll pass (lower-block part; the rest is
// in the charset tail + upper block). Placed here to use the lower-block
// tail gap.

#import "proj-fire.asm"

// UAP death-dive + ground-crash-burn dwell. Moved here from the $1800-page
// ceiling gap (which was too tight once the crash dwell grew uap_dive_step)
// into the lower-block headroom freed by the blit_driver compaction.
// Placement-agnostic; calls uap_reset_offscreen / tank_lose_life
// cross-region.

#import "uap-dive.asm"

.print "LOWER END = " + toHexString(*) + " (limit $1400, free " + ($1400 - *) + ")"
.errorif (* > CHARSET_BASE), "lower block (HUD tables + proj-fire + uap-dive) overran into $1400"

.pc = CHARSET_BASE "charset"

#import "charset.asm"

//==============================================================================
// Upper Block — Sound + Random + the Game
//==============================================================================

.pc = UPPER_CODE_BASE "game"

#import "sound.asm"
#import "uap.asm"
#import "uap-tail.asm"                          // set_uap_bitmap_ptr (moved
                                                // up from the charset tail;
                                                // the tail is now full).
#import "proj-lower.asm"                        // band_index (moved up from
                                                // the charset tail).

// sprites/bomb.asm (the two bomb bitmaps) is placed in the $18BE gap below.
// the upper block is full, and the second bomb frame would overflow it.

#import "sprites/fx.asm"                        // Shared FX bitmaps: burst
                                                // (26 B) + muzzle flash
                                                // (10 B); kept in the upper
                                                // block to free the tail (the
                                                // FX engine in the tail
                                                // reaches them via
                                                // ZP_BITMAP_PTR).

// (The projectile ZP pool abuts the UAP SoA; that is asserted where proj.asm
// is imported, below.)

//------------------------------------------------------------------------------
//
// Subroutine: main
//
// Description:
//
//   Cold-start entry (SYS 4110, via the $100E trampoline): hook the IRQ
//   vector, load the disk overlays, cold-start zero page, set up video,
//   canvas, HUD, lives, RNG, input, and sound, then hand off to the
//   title / menu sequence. Does not return (ends with jmp start_menu).
//
//------------------------------------------------------------------------------

main:

    sei

    // Point CINV at sound_isr BEFORE the overlay load (the long-hunted $028D
    // fix). The KERNAL LOAD re-enables IRQ for the slow serial transfer, and
    // the DEFAULT IRQ handler scans the keyboard, writing SHFLAG / LSTSHF
    // ($028D / $028E). which overlap the overlay3 code region, so the scan
    // corrupts the restart `jsr scan_keys` operand mid-load. sound_isr just
    // acks the VIA2 T1 jiffy and (no voices active yet) is silent, and NEVER
    // scans the keyboard, so the overlays load uncorrupted. The timer is
    // still the KERNAL's 60 Hz jiffy here (sound_init retunes it later), so
    // the serial-load timing is undisturbed. (This vector-set used to live
    // inside sound_init; it was hoisted here, so sound_init no longer sets
    // CINV.)

    lda #<sound_isr
    sta CINV
    lda #>sound_isr
    sta CINV + 1

    // Pull the disk overlays off the .d64: the KERNAL LOAD uses zero page
    // $90-$97 (the score / high-score digits), so it must run BEFORE
    // init_zp_state clears them. (Still before init_video, which wipes the
    // KERNAL load text.)

    jsr load_overlay

    jsr init_zp_state                           // Zero $02-$97 (including
                                                // SCORE_DIG / HIGH_DIG)
                                                // AFTER the load.
    jsr init_video
    jsr canvas_init
    jsr draw_hud
    jsr init_lives                              // Status-row lives icons
                                                // (row 22, cols 0-2).
    jsr random_init
    jsr input_init
    jsr sound_init                              // Ends with CLI: interrupts
                                                // on. (CINV already set
                                                // above.)

    // Boot done → show the title / menu sequence (in the "S" screens overlay
    // loaded above; start_menu also loads the page-1 "R" resident overlay).
    // The per-game entity init (tank_init / uap_init / proj_init) is NOT
    // done here at boot: enter_play does it after the menu, once
    // enter_play_boot has loaded the "O" projectile overlay into $033C.

    jmp start_menu                              // In the OverlayScreens
                                                // segment ($033C).

//------------------------------------------------------------------------------
//
// Subroutine: game_start_jingle
//
// Description:
//
//   Plays the rising game-start jingle (seq_game_start, Tenor) over the
//   freshly drawn, FROZEN playfield, then falls through into game_loop.
//   Jumped to by enter_play (overlay3) instead of game_loop: enter_play has
//   already drawn the field, reloaded the "O" overlay, and done its cli, so
//   the sound ISR is ticking and a busy-wait on the Tenor voice_active flag
//   (cleared by the sequence's 0-tick terminator) holds animation AND input
//   until the jingle ends. Direct `jmp game_loop` paths (the loop bottom)
//   skip the jingle. Does not return. falls through into game_loop.
//
//------------------------------------------------------------------------------

game_start_jingle:

    ldx #VOICE_TENOR
    lda #seq_game_start - master_seq
    jsr sound_play

!wait:

    lda voice_active + VOICE_TENOR              // Nonzero while the jingle
                                                // sequences; the ISR clears
                                                // it.
    bne !wait-

    // Fall through into game_loop.

//------------------------------------------------------------------------------
//
// Subroutine: game_loop
//
// Description:
//
//   The raster-synced main loop: sync to the lower border, pick the bomb
//   animation frame, then run one frame of input, motion, projectiles,
//   collisions, FX, and the budgeted render scheduler. Loops forever
//   (jmp game_loop at the bottom).
//
//------------------------------------------------------------------------------

game_loop:

    jsr raster_sync

    // Bomb-fall animation: choose frame 1 or 2 from bit 6 of the
    // free-running 350 Hz IRQ tick. a 64-tick (~183 ms) flip with NO timer
    // of its own (the power-of-2 trick: the toggle IS a bit of an existing
    // counter). proj_update_render plots this frame; it always ERASES with
    // frame 1 (a superset of frame 2), so the erase stays clean no matter
    // which frame was last drawn.

    ldy #<bomb_bitmap_1
    bit sound_tick_lo                           // V = bit 6 of the tick.
    bvc !bombframe+
    ldy #<bomb_bitmap_2

!bombframe:

    sty bomb_frame_lo

    jsr scan_keys
    jsr update_tank
    jsr fire_bullets
    jsr advance_uaps
    jsr try_fire_bombs
    jsr proj_update_render
    jsr check_hits
    jsr fx_update
    jsr render_scheduler
    jmp game_loop

//------------------------------------------------------------------------------
//
// Subroutine: init_zp_state
//
// Description:
//
//   Cold-starts the free zero-page game range ($02 up to
//   ZP_GAME_LAST_PLUS_ONE). RAM is not zeroed at load.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

init_zp_state:

    lda #$00
    ldx #ZP_GAME_FIRST

!loop:

    sta $00, x
    inx
    cpx #ZP_GAME_LAST_PLUS_ONE
    bne !loop-
    rts

//------------------------------------------------------------------------------
//
// Subroutine: init_video
//
// Description:
//
//   Sets the custom charset (loaded at $1400), the screen / border colour,
//   and a cleared screen. Does NOT blank the charset (the real glyphs are
//   loaded) and does NOT touch colour RAM (canvas_init sets it). Falls
//   through into clear_screen.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

init_video:

    lda #VIC_MEMORY_POINTERS_VALUE
    sta VIC_MEMORY_POINTERS
    lda #SCREEN_BORDER_COLOUR_VALUE
    sta VIC_SCREEN_BORDER_COLOUR

    // Suppress the KERNAL load messages: the menu streams banners onto the
    // custom charset, where that text would garble it.

    lda #$00
    sta MSGFLG

    // Fall through to clear_screen: blank every screen cell (border +
    // colour left as set above).

//------------------------------------------------------------------------------
//
// Subroutine: clear_screen
//
// Description:
//
//   Blanks every screen cell (BLANK_CELL into both screen-RAM pages); the
//   border and colour RAM are left as they are. Entered by fall-through from
//   init_video, and called directly by the menu screens (keeps the border).
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

clear_screen:

    lda #BLANK_CELL
    ldx #$00

!clear:

    sta SCREEN_RAM + $000, x
    sta SCREEN_RAM + $100, x
    inx
    bne !clear-
    rts

//------------------------------------------------------------------------------
//
// Subroutine: draw_hud
//
// Description:
//
//   Writes the static HUD chars + colours in one table-driven pass: row 0
//   (score / high labels + zero-padded digit fields) and row 21 (the ground
//   tile). Rows 1-20 keep CANVAS_COLOUR from canvas_init's blanket fill;
//   the row-22 lives icons are set by init_lives. Tables: hud_row_0_chars +
//   hud_row_0_colours (lower-block tail gap). Ports v1's init_colour_ram +
//   HUD glyph layout.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

draw_hud:

    ldx #SCREEN_COLUMNS - 1

!loop:

    lda hud_row_0_chars, x                      // Row 0: SCORE / HIGH labels
    sta SCREEN_RAM + 0 * SCREEN_COLUMNS, x      // + digits.
    lda hud_row_0_colours, x
    sta COLOUR_RAM + 0 * SCREEN_COLUMNS, x
    lda #$0b                                    // Row 21: ground tile (all
    sta SCREEN_RAM + 21 * SCREEN_COLUMNS, x     // green).
    lda #GROUND_TILE_COLOUR
    sta COLOUR_RAM + 21 * SCREEN_COLUMNS, x
    dex
    bpl !loop-
    rts

//------------------------------------------------------------------------------
//
// Subroutine: tank_init
//
// Description:
//
//   Centres the tank, faces it right, and plots it once.
//
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

tank_init:

    ldy #TANK_X_START                           // Y = start x: seeds tank_x_hi /
    sty tank_x_hi                               //   tank_drawn_x (both zero page) AND
    sty tank_drawn_x                            //   carries through to tank_blit_setup's bv_x.
    lda #$00
    sta tank_x_lo
    sta tank_facing
    sta tank_drawn_facing
    sta move_keys_prev                          // No keys held (enter_play's
                                                //   release gate) → no blip on
                                                //   the first frame.

    // A = 0 = TANK_FACING_RIGHT (set above); Y already = TANK_X_START and
    // survives the stores + tank_blit_setup (set_tank_bitmap_ptr preserves Y).

    jsr tank_blit_setup
    jmp plot_bitmap                             // Tail call.

//------------------------------------------------------------------------------
//
// Subroutine: update_tank
//
// Description:
//
//   Applies input_flags: 8.8 motion with edge clamp, facing, and the
//   movement-key engine blip.
//
// Clobbers: A, X (plus Y via sound_engine on a new movement-key press).
//
//------------------------------------------------------------------------------

update_tank:

    //--- Left. ---

    lda input_flags
    and #INPUT_LEFT
    beq !check_right+
    lda tank_x_lo
    sec
    sbc #<TANK_DELTA
    sta tank_x_lo
    lda tank_x_hi
    sbc #>TANK_DELTA
    sta tank_x_hi
    bcs !left_face+                             // No borrow → still ≥ 0.
    lda #$00                                    // TANK_X_MIN = 0; one A = 0
    sta tank_x_hi                               // covers both stores.
    sta tank_x_lo

!left_face:

    lda #TANK_FACING_LEFT
    sta tank_facing

!check_right:

    //--- Right. ---

    lda input_flags
    and #INPUT_RIGHT
    beq !moved+
    lda tank_x_lo
    clc
    adc #<TANK_DELTA
    sta tank_x_lo
    lda tank_x_hi
    adc #>TANK_DELTA
    sta tank_x_hi

    // Clamp as soon as hi REACHES max (not max + 1), so the tank pins to
    // exactly MAX:$00. mirroring the left edge. Without this the fraction
    // oscillates at the right edge (160.0 ↔ 160.88), so tank_x_lo keeps
    // changing and the engine-stop check never fires. Drawn x is unchanged
    // (= MAX = 160).

    cmp #TANK_X_MAX
    bcc !right_face+
    lda #TANK_X_MAX                             // At / over MAX → clamp to
    sta tank_x_hi                               // exactly MAX:$00.
    lda #$00
    sta tank_x_lo

!right_face:

    lda #TANK_FACING_RIGHT
    sta tank_facing

!moved:

    // Engine blip on a movement-key PRESS: a fixed ENGINE_BLIP_TICKS one-shot
    // fires whenever Z or C goes down. i.e. a movement bit set THIS frame
    // that was clear LAST frame. Nothing plays on release or while a key is
    // held; the sequencer self-terminates the blip, so there is no "off"
    // edge to track. (input_flags is forced 0 during the destruction dwell
    // by scan_keys, so the previous-bits byte tracks 0 while burning, and a
    // key still held at revive blips once. the engine restarting.)

    lda input_flags
    and #INPUT_LEFT | INPUT_RIGHT
    tay                                         // Y = this frame's move bits.
    eor move_keys_prev                          // A = the bits that CHANGED ...
    sty move_keys_prev                          // ... previous := current ...
    and input_flags                             // ... changed AND current = the newly
    beq !done+                                  //   pressed keys (A has only move bits,
    jsr sound_engine                            //   so the fire bit cannot leak in).

!done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: render_scheduler
//
// Description:
//
//   Budgeted round-robin redraw from a persistent cursor. The structure
//   scales from one entity (the tank) to many.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

render_scheduler:

    lda sound_tick_lo
    sta sched_budget_start
    lda #ENTITY_COUNT
    sta sched_remaining

!loop:

    ldy sched_cursor
    jsr render_entity                           // Dispatches; clobbers
                                                // A, X, Y.

    ldy sched_cursor
    iny
    cpy #ENTITY_COUNT
    bcc !wrapped+
    ldy #$00

!wrapped:

    sty sched_cursor

    lda sound_tick_lo
    sec
    sbc sched_budget_start
    cmp #RENDER_BUDGET_TICKS
    bcs !done+
    dec sched_remaining
    bne !loop-

!done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: render_entity
//
// Description:
//
//   Flat-index dispatch: entity 0 = the tank (falls through into
//   tank_render), 1..UAP_COUNT = UAP slot (index - 1).
//
// Parameters:
//
//   Y - Entity index (0 to ENTITY_COUNT - 1).
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

render_entity:

    tya
    tax
    dex                                         // X = index - 1 = UAP slot;
    bmi !tank+                                  //   negative → entity 0, fall
    jmp uap_render                              //   through into tank_render.

!tank:

    // Fall through to tank_render.

//------------------------------------------------------------------------------
//
// Subroutine: tank_render
//
// Description:
//
//   Redraws the tank only if its drawn position or facing changed (erases
//   the previous bitmap at the previous position, plots the current).
//
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

tank_render:

    lda tank_x_hi
    cmp tank_drawn_x
    bne !redraw+
    lda tank_facing
    cmp tank_drawn_facing
    bne !redraw+
    rts

!redraw:

    // Erase the previously-drawn tank, then plot at the new position /
    // facing (the shared blit setup loads ZP_BITMAP_PTR + bv_x/y/height).

    ldy tank_drawn_x
    lda tank_drawn_facing
    jsr tank_blit_setup
    jsr erase_bitmap

    ldy tank_x_hi
    lda tank_facing
    jsr tank_blit_setup
    jsr plot_bitmap

    lda tank_x_hi
    sta tank_drawn_x
    lda tank_facing
    sta tank_drawn_facing
    rts

//------------------------------------------------------------------------------
//
// Subroutine: tank_blit_setup
//
// Description:
//
//   Shared blitter setup for the tank: ZP_BITMAP_PTR by facing, bv_x from Y,
//   and the fixed tank bv_y / bv_height. Factored out of tank_init and
//   tank_render's erase + plot passes.
//
// Parameters:
//
//   A - Facing (TANK_FACING_RIGHT or TANK_FACING_LEFT).
//   Y - Tank x position for bv_x.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

tank_blit_setup:

    jsr set_tank_bitmap_ptr
    sty bv_x
    lda #TANK_Y
    sta bv_y
    lda #TANK_HEIGHT
    sta bv_height
    rts

//------------------------------------------------------------------------------
//
// Subroutine: set_tank_bitmap_ptr
//
// Description:
//
//   Points ZP_BITMAP_PTR at the right- or left-facing tank bitmap.
//
// Parameters:
//
//   A - Facing (TANK_FACING_RIGHT or TANK_FACING_LEFT).
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

set_tank_bitmap_ptr:

    // tank_bitmap_right and tank_bitmap_left are emitted consecutively and
    // share the SAME page, so their high byte is identical. hoist the high
    // store out of both arms and select only the low byte by facing. (X is
    // clobbered; the sole caller chain, tank_blit_setup ← tank_init /
    // tank_render, never reads X across this call. Y is preserved, which
    // tank_init now relies on.)

    .errorif ( floor( tank_bitmap_right / 256 ) != floor( tank_bitmap_left / 256 ) ), "set_tank_bitmap_ptr assumes the two tank bitmaps share one page"

    ldx #<tank_bitmap_right                     // Default = right-facing low byte.
    cmp #TANK_FACING_LEFT
    bne !store+                                 // Not LEFT → keep the right low byte.
    ldx #<tank_bitmap_left                      // LEFT → left low byte.

!store:

    stx ZP_BITMAP_PTR
    lda #>tank_bitmap_right                     // == >tank_bitmap_left (same page).
    sta ZP_BITMAP_PTR + 1
    rts

//------------------------------------------------------------------------------
//
// Subroutine: load_overlay
//
// Description:
//
//   KERNAL-LOADs the boot disk overlays to their own addresses: "S"
//   (screens / menu) → $033C and "P" (score + overlay3) → $0200. The "O"
//   (projectile) overlay → $033C is loaded later by enter_play_boot
//   (overlay3), time-sharing $033C with the screens overlay; the "R"
//   (page-1 resident) overlay → $0100 is loaded by start_menu (its name
//   byte lives in the S overlay. this block is full). Secondary address 1 uses each file's
//   load header. Single-character disk names keep this routine small. Called
//   once at boot, before init_video clears the screen (so any KERNAL
//   "SEARCHING / LOADING" text is wiped). The disk is always present
//   (disk-only), so a load error is not handled. (c1541 stores the
//   lower-case bat names as upper-case PETSCII, which is what these bytes
//   match: $4F = "O", $50 = "P".) Moved here from the charset tail to fund
//   the pool's growth to 47 slots + the muzzle-flash FX.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

load_overlay:

    ldx #<ovls_name
    ldy #>ovls_name
    lda #$01
    jsr load_file
    ldx #<ovl2_name
    ldy #>ovl2_name
    lda #$01

    // Fall through to load_file.

//------------------------------------------------------------------------------
//
// Subroutine: load_file
//
// Description:
//
//   KERNAL-loads one file from disk: logical file 1, device 8, secondary
//   address 1 (load to the file's own address), load (not verify).
//   Tail-calls KERNAL_LOAD (its rts returns to the caller). Entered by
//   fall-through from load_overlay.
//
// Parameters:
//
//   A - Name length.
//   X - Name pointer, low byte.
//   Y - Name pointer, high byte.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

load_file:

    jsr KERNAL_SETNAM
    lda #$01                                    // Logical file number.
    ldx #$08                                    // Device 8 (disk).
    ldy #$01                                    // SA = 1: load to the file's
                                                // own address.
    jsr KERNAL_SETLFS
    lda #$00                                    // 0 = load (not verify).
    jmp KERNAL_LOAD                             // Tail-call (rts back to the
                                                // caller).

//------------------------------------------------------------------------------
// Overlay disk-file names (single PETSCII characters).
//------------------------------------------------------------------------------

ovl_name:
    .byte $4f                                   // "O" (PETSCII) → the $033C
                                                // projectile overlay.
ovl2_name:
    .byte $50                                   // "P" (PETSCII) → the $0200
                                                // score + overlay3.
ovls_name:
    .byte $53                                   // "S" (PETSCII) → the $033C
                                                // screens / menu overlay.

//------------------------------------------------------------------------------
// 6-byte high-score save buffer (overlay3.asm: prepare_gameover writes it,
// enter_play reads it).
//
// It lives in resident UPPER-BLOCK RAM, NOT zero page, because enter_play's
// init_zp_state wipes the zero-page game range $02-$9B (including HIGH_DIG
// at $92-$97), and the boot menu's KERNAL LOADs clobber that serial-load
// zero page too. prepare_gameover captures the live high score here at
// game-over; enter_play restores HIGH_DIG from it after the wipe. So it
// persists across games. Cold-boot value = 0 (this .fill), so the title
// screen's first game starts with HIGH = 000000.
//------------------------------------------------------------------------------

high_save:

    .fill 6, $00

//==============================================================================
// Charset-Tail Code ($16D0-$17FF)
//==============================================================================

// Projectile code in the freed charset-tail gap ($16D0-$17FF), reclaimed by
// shrinking the canvas pool to 64 slots. Placed here so the upper block
// stays under screen RAM; the upper pc is captured and restored around it.

.var projectile_resume = *
.pc = CHARSET_TAIL_BASE "projectiles"

// Unified integer projectile pool (tank bullets + UAP bombs): fire_bullets,
// try_fire_bombs, proj_update_render, proj_init, and the aim / launch
// helpers. Replaces the old separate 8.8 bullet code and the standalone bomb
// module. Placed in this charset-tail region; spills into the upper block
// via proj-fire.asm if it overruns $1800.

#import "proj.asm"
#import "collide.asm"                           // collision detection
                                                // (bullet → UAP).
#import "fx.asm"                                // Shared FX engine (bitmap is
                                                // in the upper block, see
                                                // above).

.errorif (PROJ_ZP_BASE != UAP_ZP_END), "projectile ZP pool must follow the UAP SoA (UAP_ZP_END)"
.errorif (* > CHARSET_BASE + $400), "projectile tail code (proj + collide + fx engine) overran into $1800"
.print "CHARSET TAIL END = " + toHexString(*) + " (limit $1800, free " + (CHARSET_BASE + $400 - *) + ")"
.pc = projectile_resume                         // Resume the upper block.

//------------------------------------------------------------------------------
//
// Subroutine: fx_update
//
// Description:
//
//   Called once per frame from the main game loop. Counts the FX timer down;
//   on expiry, erases the bitmap and frees the slot. Part of the FX engine
//   (fx.asm). placed here in the upper block, AFTER the tail imports, so
//   fx.asm's constants are already parsed (the tail is full).
//
// Preserves: X.
//
// Clobbers: A, plus Y via fx_setup / erase_bitmap on expiry (tail call).
//
//------------------------------------------------------------------------------

fx_update:

    lda fx_timer
    beq !done+                                  // Nothing active.
    dec fx_timer
    bne !done+                                  // Still ticking.

    //--- Timer expired: erase the bitmap (timer is now 0 so the slot is free). ---

    jsr fx_setup
    jmp erase_bitmap                            // Tail call.

!done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: raster_sync
//
// Description:
//
//   Paces one video frame (waits for the lower-border raster edge).
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

raster_sync:

!hi:

    lda VIC_RASTER
    cmp #RASTER_SYNC_LINE
    beq !hi-

!lo:

    lda VIC_RASTER
    cmp #RASTER_SYNC_LINE
    bne !lo-
    rts

//==============================================================================
// Projectile Bomb Helpers (Upper-Block Tail)
//==============================================================================

// Unified projectile pool: the bomb aim + cap-count helpers (upper-block
// part; the rest is in the charset tail + lower block). Placed at the end of
// the upper block to use its free tail.

#import "proj-bomb.asm"

//------------------------------------------------------------------------------
//
// Subroutine: uap_dive_pitch_step
//
// Description:
//
//   Steps the RISING dive-beep pitch for the diving UAP in slot X (the UAP
//   dive-beep audio event). The pitch lives in uap_vx_lo[x] and the previous
//   warble-gate state in uap_vx_hi[x]. both reused as scratch while the UAP
//   DIVES (the straight-down dive never reads its velocity, and
//   uap_reset_offscreen reloads it on respawn, so the reuse is safe). On each
//   beep's off->on edge the pitch rises by DIVE_BEEP_STEP, capped at
//   DIVE_BEEP_PITCH_MAX ($78). hit_uap (collide.asm) seeds the pitch to
//   DIVE_BEEP_PITCH_INIT (= DIVE_BEEP_PITCH_START - DIVE_BEEP_STEP) and the gate
//   to $00, so the first off->on edge yields exactly DIVE_BEEP_PITCH_START ($40). The last-gate is latched UNCONDITIONALLY
//   every frame (not only on the edge) so the step fires once per beep and does
//   not stall. Called every diving frame from uap_dive_beep (overlay3), which
//   then gates + renders uap_vx_lo[x]. Placed here in the upper block (the
//   reclaimed space); overlay3 is full.
//
// Parameters:
//
//   X - Diving UAP slot. Preserved.
//
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

uap_dive_pitch_step:

    lda sound_tick_lo
    and #DIVE_BEEP_GATE_MASK                    // A = current gate: $00 (off) or $20 (on).
    tay                                         // Y = current gate (saved across the eor).
    eor uap_vx_hi, x                            // A = bits that CHANGED vs last frame.
    sty uap_vx_hi, x                            // latch current gate UNCONDITIONALLY (last := now).
    and uap_vx_hi, x                            // changed AND now-on = $20 only on an off->on edge.
    beq !done+                                  // no new beep this frame → hold the pitch.
    lda uap_vx_lo, x                            // new beep → step the pitch up.
    cmp #DIVE_BEEP_PITCH_MAX                    // carry clear iff pitch < $78.
    bcs !done+                                  // at the cap → hold.
    adc #DIVE_BEEP_STEP                         // +$8 (carry clear → exact).
    sta uap_vx_lo, x

!done:

    rts

.errorif (* > SCREEN_RAM), "upper block (game + proj-bomb) overran into screen RAM at $1E00"
.print "UPPER BLOCK END = " + toHexString(*) + " (limit $1E00, free " + (SCREEN_RAM - *) + ")"

//==============================================================================
// Ceiling-Gap Code ($1870..$18AF)
//==============================================================================

// The free RAM between the canvas scratch end (CANVAS_RAM_END) and the sound
// state (SOUND_RAM_BASE). UAP death-dive used to live here but moved to the
// lower block; this gap now holds the tank-destruction dwell entry (and
// fire glue). Loaded with the main prg; the canvas never writes past
// CANVAS_RAM_END, so it is stable at runtime.

.var ceiling_resume = *
.pc = CANVAS_RAM_END "ceiling-gap"

//------------------------------------------------------------------------------
//
// Subroutine: tank_enter_dwell
//
// Description:
//
//   Begins the tank-destroyed dwell (F2): arms the dwell timer and starts a
//   sustained low white-noise burn at TANK_BURN_VOLUME. (The engine is now a
//   short sequenced blip, not a held hum, so there is nothing to switch off
//   here. a blip in flight just self-terminates within ~183 ms.) The
//   per-frame countdown, control lockout, and audio restore are in scan_keys
//   (input.asm). Reached by tail-jmp from tank_lose_life's survive path
//   (lives > 0); returns to tank_lose_life's caller.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

tank_enter_dwell:

    lda #DESTROY_DWELL_FRAMES
    sta tank_dwell
    lda #$00
    sta voice_active + VOICE_NOISE              // Hand the noise voice to us,
                                                // not the sequencer.
    lda #TANK_BURN_NOISE
    sta VIC_SOUND_BASE + VOICE_NOISE            // $900D: sustained deep burn.
    lda #TANK_BURN_VOLUME
    sta VIC_VOLUME                              // $900E: quieter global
                                                // volume while burning.
    rts

//------------------------------------------------------------------------------
//
// Subroutine: tank_exit_dwell
//
// Description:
//
//   End of the destroyed dwell. Restores the global volume and silences the
//   burn noise (both the revive and game-over paths need this), then
//   branches on the remaining lives: no lives left → tank_game_over (the
//   tank has finished burning); otherwise revive (force a clean tank
//   re-plot). move_keys_prev is left alone: it tracked the gated (zeroed)
//   input through the burn, so a movement key still held at revive fires
//   one blip. the engine restarting. Called from scan_keys when the dwell
//   timer expires.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

tank_exit_dwell:

    lda #SOUND_VOLUME                           // Restore the volume (the
    sta VIC_VOLUME                              // burn lowered it to $05) ...
    lda #$00
    sta VIC_SOUND_BASE + VOICE_NOISE            // ... and silence the burn
                                                // noise, for both outcomes.
    lda lives
    bne !revive+
    jmp tank_game_over                          // Last life burned out →
                                                // game over (never returns).

!revive:

    lda #$ff
    sta tank_drawn_x                            // F4: force a clean tank
                                                // re-plot next frame (the
                                                // burn eroded it).
    rts                                         // tank_render erases at $FF
                                                // (clipped), then plots
                                                // clean.

//------------------------------------------------------------------------------
//
// Subroutine: tank_fire_step
//
// Description:
//
//   F4: flashes one explosion at a random x along the tank's body line (the
//   burn sprite is dropped here, lowered onto the body below the protruding
//   gun). Called each dwelling frame from scan_keys. fx is pool-of-1 +
//   auto-erasing, so this self-paces and erodes the tank as it burns.
//   Tail-calls fx_spawn (A = x, Y = y).
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

tank_fire_step:

    ldy #TANK_FIRE_CENTRE_Y                     // Y = the tank body line
                                                // (random_next preserves Y).
    jsr random_next
    and #TANK_FIRE_XMASK
    clc
    adc tank_drawn_x                            // A = tank x + random jitter.
    jmp fx_spawn

//------------------------------------------------------------------------------
//
// Subroutine: uap_burn_noise
//
// Description:
//
//   Steady white-noise hiss while a shot-down UAP burns on the ground (Noise
//   voice, colour $64 -> byte $E4). Written directly to $900D each burning
//   frame from uap_crash_dwell (uap-dive.asm); uap_crash_end (overlay3)
//   silences it. The high dive beep plays during the DESCENT instead
//   (uap_dive_beep, overlay3). Lives HERE in the $1800 ceiling gap because
//   uap-dive.asm fills the lower block. The Noise voice is shared with the
//   gun + air-explosion (most-recent-wins): while one of those sequences it
//   briefly wins, and the hiss re-asserts the next frame.
//
// Clobbers: A (X and Y are preserved).
//
//------------------------------------------------------------------------------

.const UAP_BURN_NOISE_PITCH     = $64           // Noise colour value (0-127): a mid white-noise hiss.
.const UAP_BURN_NOISE_BYTE      = $80 | UAP_BURN_NOISE_PITCH  // $E4 = enable | colour.

uap_burn_noise:

    lda #UAP_BURN_NOISE_BYTE
    sta VIC_SOUND_BASE + VOICE_NOISE
    rts

.errorif (* > SOUND_RAM_BASE), "ceiling-gap code overran into the sound state ($18B0)"
.print "CEILING GAP END = " + toHexString(*) + " (limit " + toHexString(SOUND_RAM_BASE) + ", free " + (SOUND_RAM_BASE - *) + ")"
.pc = ceiling_resume                            // Resume the upper-block pc.

//==============================================================================
// Difficulty-Gap Code
//==============================================================================

// The free RAM between the RNG state (RANDOM_RAM_BASE + 2) and the
// upper-block code (UPPER_CODE_BASE = $1900). F6's update_difficulty lives
// HERE (resident, loaded with the main prg). NOT in the overlay3 tail,
// because that overlay KERNAL-LOADs to $0200 at boot and must not reach
// $0314 (the CINV IRQ vector) / $0330 (ILOAD) used during the load itself.

.var difficulty_resume = *
.pc = RANDOM_RAM_BASE + 2 "difficulty"

//------------------------------------------------------------------------------
//
// Subroutine: update_difficulty
//
// Description:
//
//   F6: scales the active UAP count to the score. Called from add_score
//   (the $0200 overlay) after every score change. Bands: 0-1999 → 1 UAP,
//   2000-2999 → 2, 3000-3999 → 3, 4000+ → 4. Monotonic up (the score only
//   rises): when the target top index exceeds uap_top, fly the
//   newly-activated slot(s) in. The score is 6 MSB-first decimal digits
//   SCORE_DIG[0..5]; SCORE_DIG + 2 is the thousands digit.
//
// Clobbers: A, X, Y (add_score saves / restores the caller's X around this).
//
//------------------------------------------------------------------------------

update_difficulty:

    ldx #UAP_MAX - 1                            // Default target = 4 UAPs
                                                // (top index 3) for
                                                // score ≥ 10000.
    lda SCORE_DIG + 0                           // Hundred-thousands or ...
    ora SCORE_DIG + 1                           // ... ten-thousands non-zero
                                                // → score ≥ 10000 →
                                                // keep max.
    bne !grow+
    ldy SCORE_DIG + 2                           // < 10000: thousands digit
                                                // (0-9) → target top via
                                                // the table.
    ldx difficulty_top_table, y

!grow:

    cpx uap_top
    beq !done+                                  // Target already reached.
    bcc !done+                                  // Target below current
                                                // (never. monotonic) →
                                                // done.
    inc uap_top                                 // Activate the next slot ...
    txa
    pha                                         // ... save the target across
                                                // uap_spawn (clobbers
                                                // A, X, Y) ...
    ldx uap_top
    jsr uap_spawn                               // ... and fly the new UAP in
                                                // (spawns + plots).
    pla
    tax
    jmp !grow-

!done:

    rts

//------------------------------------------------------------------------------
// Thousands digit (0-9) → target top index: 0-1 → 0, 2 → 1, 3 → 2, 4-9 → 3
// (4000+ → 4 UAPs).
//------------------------------------------------------------------------------

difficulty_top_table:

    .byte 0, 0, 1, 2, 3, 3, 3, 3, 3, 3

.errorif (* > UPPER_CODE_BASE), "difficulty-gap code overran into the upper block ($1900)"
.print "DIFFICULTY GAP END = " + toHexString(*) + " (limit " + toHexString(UPPER_CODE_BASE) + ", free " + (UPPER_CODE_BASE - *) + ")"
.pc = difficulty_resume

//==============================================================================
// Bomb Bitmaps ($18BE Gap)
//==============================================================================

// Placed in the $18BE gap (between the sound state at SOUND_RAM_BASE + 14
// and the RNG state at RANDOM_RAM_BASE). The two animation frames (16 B)
// would overflow the full upper block, so they live here. Both frames share
// this page, so set_proj_ptr fixes the high byte and animates only the low
// byte (bomb_ptr_lo).

.var bomb_resume = *
.pc = SOUND_RAM_BASE + 14 "bomb-bitmaps"

#import "sprites/bomb.asm"

.errorif (* > RANDOM_RAM_BASE), "bomb bitmaps overran into the RNG state ($18D0)"
.print "BOMB BITMAPS END = " + toHexString(*) + " (limit " + toHexString(RANDOM_RAM_BASE) + ", free " + (RANDOM_RAM_BASE - *) + ")"
.pc = bomb_resume

//==============================================================================
// Disk Code Overlay Segment ($033C-$03FB)
//==============================================================================

// Assembled in this same run (so it shares every symbol with the main
// program) and written to a separate overlay.prg; load_overlay pulls it off
// the .d64 into the cassette buffer at boot. See overlay.asm.

.segmentdef Overlay [start=OVERLAY_BASE]
.segment Overlay

#import "overlay.asm"

.print "PROJ OVERLAY END = " + toHexString(*) + " (limit " + toHexString(OVERLAY_TOP + 1) + ", free " + (OVERLAY_TOP + 1 - *) + ")"
.errorif (* > OVERLAY_TOP + 1), "disk overlay overran the cassette buffer ($03FB)"

.segment Default
.file [name="overlay.prg", segments="Overlay"]

//==============================================================================
// Second Disk Overlay (Combined File, $0200-$033B)
//==============================================================================

// Spans $0200-$033B as ONE contiguous segment, written to a single
// overlay2.prg and loaded by load_overlay's "P". The segment is logically
// two regions:
//
//   $0200-$0258  score overlay  (the original BASIC input buffer; score.asm)
//   $0259-$033B  3rd overlay    (the KERNAL workspace gap; overlay3.asm,
//                                validated 2026-06-04 to survive the
//                                boot-time KERNAL_LOAD calls; see
//                                overlay3.asm)
//
// Combining them into one .prg avoids needing any new load_overlay code
// (zero charset-tail cost). KERNAL_LOAD "P" pulls all 316 B and each byte
// lands at its assembled address (the gap is zero-padded by Kick Assembler
// when the .pc is set forward).

.segmentdef Overlay2 [start=OVERLAY2_BASE]
.segment Overlay2

#import "score.asm"

.print "SCORE OVERLAY END = " + toHexString(*) + " (limit " + toHexString(OVERLAY2_TOP + 1) + ", free " + (OVERLAY2_TOP + 1 - *) + ")"
.errorif (* > OVERLAY2_TOP + 1), "score overlay (score.asm) overran the $0200 input buffer ($0258)"

.pc = OVERLAY3_BASE "overlay3"

#import "overlay3.asm"

// The Overlay2 .prg is KERNAL-LOADed to $0200 at boot, so its LAST BYTE must
// stay below $0314: any byte at $0314+ overwrites the live KERNAL vectors
// the load itself rides on. CINV ($0314, the IRQ vector pointed at
// sound_isr) and the I/O vectors including ILOAD ($0330). (OVERLAY3_TOP =
// $033B is the nominal region size, but only $0259-$0313 is safe to
// actually fill.) This guard is the real limit.

.print "OVERLAY3 END = " + toHexString(*) + " (limit $0314, free " + ($0314 - *) + ")"
.errorif (* > $0314), "Overlay2 .prg reaches the KERNAL vectors at $0314+ (CINV/ILOAD) -- it will crash its own boot load. Keep overlay3 code below $0314."

.segment Default
.file [name="overlay2.prg", segments="Overlay2"]

//==============================================================================
// Screens / Menu Overlay ($033C-$03FB)
//==============================================================================

// TIME-SHARES the cassette buffer with the projectile overlay ("O"): only
// one is loaded at a time (menu vs. play). Holds screens.asm (the
// disk-banner loader / painter) plus the boot menu sequencer. Loaded as "S"
// at boot ONLY (load_overlay); enter_play_boot then loads "O" over it when
// play starts, and nothing ever loads "S" again. the game-over screen is
// the zero-disk page1_gameover (resident.asm). Assembled in this same run so
// it shares every symbol with the main program; written to its own
// screens-overlay.prg.

.segmentdef OverlayScreens [start=OVERLAY_BASE]
.segment OverlayScreens

#import "screens.asm"

//------------------------------------------------------------------------------
//
// Subroutine: start_menu
//
// Description:
//
//   The consolidated single-screen startup: title + author + controls +
//   press-any-key on one screen (47 pool cells. the whole pool; the
//   banner pre-generation guard fails the build if the four banners outgrow
//   it),
//   then hands off to enter_play_boot (load "O", re-init, run). Entered from
//   main at BOOT ONLY. the game-over screen is the zero-disk page1_gameover
//   (resident.asm), which goes straight back into play, so the title screen
//   shows once per power-on. Also performs the one and only load of the
//   page-1 "R" overlay (the resident banners + game-over code). The T/A/C
//   banners still stream from disk (show_banner); the press banner is
//   painted from the resident data. init_video clears the screen and sets
//   the black border + MSGFLG. Does not return (ends with jmp
//   enter_play_boot).
//
//------------------------------------------------------------------------------

start_menu:

    jsr init_video                              // Black border, blank screen,
                                                // KERNAL messages off.

    // Load the page-1 "R" overlay → $0100-$01D7: the resident PRESS ANY KEY
    // + GAME OVER banners and the zero-disk game-over code (resident.asm).
    // Loaded ONCE per power-on, here; nothing ever reloads it.

    ldx #<ovlr_name
    ldy #>ovlr_name
    lda #$01
    jsr load_file

    ldx #BANNER_TITLE
    jsr show_banner
    ldx #BANNER_AUTHOR
    jsr show_banner
    ldx #BANNER_CONTROLS
    jsr show_banner
    jsr page1_show_press                        // Press banner from the
                                                //   resident data (no "K"
                                                //   disk load any more).
    jsr wait_any_key
    jmp enter_play_boot                         // overlay3: load "O" → $033C
                                                //   (it overwrites THIS
                                                //   overlay. that is why the
                                                //   load cannot live here),
                                                //   then fall into enter_play.

//------------------------------------------------------------------------------
// Disk-file name for the page-1 "R" overlay. Lives HERE in the S overlay,
// next to its only user (start_menu above). the resident upper block, where
// the other name bytes sit, is full.
//------------------------------------------------------------------------------

ovlr_name:
    .byte $52                                   // "R" (PETSCII) → the $0100
                                                //   page-1 resident overlay.

//------------------------------------------------------------------------------
//
// Subroutine: wait_any_key
//
// Description:
//
//   Two-phase wait: first for all keys released, then for any new keypress.
//   Uses restart_key_down (resident in overlay3). Mirrors overlay3_restart's
//   old in-line key waits.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

wait_any_key:

!release:

    jsr restart_key_down
    bne !release-

!press:

    jsr restart_key_down
    beq !press-
    rts

.errorif (* > OVERLAY_TOP + 1), "screens / menu overlay overran the cassette buffer ($03FB)"
.print "SCREENS OVERLAY END = " + toHexString(*) + " (limit " + toHexString(OVERLAY_TOP + 1) + ", free " + (OVERLAY_TOP + 1 - *) + ")"
.segment Default
.file [name="screens-overlay.prg", segments="OverlayScreens"]

//==============================================================================
// Page-1 Resident Overlay ($0100-$01D7)
//==============================================================================

// The "R" disk file: the resident PRESS ANY KEY + GAME OVER banners and the
// zero-disk game-over screen, living in the unused floor of the 6502 stack
// page (the stack only ever touches the top of the page. see PAGE1_BASE /
// PAGE1_TOP in constants.asm). Loaded ONCE at boot by start_menu and never
// reloaded, making the game-over → restart cycle zero-disk. Assembled in this
// same run (shares every symbol); written to its own resident.prg.

.segmentdef Page1 [start=PAGE1_BASE]
.segment Page1

#import "resident.asm"

.print "PAGE1 OVERLAY END = " + toHexString(*) + " (limit " + toHexString(PAGE1_TOP + 1) + ", free " + (PAGE1_TOP + 1 - *) + ")"
.errorif (* > PAGE1_TOP + 1), "page-1 resident overlay reaches the stack floor ($01D8) -- the live stack / KERNAL LOAD would corrupt it. Shrink resident.asm."
.segment Default
.file [name="resident.prg", segments="Page1"]
