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
//   UAP state constants (zero-page SoA map + state enum). Pure .const, emits
//   NO bytes, so it can be #imported early (e.g. by the unified projectile
//   pool's proj-defs.asm) to make uap_state / uap_x_hi / uap_y_hi /
//   UAP_STATE_FLYING resolvable without pulling in uap.asm's CODE. uap.asm
//   imports this too, so the map has a single source.
//
//*******************************************************************************

#importonce

#import "constants.asm"                         // UAP_MAX.

//==============================================================================
// Constants — UAP State Enum
//==============================================================================

.const UAP_STATE_INACTIVE       = 0
.const UAP_STATE_FLYING         = 1

// UAP_STATE_DIVING: shot-down wreck, falling to the ground. Bit 7 set so
// advance_uaps routes it with a one-byte `bmi` (no compare); also != FLYING,
// so bullets/bombs ignore a wreck (check_hits / try_fire_bombs test FLYING).

.const UAP_STATE_DIVING         = $80

// UAP_STATE_CRASHED: wreck burning on the ground (1000 ms dwell before
// respawn). Bit 7 set (like DIVING) so advance_uaps still routes it to
// uap_dive_step; != FLYING so bullets/bombs ignore it. Distinguished from
// DIVING by value (uap_dive_step branches CRASHED → dwell countdown, not
// descent).

.const UAP_STATE_CRASHED        = $C0

//==============================================================================
// Constants — Death Dive
//==============================================================================

// Death dive. Deliberately simplified to a straight-down descent
// (no aimed trajectory), reaching the ground at row 20. Literal y thresholds
// (derivations in comments) to avoid cross-file .const ordering (TANK_Y /
// UAP_HEIGHT live in other modules).

.const UAP_DIVE_VY              = pxPerSecToDelta( 88 )     // descent speed, 8.8 (faster than
                                                            // the 66 px/s cruise).
.const UAP_GROUND_Y             = 160                       // row 20 * 8: crash line, just above
                                                            // the static ground row 21.
.const UAP_WRECK_TANK_Y         = 147                       // wreck inset base (y + 6) reaches the
                                                            // tank inset top (TANK_Y + 1): 152 - 6 + 1.
.const CRASH_DWELL_FRAMES       = msToFrames( 1000 )        // burning-wreck dwell on the ground
                                                            // before respawn (50 PAL).
.const UAP_FIRE_XMASK           = $03                       // F3: random x jitter (0-3 px) of the
                                                            // burn sprite along the 15-px wreck.
.const UAP_FIRE_Y               = 155                       // F3: burn-sprite top y
                                                            // (= 168 - FX_HEIGHT 13). Keeps the
                                                            // 13-px burn OFF the static ground
                                                            // (row 21, y 168+); flames rise over
                                                            // the wreck (at y 160). Erosion of
                                                            // row 21 here would corrupt the static glyphs.

//==============================================================================
// Constants — Collision Boxes
//==============================================================================

// Collision boxes: inset 1 px on every side from the sprite bitmap (a
// fairer, less twitchy hit. a clipped corner no longer registers). Bitmaps:
// UAP 15 x 7, tank 16 x 16. The AABB compares pos + offset with >=
// (edge-touch); *_HIT_FAR is the pos → inset far-edge offset (= bitmap - 1,
// i.e. 1 + (bitmap - 2)). Each box's NEAR (+1) inset is folded into the
// OPPOSING box's far offset (-1) at the test site, so there are no extra
// instructions versus the old full-box tests.

.const UAP_HIT_FAR_X            = 14                        // UAP box: cols 1..13 (13 px) of the
                                                            // 15 px bitmap.
.const UAP_HIT_FAR_Y            = 6                         // UAP box: rows 1..5 (5 px) of the
                                                            // 7 px bitmap.
.const TANK_HIT_FAR_X           = TANK_WIDTH - 1            // 15: 14 px box of the 16 px bitmap.
.const TANK_HIT_FAR_Y           = TANK_HEIGHT - 1           // 15: 14 px box of the 16 px bitmap.

//==============================================================================
// Constants — SoA Zero-Page State
//==============================================================================

// SoA zero-page state ($0F-$8F entity arrays).

.const UAP_ZP_BASE              = $0f
.const uap_x_lo                 = UAP_ZP_BASE               // [UAP_MAX] 8.8 position x.
.const uap_x_hi                 = uap_x_lo    + UAP_MAX
.const uap_y_lo                 = uap_x_hi    + UAP_MAX     // 8.8 position y.
.const uap_y_hi                 = uap_y_lo    + UAP_MAX
.const uap_vx_lo                = uap_y_hi    + UAP_MAX     // 8.8 signed velocity.
.const uap_vx_hi                = uap_vx_lo   + UAP_MAX
.const uap_vy_lo                = uap_vx_hi   + UAP_MAX
.const uap_vy_hi                = uap_vy_lo   + UAP_MAX
.const uap_state                = uap_vy_hi   + UAP_MAX
.const uap_drawn_x              = uap_state   + UAP_MAX     // last rendered position
                                                            // (overlap-safe erase).
.const uap_drawn_y              = uap_drawn_x + UAP_MAX
.const uap_revec                = uap_drawn_y + UAP_MAX     // frames until the next random
                                                            // re-vector. While a UAP is CRASHED,
                                                            // this same byte is reused as the
                                                            // 1000 ms ground-burn dwell countdown
                                                            // (idle when not flying).
.const UAP_ZP_END               = uap_revec   + UAP_MAX

.errorif (UAP_ZP_END > $90), "UAP zero-page state overflows the entity-array region"

//==============================================================================
// Constants — Runtime Difficulty
//==============================================================================

// Highest active UAP slot (= active count - 1, range 0..UAP_MAX-1). Using
// the top index (not the count) keeps every `ldx #UAP_COUNT-1` loop a
// byte-neutral `ldx uap_top`. NOT in init_zp_state's zeroed range ($02-$9B);
// uap_init sets it explicitly (and on restart). No KERNAL runs after boot,
// so it is stable through gameplay.

.const uap_top                  = $a2
.const UAP_START_TOP            = 0                         // game starts with 1 active UAP
                                                            // (slot 0); difficulty grows it.
