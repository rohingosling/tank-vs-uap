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
//   The page-1 "R" overlay, resident at $0100-$01D7 ($0100 is the 6502 stack
//   page's unused floor. the stack itself never leaves the top of the page;
//   see PAGE1_BASE/PAGE1_TOP in constants.asm). Loaded ONCE at boot by
//   start_menu, and never reloaded: it makes the whole game-over → restart
//   cycle ZERO-disk.
//
//   Holds the two RAM-resident banners (PRESS ANY KEY, 80 B; GAME OVER, 64 B
//   — packed cell bytes + layout constants pre-generated into banner-resident.asm)
//   plus the code that paints them:
//
//     page1_show_press. copy the press art into its pool charset cells and
//                        write its cell codes on the screen. Used by BOTH the
//                        boot title screen (start_menu) and the game-over
//                        screen, replacing the old disk-streamed "K" banner.
//     page1_gameover   . the full game-over screen + restart, replacing the
//                        old gameover_menu ("S" reload + "G"/"K" banner
//                        loads): blank the screen, paint GAME OVER + PRESS
//                        ANY KEY from the resident data, wait for a fresh
//                        keypress, jmp enter_play. Zero disk access. and
//                        enter_play no longer reloads "O" either, because
//                        with no "S" reload here the projectile overlay is
//                        still resident at $033C.
//
//   The banners' pool charset cells ($32-$3B / $15-$1C) are reused by
//   gameplay (the dynamic tile canvas owns the pool during play), so the art
//   must be re-copied every time a screen is shown. that is why the copy
//   loops, not just the data, live here.
//
//   IMPORTANT: code in this file runs WHILE THE STACK IS LIVE in the same
//   page (game-over arrives mid-game-loop with an abandoned jsr chain above,
//   and the sound ISR keeps firing). That is safe because the stack only
//   ever touches the top of the page; the PAGE1_TOP guard in tank-vs-uap.asm
//   keeps this overlay below it.
//
//*******************************************************************************

#importonce

#import "constants.asm"

//------------------------------------------------------------------------------
// Resident banner data + layout constants (PRESS_BANNER_* / GAMEOVER_BANNER_*),
// pre-generated into build/banner-resident.asm (found via the assembler's
// -libdir build). Do NOT hand-edit the art; regenerate the banner data and
// rebuild.
//------------------------------------------------------------------------------

#import "banner-resident.asm"

//------------------------------------------------------------------------------
//
// Subroutine: page1_show_press
//
// Description:
//
//   Paint the PRESS ANY KEY banner from the resident data: copy the 80 packed
//   art bytes into the banner's pool charset cells ($1590), then write its 10
//   sequential cell codes ($32, $33, ...) across the single-row screen
//   rectangle. The resident equivalent of show_banner (screens.asm) for the
//   old disk "K" banner.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

page1_show_press:

    ldx #PRESS_BANNER_BYTES - 1

!copy:

    lda press_banner_data, x
    sta PRESS_BANNER_CHARSET, x
    dex
    bpl !copy-

    ldx #PRESS_BANNER_CELLS - 1

!codes:

    txa
    clc
    adc #PRESS_BANNER_CODE                      // cell code = first code + column.
    sta PRESS_BANNER_SCREEN, x
    dex
    bpl !codes-
    rts

//------------------------------------------------------------------------------
//
// Subroutine: page1_gameover
//
// Description:
//
//   The zero-disk game-over screen + restart. Reached by jmp from
//   prepare_gameover (overlay3.asm) after the game-over jingle has finished
//   and the high score is saved. The border has been red since the last
//   life's burn; init_video resets it to BLACK and blanks the field (it falls
//   through into clear_screen). Paints GAME OVER + PRESS ANY KEY from the
//   resident data, waits for all keys released then a fresh keypress (same
//   two-phase shape as the old wait_any_key), and starts a new game directly
//   via enter_play. the title / controls screens show once per power-on
//   only. No disk access anywhere on this path.
//
// Clobbers: not meaningful. never returns (control passes to enter_play).
//
//------------------------------------------------------------------------------

page1_gameover:

    jsr init_video                              // black border + blank screen (the red ends
                                                // with the burn / jingle phase).

    // Copy the GAME OVER art into its pool charset cells ($14A8) and write
    // its 8 cell codes ($15, $16, ...) across the single-row rectangle.

    ldx #GAMEOVER_BANNER_BYTES - 1

!copy:

    lda gameover_banner_data, x
    sta GAMEOVER_BANNER_CHARSET, x
    dex
    bpl !copy-

    ldx #GAMEOVER_BANNER_CELLS - 1

!codes:

    txa
    clc
    adc #GAMEOVER_BANNER_CODE                   // cell code = first code + column.
    sta GAMEOVER_BANNER_SCREEN, x
    dex
    bpl !codes-

    jsr page1_show_press

    // Two-phase any-key wait: all keys released first (the key mashing that
    // lost the game must not skip the screen), then any fresh press starts a
    // new game. restart_key_down is resident in overlay3.

!release:

    jsr restart_key_down
    bne !release-

!press:

    jsr restart_key_down
    beq !press-

    jmp enter_play                              // re-init and run. no "O" reload needed: the
                                                // projectile overlay is still resident at $033C.
