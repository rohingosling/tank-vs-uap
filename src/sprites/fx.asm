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
//   Shared FX bitmaps: the explosion burst (air + ground) and the tank gun
//   muzzle flash. every bitmap drawn by the shared FX engine (fx.asm), in
//   one file.
//
//   Explosion burst: the "Air explosion" art. 13 x 13 px, single
//   frame. We keep only Frame 2 (the largest burst with outer debris),
//   dropping Frames 0 (small core) and 1 (four-pointed star) to save space.
//   The same bitmap source serves both air and ground
//   explosions.
//
//   Muzzle flash: the "Tank Gun Muzzle Flash" art. 8 x 5 px,
//   single frame, drawn by fx_spawn_muzzle when the gun fires, for the same
//   FX_LIFE_FRAMES as an air explosion.
//
//   Format (both): 2 bytes per row (16-px-wide blitter), byte 0 =
//   cols 0..7, byte 1 = the remaining columns in its top bits, padded with
//   0. Bit 7 = leftmost pixel. Both are horizontally symmetric, so one
//   bitmap serves all cases (the burst is radial; the flash mirrors via its
//   spawn x instead of a flipped variant).
//
//*******************************************************************************

#importonce

.const FX_WIDTH                 = 13
.const FX_HEIGHT                = 13

// Top half of the burst (rows 0-6, ending on the widest row): plotted alone it
// reads as a dome sitting on a surface. used for the bomb-on-ground puff.
// Same bitmap data; the blitter just stops after FX_HEIGHT_HALF rows.

.const FX_HEIGHT_HALF           = 7

//------------------------------------------------------------------------------
// FX bitmap (Frame 2: larger burst + debris). One .byte pair per row; the
// trailing comment shows the row's pixel pattern.
//------------------------------------------------------------------------------

fx_bitmap:

    .byte $02, $00                              // ......X......
    .byte $00, $00                              // .............
    .byte $20, $10                              // ..X........X.
    .byte $02, $00                              // ......X......
    .byte $08, $80                              // ....X...X....
    .byte $02, $00                              // ......X......
    .byte $97, $48                              // X..X.XXX.X..X
    .byte $02, $00                              // ......X......
    .byte $08, $80                              // ....X...X....
    .byte $02, $00                              // ......X......
    .byte $20, $20                              // ..X.......X..
    .byte $00, $00                              // .............
    .byte $02, $00                              // ......X......

fx_bitmap_end:

.assert "fx bitmap size = 26 B", fx_bitmap_end - fx_bitmap, FX_HEIGHT * 2

.const MUZZLE_FLASH_WIDTH       = 8
.const MUZZLE_FLASH_HEIGHT      = 5

//------------------------------------------------------------------------------
// Muzzle-flash bitmap. One .byte pair per row; the trailing comment shows the
// row's pixel pattern.
//
// The art interlocks with the tank: drawn at (tank gun x - 3, TANK_Y - 4)
// its bottom row's pixels (cols 1 and 6) FLANK the 2-px gun barrel
// (flash-local cols 3-4) with no shared bits, so the flash erase can never
// erode a stationary tank's pixels.
//------------------------------------------------------------------------------

muzzle_flash_bitmap:

    .byte $42, $00                              // .X....X.
    .byte $18, $00                              // ...XX...
    .byte $bd, $00                              // X.XXXX.X
    .byte $18, $00                              // ...XX...
    .byte $42, $00                              // .X....X.

muzzle_flash_bitmap_end:

.assert "muzzle-flash bitmap size = 10 B", muzzle_flash_bitmap_end - muzzle_flash_bitmap, MUZZLE_FLASH_HEIGHT * 2
