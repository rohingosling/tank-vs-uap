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
//   Player tank bitmap (16 x 16 px).
//
//   Stored 2 bytes per row (32 bytes), byte 0 = pixels 0-7, byte 1 =
//   pixels 8-15, bit 7 = left. The grid is the RIGHT-facing source of
//   truth; the LEFT-facing variant is generated at assembly time as a
//   horizontal mirror (swap each row's two bytes and reverse each byte's
//   bits) so the two can never drift.
//
//*******************************************************************************

#importonce

#import "constants.asm"                         // TANK_WIDTH / TANK_HEIGHT.

//------------------------------------------------------------------------------
// revbits( b ). reverse the 8 bits of a byte (for the horizontal mirror).
//------------------------------------------------------------------------------

.function revbits( b )
{
    .var r = 0
    .for ( var i = 0; i < 8; i++ )
    {
        .eval r = ( r << 1 ) | ( ( b >> i ) & 1 )
    }
    .return r
}

//------------------------------------------------------------------------------
// Right-facing tank rows (the single source of truth).
//------------------------------------------------------------------------------

.var tankRows = List()

.eval tankRows.add( $18, $00 )                  // ...XX...........
.eval tankRows.add( $18, $00 )                  // ...XX...........
.eval tankRows.add( $18, $00 )                  // ...XX...........
.eval tankRows.add( $18, $00 )                  // ...XX...........
.eval tankRows.add( $18, $00 )                  // ...XX...........
.eval tankRows.add( $3c, $00 )                  // ..XXXX..........
.eval tankRows.add( $3c, $00 )                  // ..XXXX..........
.eval tankRows.add( $99, $7c )                  // X..XX..X.XXXXX..
.eval tankRows.add( $c3, $72 )                  // XX....XX.XXX..X.
.eval tankRows.add( $ff, $f1 )                  // XXXXXXXXXXXX...X
.eval tankRows.add( $7f, $ff )                  // .XXXXXXXXXXXXXXX
.eval tankRows.add( $00, $00 )                  // ................
.eval tankRows.add( $2a, $aa )                  // ..X.X.X.X.X.X.X.
.eval tankRows.add( $5c, $1d )                  // .X.XXX.....XXX.X
.eval tankRows.add( $5c, $1d )                  // .X.XXX.....XXX.X
.eval tankRows.add( $2a, $aa )                  // ..X.X.X.X.X.X.X.

//------------------------------------------------------------------------------
// Right-facing bitmap, emitted verbatim from tankRows.
//------------------------------------------------------------------------------

tank_bitmap_right:

    .for ( var i = 0; i < tankRows.size(); i++ )
    {
        .byte tankRows.get( i )
    }

//------------------------------------------------------------------------------
// Left-facing bitmap. assembly-time horizontal mirror of tankRows (swap each
// row's two bytes and reverse each byte's bits).
//------------------------------------------------------------------------------

tank_bitmap_left:

    .for ( var row = 0; row < TANK_HEIGHT; row++ )
    {
        .byte revbits( tankRows.get( row * 2 + 1 ) ), revbits( tankRows.get( row * 2 + 0 ) )
    }
