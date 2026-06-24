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
//   canvas.asm. the Dynamic Tile Canvas: pool claim / release plus the
//   cell-oriented blitter.
//
//   Entities are drawn as true pixels by binding pooled charset cells
//   ($1A-$7F) to screen cells on demand. The
//   value in a screen cell IS its slot index, so screen RAM doubles as the
//   cell → slot map.
//
//   Blitter design (mandatory, not per-pixel):
//
//     Pass 1 (blit_shift): for each bitmap row, shift byte0:byte1:0 (24 bits)
//     right by (x AND 7) to place the row at any sub-cell column, producing
//     three cell-column bytes col_buf0/1/2.
//
//     Pass 2 (merge): walk the sprite band by band (one cell row = 8 pixel
//     rows); for each of the up-to-3 cell columns, compute the charset cell
//     address ONCE, then merge whole bytes down the column's row stack (OR to
//     plot, AND-NOT to erase). All-zero columns are skipped.
//
//   The code and tables are placement-agnostic (the includer sets `.pc` into
//   the lower block before import). RAM scratch lives at fixed upper-block
//   addresses (CANVAS_RAM_BASE), uninitialised in the .prg.
//
//*******************************************************************************

#importonce

#import "constants.asm"

//==============================================================================
// Constants
//==============================================================================

//------------------------------------------------------------------------------
// Zero-page scratch.
//
// ZP scratch $E8-$FF, never overlapping $F5 / $F6.
//------------------------------------------------------------------------------

.const ZP_BITMAP_PTR            = $E8           // +$E9: source bitmap pointer.
.const ZP_SCREEN_PTR            = $EA           // +$EB: current band's screen-row base.
.const ZP_CELL_PTR              = $EC           // +$ED: current charset cell.
.const ZP_COL_PTR               = $EE           // +$EF: current column's row stack (offset
                                                //   to map ric → bmrow).
.const ZP_SHIFT0                = $F0           // 24-bit shift accumulator: leftmost cell column.
.const ZP_SHIFT1                = $F1           // 24-bit shift accumulator: middle cell column.
.const ZP_SHIFT2                = $F2           // 24-bit shift accumulator: rightmost cell column.

//------------------------------------------------------------------------------
// Upper-block RAM scratch.
//
// Uninitialised; not emitted to the .prg.
//------------------------------------------------------------------------------

.const free_stack               = CANVAS_RAM_BASE  // POOL_SLOTS bytes (base in constants.asm).
.const col_buf0                 = free_stack + POOL_SLOTS  // 16 bytes (one byte per sprite row).
.const col_buf1                 = col_buf0 + 16
.const col_buf2                 = col_buf1 + 16
.const free_count               = col_buf2 + 16  // Free slots remaining.
.const bv_x                     = free_count + 1  // Call inputs:
.const bv_y                     = bv_x + 1
.const bv_height                = bv_y + 1
.const bv_sub_x                 = bv_height + 1  // x AND 7.
.const bv_cell_col              = bv_sub_x + 1  // x >> 3.
.const bv_nz0                   = bv_cell_col + 1  // Per-column "any bits set" (must be
                                                   //   contiguous: indexed by column).
.const bv_nz1                   = bv_nz0 + 1
.const bv_nz2                   = bv_nz1 + 1
.const bv_cur_cell_row          = bv_nz2 + 1
.const bv_ric_start             = bv_cur_cell_row + 1  // Row-in-cell of this band's first row.
.const bv_band_first_bmrow      = bv_ric_start + 1  // Bitmap row index at band start.
.const bv_band_rows             = bv_band_first_bmrow + 1
.const bv_band_offset           = bv_band_rows + 1  // band_first_bmrow - ric_start (signed).
.const bv_band_offset_hi        = bv_band_offset + 1  // Its sign extension ($00 / $FF).
.const bv_ric_end               = bv_band_offset_hi + 1  // ric_start + band_rows.
.const bv_col                   = bv_ric_end + 1  // Current column 0..2.
.const bv_slot                  = bv_col + 1    // Current pool slot.
.const bv_scol                  = bv_slot + 1   // Current screen column.
.const bv_remaining             = bv_scol + 1   // Sprite rows left to band.
.const CANVAS_RAM_END           = bv_remaining + 1

//------------------------------------------------------------------------------
// Pool-zero geometry.
//
// floor() every split. Kick Assembler '/' is float division.
//------------------------------------------------------------------------------

.const POOL_CHARSET_BASE        = CHARSET_BASE + POOL_FIRST_SLOT * 8  // $14A8.
.const POOL_ZERO_BYTES          = POOL_SLOTS * 8  // 376.
.const POOL_ZERO_FULL_PAGES     = floor( POOL_ZERO_BYTES / 256 )  // 1.
.const POOL_ZERO_TAIL           = POOL_ZERO_BYTES - POOL_ZERO_FULL_PAGES * 256  // 120.

