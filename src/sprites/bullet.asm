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
//   Tank bullet bitmap (2 x 3 px).
//
//   2 bytes per row: the 2-px shape sits in the top bits of byte 0
//   ($C0 = pixels 0-1); byte 1 is padding. There are two alternating
//   frames; this uses the solid shape (the flicker animation is polish for
//   later). Vertical-axis symmetric. no directional variant.
//
//*******************************************************************************

#importonce

#import "constants.asm"                         // BULLET_WIDTH / BULLET_HEIGHT.

bullet_bitmap:

    .byte $c0, $00                              // XX
    .byte $c0, $00                              // XX
    .byte $c0, $00                              // XX
