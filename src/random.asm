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
//   Galois LFSR (tap $1D, period 255) + counter-XOR variant.
//
//   Seeded from the VIC raster ($9004) with a $00 → $FF fallback (an LFSR
//   seeded with 0 is stuck at 0). The LFSR alone repeats every 255 calls;
//   XOR-ing its state with a free-running byte counter stretches the
//   perceptual period to 255 * 256 = 65280 for +5 cycles/call. Serves
//   motion, fire probability, and scoring.
//
//   Placement-agnostic CODE; state at RANDOM_RAM_BASE (uninitialised RAM,
//   not in the .prg).
//
//*******************************************************************************

#importonce

#import "constants.asm"

//==============================================================================
// Constants
//==============================================================================

// RNG state, in uninitialised RAM at RANDOM_RAM_BASE (not in the .prg).

.const rng_state                = RANDOM_RAM_BASE      // LFSR state (1..255, never 0).
.const rng_counter              = RANDOM_RAM_BASE + 1  // Free-running byte counter.

//==============================================================================
// Subroutines — Random Number Generator
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: random_init
//
// Description:
//
//   Seeds the LFSR from the VIC raster line, forcing a non-zero seed: a $00
//   raster value falls back to $FF, because an LFSR seeded with 0 is stuck
//   at 0. Also clears the free-running counter.
//
// Outputs:
//
//   rng_state   - seeded to a non-zero value.
//   rng_counter - cleared to 0.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

random_init:

    lda VIC_RASTER
    bne !seeded+
    lda #$ff                                    // 0 would stick the LFSR; use $FF instead.

!seeded:

    sta rng_state
    lda #$00
    sta rng_counter
    rts

//------------------------------------------------------------------------------
//
// Subroutine: random_next
//
// Description:
//
//   Advances the LFSR one step (shift right; on carry, EOR the
//   maximal-length tap $1D), increments the free-running counter, and
//   returns the XOR of the two. Preserves X and Y.
//
// Outputs:
//
//   A - rng_state EOR rng_counter.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

random_next:

    lda rng_state
    lsr                                         // Shift right; LSB → carry.
    bcc !no_tap+
    eor #$1d                                    // Maximal-length tap.

!no_tap:

    sta rng_state
    inc rng_counter
    eor rng_counter                             // A = rng_state EOR rng_counter.
    rts