//==============================================================================
// Subroutines — Initialization
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: canvas_init
//
// Description:
//
//   Zeroes the dynamic pool's charset bytes, builds the free stack, and sets
//   colour RAM once.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

canvas_init:

    // Zero the dynamic pool's charset bytes ($14A8-$161F).

    lda #$00
    ldx #$00

!page:

    .for (var p = 0; p < POOL_ZERO_FULL_PAGES; p++)
    {
        sta POOL_CHARSET_BASE + p * 256, x
    }
    inx
    bne !page-

    .if (POOL_ZERO_TAIL > 0)
    {
        ldx #POOL_ZERO_TAIL - 1

    !tail:

        sta POOL_CHARSET_BASE + POOL_ZERO_FULL_PAGES * 256, x
        dex
        bpl !tail-
    }

    // Build the free stack: slots POOL_FIRST_SLOT..POOL_LAST_SLOT all free.

    ldx #$00

!fill:

    txa
    clc
    adc #POOL_FIRST_SLOT
    sta free_stack, x
    inx
    cpx #POOL_SLOTS
    bne !fill-

    lda #POOL_SLOTS
    sta free_count

    // Colour RAM: set once (the canvas never touches colour at runtime).

    ldx #$00

!colour:

    lda #CANVAS_COLOUR
    sta COLOUR_RAM + $000, x
    sta COLOUR_RAM + $100, x
    inx
    bne !colour-

    rts

//==============================================================================
// Subroutines — Blitter
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: blit_run
//
// Description:
//
//   The shared band-walk body for plot_bitmap and erase_bitmap: draws or
//   erases the bitmap at (bv_x, bv_y), bv_height rows, with ZP_BITMAP_PTR →
//   data. Both entry points share this ONE body; only the per-cell handler
//   (claim + OR versus AND-NOT + release) differs, so each entry self-modifies
//   the cell-handler jsr operand ONCE per call (not per cell. zero hot-path
//   cost) and jumps here. This reclaims ~114 B versus expanding the body twice
//   (it was an assembly-time macro).
//
// Inputs:
//
//   bv_x          - Bitmap X position (pixels).
//   bv_y          - Bitmap Y position (pixels).
//   bv_height     - Bitmap height (rows).
//   ZP_BITMAP_PTR - Pointer to the source bitmap data.
//
// Clobbers: A, Y, ZP_SCREEN_PTR, ZP_CELL_PTR, ZP_COL_PTR, ZP_SHIFT0-ZP_SHIFT2
//           (X is preserved).
//
//------------------------------------------------------------------------------

blit_run:

    // Preserve the caller's X across the blit (the band walk uses X
    // internally); restored at !done. plot_bitmap / erase_bitmap therefore
    // PRESERVE X, so callers iterating an entity slot in X no longer need to
    // wrap each blit in txa / pha / pla / tax.

    txa
    pha

    jsr blit_compute_geometry
    jsr blit_shift

    // Band-iteration setup.

    lda bv_y
    lsr
    lsr
    lsr
    sta bv_cur_cell_row                         // y >> 3.
    lda bv_y
    and #$07
    sta bv_ric_start                            // y AND 7.
    lda #$00
    sta bv_band_first_bmrow
    lda bv_height
    sta bv_remaining

!band:

    // band_rows = min( 8 - ric_start, remaining ).

    lda #$08
    sec
    sbc bv_ric_start
    cmp bv_remaining
    bcc !skip+
    lda bv_remaining

!skip:

    sta bv_band_rows
    clc
    adc bv_ric_start
    sta bv_ric_end

    // band_offset = band_first_bmrow - ric_start (signed; maps row-in-cell to
    // the col_buf row).

    lda bv_band_first_bmrow
    sec
    sbc bv_ric_start
    sta bv_band_offset
    lda #$00
    sbc #$00
    sta bv_band_offset_hi

    // screen_ptr = start of this cell row.

    ldx bv_cur_cell_row
    lda screen_row_lo, x
    sta ZP_SCREEN_PTR
    lda screen_row_hi, x
    sta ZP_SCREEN_PTR + 1

    // For each of the 3 cell columns.

    lda #$00
    sta bv_col

!col:

blit_cell_call:
    jsr plot_one_cell                           // Cell handler; operand self-modified by
                                                //   plot_bitmap / erase_bitmap.
    inc bv_col
    lda bv_col
    cmp #$03
    bne !col-

    // Advance to the next band.

    lda bv_band_first_bmrow
    clc
    adc bv_band_rows
    sta bv_band_first_bmrow
    lda bv_remaining
    sec
    sbc bv_band_rows
    sta bv_remaining
    beq !done+
    inc bv_cur_cell_row
    lda #$00
    sta bv_ric_start
    jmp !band-

