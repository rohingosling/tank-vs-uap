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
//   Scoring band classifier resident in the charset-tail gap (with proj.asm
//   and collide.asm). band_index maps an entity y to an altitude band; it is
//   called only by collide's hit handlers (hit_uap / hit_bullet_bomb), which
//   then index the band-point tables (uap_band_points / bomb_band_points).
//   those tables live in the $0200 scoring overlay (score.asm) to keep the
//   tail within $1800. set_proj_ptr was moved to the $033C overlay
//   (overlay.asm); the per-frame integrator there is its main caller and the
//   tail was full.
//
//*******************************************************************************

#importonce

#import "proj-defs.asm"

//------------------------------------------------------------------------------
//
// Subroutine: band_index
//
// Description:
//
//   Maps an entity y to an altitude scoring band. Higher altitude (lower y) →
//   lower index → more points.
//
// Parameters:
//
//   A - Entity y.
//
// Outputs:
//
//   Y - Band index: 0 (high, y < 48) / 1 (medium, y < 88) / 2 (low).
//
// Clobbers: Y (A and X are preserved).
//
//------------------------------------------------------------------------------

band_index:

    ldy #0
    cmp #BAND_HIGH_Y
    bcc !done+                                  // y <  48 → high (Y = 0).
    iny
    cmp #BAND_MED_Y
    bcc !done+                                  // y <  88 → medium (Y = 1).
    iny                                         // y ≥  88 → low (Y = 2).

!done:

    rts
