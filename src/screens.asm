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
//   screens.asm. title / game-over screen support.
//
//   Streams the pre-generated disk banners into tile-pool charset cells and
//   places their cell codes on the screen. In the shipping game this lives in
//   the $033C disk overlay, which time-shares the region with the
//   projectile-render overlay (only one is live at a time. play vs menu).
//
//   Each banner .prg loads (KERNAL LOAD, secondary address 1 → the file's
//   own header address) into a run of pool charset cells; show_banner then
//   writes the matching cell codes (first_slot, +1, ...) into a
//   cells_w × cells_h rectangle on the screen, top-left from a per-banner
//   table. Layout + slot numbers are pre-generated (title $15-$28,
//   author $29-$31, controls $3C-$43). The press ($32-$3B) and game-over
//   ($15-$1C) banners are RAM-RESIDENT (no disk file): they are painted by
//   the page-1 "R" overlay (resident.asm), not by show_banner. only their
//   pool slots are still allocated by the same generation step, so nothing
//   collides.
//
//   Placement-agnostic CODE/tables (the includer sets .pc).
//
//*******************************************************************************

#importonce

#import "constants.asm"

//------------------------------------------------------------------------------
// Banner ids (index into the tables below).
//------------------------------------------------------------------------------

.const BANNER_TITLE             = 0
.const BANNER_AUTHOR            = 1
.const BANNER_PRESS             = 2
.const BANNER_GAMEOVER          = 3
.const BANNER_CONTROLS          = 4

//==============================================================================
// Banner Layout
//==============================================================================

// Banner positions + sizes are OWNED by the banner-generation step, not set
// here. To reposition a banner, edit its TOP-LEFT PIXEL (x, y) at generation
// time and rebuild: generation bakes the sub-cell offset into the art (real
// pixel placement, not 8-px-cell-snapped), auto-allocates the charset pool
// slots, and produces build/banner-layout.asm. the per-banner tables
// imported below. A build-time guard there fails if a menu screen needs more
// than the 44 pool cells.

//------------------------------------------------------------------------------
// Zero-page scratch.
//
// Reuses the gameplay scalar range $02-$06 (tank x / scheduler), which is
// free while a menu screen is up (gameplay is paused); tank_init re-seeds it
// when play starts.
//------------------------------------------------------------------------------

.const sb_ptr                   = $02           // +$03: screen write pointer.
.const sb_code                  = $04           // Current cell code being written.
.const sb_rows                  = $05           // Cell-rows remaining.
.const sb_width                 = $06           // Cells per row (banner_cw of the current banner).

//------------------------------------------------------------------------------
// Per-banner tables (banner_name / banner_slot / banner_cw / banner_ch /
// banner_scr_lo / banner_scr_hi), indexed by banner id.
//
// GENERATED from each banner's pixel position into build/banner-layout.asm
// (found via the assembler's -libdir build). Do NOT hand-edit positions or
// sizes here; edit the banner definitions at generation time and rebuild. The
// generated file also carries the banner_name page-boundary guard for
// banner_load below.
//------------------------------------------------------------------------------

#import "banner-layout.asm"

//------------------------------------------------------------------------------
//
// Subroutine: banner_load
//
// Description:
//
//   KERNAL-loads the banner file for banner id X (SA = 1 → the file's own
//   header address, i.e. its pool charset cells). Suppress KERNAL messages
//   via MSGFLG first if the screen is custom.
//
// Parameters:
//
//   X - Banner id (preserved).
//
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

banner_load:

    txa
    pha                                         // Save the id.
    clc
    adc #<banner_name                           // A = id → name pointer low.
    tax
    ldy #>banner_name                           // Y = name pointer high (banner_name + id stays on one
                                                //   page, guarded above). saves the old carry-correct.
    lda #$01                                    // Name length = 1.
    jsr KERNAL_SETNAM
    lda #$01                                    // Logical file 1.
    ldx #$08                                    // Device 8 (disk).
    ldy #$01                                    // SA = 1: load to the file's own (header) address.
    jsr KERNAL_SETLFS
    lda #$00                                    // 0 = load (not verify).
    jsr KERNAL_LOAD
    pla
    tax                                         // Restore the id.
    rts

//------------------------------------------------------------------------------
//
// Subroutine: show_banner
//
// Description:
//
//   Loads banner id X, then places its cell codes on the screen: writes the
//   matching codes (first_slot, +1, ...) into a cells_w × cells_h rectangle,
//   top-left from the per-banner tables.
//
// Parameters:
//
//   X - Banner id (preserved).
//
// Clobbers: A, Y, and the sb_* zero-page scratch.
//
//------------------------------------------------------------------------------

show_banner:

    jsr banner_load
    lda banner_scr_lo, x
    sta sb_ptr
    lda banner_scr_hi, x
    sta sb_ptr + 1
    lda banner_slot, x
    sta sb_code
    lda banner_ch, x
    sta sb_rows
    lda banner_cw, x                            // cpy has no absolute,X mode → hold the width in zero page.
    sta sb_width

!row:

    ldy #$00

!col:

    lda sb_code
    sta ( sb_ptr ), y
    inc sb_code
    iny
    cpy sb_width
    bne !col-
    lda sb_ptr                                  // Advance to the next screen cell-row.
    clc
    adc #SCREEN_COLUMNS
    sta sb_ptr
    bcc !same+
    inc sb_ptr + 1

!same:

    dec sb_rows
    bne !row-
    rts