!done:

    pla
    tax                                         // Restore the caller's X (saved at entry).
    rts

//------------------------------------------------------------------------------
//
// Subroutine: plot_bitmap
//
// Description:
//
//   Draws the bitmap at (bv_x, bv_y), bv_height rows, with ZP_BITMAP_PTR →
//   data. Patches the shared body's cell-handler jsr to plot_one_cell
//   (claim + OR-in) and jumps to blit_run.
//
// Clobbers: A, Y, ZP_SCREEN_PTR, ZP_CELL_PTR, ZP_COL_PTR, ZP_SHIFT0-ZP_SHIFT2
//           (X is preserved).
//
//------------------------------------------------------------------------------

plot_bitmap:

    lda #<plot_one_cell
    sta blit_cell_call + 1
    lda #>plot_one_cell
    sta blit_cell_call + 2
    jmp blit_run

//------------------------------------------------------------------------------
//
// Subroutine: erase_bitmap
//
// Description:
//
//   Erases the bitmap at (bv_x, bv_y), bv_height rows, with ZP_BITMAP_PTR →
//   data. Patches the shared body's cell-handler jsr to erase_one_cell
//   (AND-NOT + release) and jumps to blit_run.
//
//   ERASE must be called with the entity's PREVIOUS bitmap pointer and
//   PREVIOUS (x, y) so it clears exactly the pixels that draw set.
//
// Clobbers: A, Y, ZP_SCREEN_PTR, ZP_CELL_PTR, ZP_COL_PTR, ZP_SHIFT0-ZP_SHIFT2
//           (X is preserved).
//
//------------------------------------------------------------------------------

erase_bitmap:

    lda #<erase_one_cell
    sta blit_cell_call + 1
    lda #>erase_one_cell
    sta blit_cell_call + 2
    jmp blit_run

//------------------------------------------------------------------------------
//
// Subroutine: plot_one_cell
//
// Description:
//
//   Resolves (claims) the cell for column bv_col in the current band and ORs
//   this column's rows into it. Skips all-zero columns, off-screen columns,
//   and exhausted claims (silently. the cell stays blank and self-heals).
//
// Clobbers: A, X, Y, ZP_CELL_PTR, ZP_COL_PTR.
//
//------------------------------------------------------------------------------

plot_one_cell:

    ldx bv_col
    lda bv_nz0, x
    bne !go+
    rts                                         // All-zero column: nothing to plot.

!go:

    lda bv_cell_col
    clc
    adc bv_col
    cmp #SCREEN_COLUMNS
    bcc !on+
    rts                                         // Off the right edge: clip.

!on:

    sta bv_scol
    tay
    lda ( ZP_SCREEN_PTR ), y                    // Peek the current slot in this screen cell.

    cmp #BLANK_CELL
    bne !notblank+

    // Blank cell: claim a free slot.

    lda free_count
    bne !claim+

    // Pool exhausted: skip this cell (leave it blank). A freed slot reclaims
    // it on a later frame. self-healing, so a transient peak never leaves a
    // permanent artifact. (The old debug sentinel glyph is gone; its charset
    // cell is a pool slot now.)

    rts

!claim:

    dec free_count
    ldx free_count
    lda free_stack, x
    sta bv_slot
    sta ( ZP_SCREEN_PTR ), y                    // Y still = bv_scol (set by the tay at !on,
                                                //   not clobbered since) → no ldy reload.
    jmp !haveslot+

!notblank:

    // Non-blank cell → an existing pool slot (shared cell). With exhaustion
    // skipping silently and entities confined to the dynamic rows, a drawn
    // cell is always a slot.

    sta bv_slot

!haveslot:

    jsr set_cell_ptr
    jsr set_col_ptr

    // Merge this column's rows into the cell: charset |= col_buf.

    ldy bv_ric_start

!merge:

    lda ( ZP_COL_PTR ), y
    ora ( ZP_CELL_PTR ), y
    sta ( ZP_CELL_PTR ), y
    iny
    cpy bv_ric_end
    bne !merge-
    rts

//------------------------------------------------------------------------------
//
// Subroutine: erase_one_cell
//
// Description:
//
//   ANDs-NOT this column's rows out of the cell for column bv_col in the
//   current band, then releases the slot if the whole cell went blank.
//
// Clobbers: A, X, Y, ZP_CELL_PTR, ZP_COL_PTR.
//
//------------------------------------------------------------------------------

erase_one_cell:

    ldx bv_col
    lda bv_nz0, x
    bne !go+
    rts                                         // All-zero column: this entity never touched it.

!go:

    lda bv_cell_col
    clc
    adc bv_col
    cmp #SCREEN_COLUMNS
    bcc !on+
    rts                                         // Off the right edge: clip.

