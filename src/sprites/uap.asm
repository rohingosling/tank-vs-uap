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
//   UAP entity bitmap (15 x 7 px).
//
//   Stored 2 bytes per row (16-px-wide blitter format): byte 0 =
//   pixels 0-7, byte 1 = pixels 8-15, bit 7 = leftmost pixel. The 15-px
//   shape is left-aligned; pixel 15 is 0 padding. Vertical-axis symmetric:
//   no directional variant.
//
//*******************************************************************************

#importonce

.const UAP_WIDTH                = 15
.const UAP_HEIGHT               = 7

//------------------------------------------------------------------------------
// UAP bitmap. one .byte pair per row; the trailing comment shows the row's
// pixel pattern.
//------------------------------------------------------------------------------

uap_bitmap:

    .byte $03, $80                              // ......XXX......
    .byte $04, $40                              // .....X...X.....
    .byte $08, $20                              // ....X.....X....
    .byte $7f, $fc                              // .XXXXXXXXXXXXX.
    .byte $d6, $d6                              // XX.X.XX.XX.X.XX
    .byte $7f, $fc                              // .XXXXXXXXXXXXX.
    .byte $07, $c0                              // .....XXXXX.....
