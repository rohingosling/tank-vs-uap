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
//   UAP helper(s) relocated to the charset tail to relieve the full upper
//   block. Called cross-region from uap.asm (uap_render / uap_spawn).
//   Currently just set_uap_bitmap_ptr.
//
//*******************************************************************************

#importonce

#import "constants.asm"
#import "sprites/uap.asm"                       // uap_bitmap (emitted once, in the
                                                // upper block via uap.asm).

//------------------------------------------------------------------------------
//
// Subroutine: set_uap_bitmap_ptr
//
// Description:
//
//   Points ZP_BITMAP_PTR at the UAP bitmap (single source; the UAP is
//   vertical-axis symmetric).
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

set_uap_bitmap_ptr:

    lda #<uap_bitmap
    sta ZP_BITMAP_PTR
    lda #>uap_bitmap
    sta ZP_BITMAP_PTR + 1
    rts