!on:

    sta bv_scol
    tay
    lda ( ZP_SCREEN_PTR ), y
    cmp #POOL_FIRST_SLOT
    bcs !poolslot+
    rts                                         // Blank / static cell: nothing to erase.

!poolslot:

    sta bv_slot
    jsr set_cell_ptr
    jsr set_col_ptr

    // Clear this column's rows from the cell: charset &= ~col_buf.

    ldy bv_ric_start

!merge:

    lda ( ZP_COL_PTR ), y
    eor #$FF
    and ( ZP_CELL_PTR ), y
    sta ( ZP_CELL_PTR ), y
    iny
    cpy bv_ric_end
    bne !merge-

    // Release the slot only if the entire cell is now blank.

    ldy #$07

!check:

    lda ( ZP_CELL_PTR ), y
    bne !keep+
    dey
    bpl !check-

    ldx free_count
    lda bv_slot
    sta free_stack, x
    inc free_count
    lda #BLANK_CELL
    ldy bv_scol
    sta ( ZP_SCREEN_PTR ), y

!keep:

    rts

//==============================================================================
// Subroutines — Shared Blit Helpers
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: blit_compute_geometry
//
// Description:
//
//   bv_sub_x = x AND 7; bv_cell_col = x >> 3.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

blit_compute_geometry:

    lda bv_x
    and #$07
    sta bv_sub_x
    lda bv_x
    lsr
    lsr
    lsr
    sta bv_cell_col
    rts

//------------------------------------------------------------------------------
//
// Subroutine: blit_shift
//
// Description:
//
//   Pass 1: shifts each bitmap row right by sub_x into col_buf0/1/2 and
//   OR-accumulates the per-column "any bits set" flags (bv_nz0/1/2).
//
// Clobbers: A, X, Y, ZP_SHIFT0-ZP_SHIFT2.
//
//------------------------------------------------------------------------------

blit_shift:

    lda #$00
    sta bv_nz0
    sta bv_nz1
    sta bv_nz2

    ldx #$00                                    // X = bitmap row index.

!row:

    txa
    asl
    tay                                         // Y = 2 * row (byte offset).
    lda ( ZP_BITMAP_PTR ), y
    sta ZP_SHIFT0                               // col0 = byte 0.
    iny
    lda ( ZP_BITMAP_PTR ), y
    sta ZP_SHIFT1                               // col1 = byte 1.
    lda #$00
    sta ZP_SHIFT2                               // col2 = 0.

    ldy bv_sub_x
    beq !store+

!shift:

    lsr ZP_SHIFT0
    ror ZP_SHIFT1
    ror ZP_SHIFT2
    dey
    bne !shift-

!store:

    lda ZP_SHIFT0
    sta col_buf0, x
    ora bv_nz0
    sta bv_nz0
    lda ZP_SHIFT1
    sta col_buf1, x
    ora bv_nz1
    sta bv_nz1
    lda ZP_SHIFT2
    sta col_buf2, x
    ora bv_nz2
    sta bv_nz2

    inx
    cpx bv_height
    bne !row-
    rts

//------------------------------------------------------------------------------
//
// Subroutine: set_cell_ptr
//
// Description:
//
//   ZP_CELL_PTR = CHARSET_BASE + bv_slot * 8.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

set_cell_ptr:

    lda bv_slot
    and #$1F
    asl
    asl
    asl
    sta ZP_CELL_PTR                             // ( slot AND $1F ) << 3.
    lda bv_slot
    lsr
    lsr
    lsr
    lsr
    lsr
    clc
    adc #>CHARSET_BASE
    sta ZP_CELL_PTR + 1                         // $14 + ( slot >> 5 ).
    rts

//------------------------------------------------------------------------------
//
// Subroutine: set_col_ptr
//
// Description:
//
//   ZP_COL_PTR = col_buf[bv_col] + (band_first_bmrow - ric_start), so that
//   (ZP_COL_PTR), Y with Y = row-in-cell indexes the correct bitmap row of
//   this column.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

set_col_ptr:

    ldx bv_col
    lda col_buf_base_lo, x
    clc
    adc bv_band_offset
    sta ZP_COL_PTR
    lda col_buf_base_hi, x
    adc bv_band_offset_hi
    sta ZP_COL_PTR + 1
    rts

//==============================================================================
// Data — Read-Only Tables (Lower-Block Data)
//==============================================================================

screen_row_lo:

    .fill SCREEN_ROWS, <( SCREEN_RAM + i * SCREEN_COLUMNS )

screen_row_hi:

    .fill SCREEN_ROWS, >( SCREEN_RAM + i * SCREEN_COLUMNS )

col_buf_base_lo:

    .byte <col_buf0, <col_buf1, <col_buf2

col_buf_base_hi:

    .byte >col_buf0, >col_buf1, >col_buf2

.errorif (CANVAS_RAM_END > SCREEN_RAM), "canvas RAM overflows into screen RAM"
