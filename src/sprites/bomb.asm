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
//   UAP bomb bitmap (3 x 4 px, solid diamond. the frame-0 art).
//
//   Stored 2 bytes per row (16-px-wide blitter format): byte 0 =
//   pixels 0-7, byte 1 = pixels 8-15 (padding). Vertical-axis symmetric.
//   no directional variant. Pulled out of proj.asm so the bitmap can live
//   in the upper block while the proj code stays in the charset tail.
//
//*******************************************************************************

#importonce

//------------------------------------------------------------------------------
// Frame 1 — the full (solid) diamond.
//------------------------------------------------------------------------------

bomb_bitmap_1:

    .byte $40, $00                              // .X.
    .byte $e0, $00                              // XXX
    .byte $e0, $00                              // XXX
    .byte $40, $00                              // .X.

//------------------------------------------------------------------------------
// Frame 2 — hollow diamond (the bomb alternates to this every ~183 ms as it
// falls).
//
// Its set pixels MUST stay a SUBSET of frame 1's: the blitter always erases a
// bomb with frame 1 (the full diamond), so frame 1 has to cover every pixel
// frame 2 can light, or the erase leaves residue. Hollow diamond ($A0 = X.X
// is a subset of $E0 = XXX).
//------------------------------------------------------------------------------

bomb_bitmap_2:

    .byte $40, $00                              // .X.
    .byte $a0, $00                              // X.X
    .byte $a0, $00                              // X.X
    .byte $40, $00                              // .X.
