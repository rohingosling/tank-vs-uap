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
//   Shared declarations (tuning + zero-page map) for the unified projectile
//   pool. Pure .const, so it emits NO bytes and can be #imported wherever a
//   proj-* code file lives (the pool is split across the charset tail + upper
//   + lower blocks to fit fragmented free RAM).
//
//*******************************************************************************

#importonce

#import "constants.asm"
#import "uap-defs.asm"                          // uap_state / uap_x_hi / uap_y_hi / UAP_STATE_* (zero bytes).

//==============================================================================
// Constants — Tuning
//==============================================================================

// Pool size and slot kinds.

.const PROJ_MAX                 = 10            // Shared pool (≤ 4 bullets + ≤ 6 bombs).
.const PROJ_FREE                = $00
.const PROJ_BULLET              = $01
.const PROJ_BOMB                = $80           // | owner UAP (0..UAP_COUNT-1).

// Integer per-frame steps. Whole pixels only. 1 px/frame = 50 px/s PAL,
// 2 = 100 px/s; sub-pixel speeds would need 8.8 fixed-point (removed for RAM).
// Bullets and bombs are independent.

.const BULLET_VY                = 2             // Up,   ~100 px/s PAL.
.const BOMB_VY                  = 1             // Down,  ~50 px/s PAL (slower than bullets).
.const BULLET_VY_UP             = ( 256 - BULLET_VY ) & $ff  // Signed-byte step.
.const BOMB_VY_DOWN             = BOMB_VY
.const BOMB_VX_DIAG             = BOMB_VY       // 45°: sideways step matches the vertical.
.const BOMB_VX_RIGHT            = BOMB_VX_DIAG
.const BOMB_VX_LEFT             = ( 256 - BOMB_VX_DIAG ) & $ff

// Bullet (tank gun).

.const TANK_Y_LOCAL             = CANVAS_ROW_BOTTOM * 8 - TANK_HEIGHT + 8  // Tank top edge (= 152).
.const GUN_X_OFFSET             = 3             // Muzzle x within the 16-px tank (facing right).
.const GUN_X_OFFSET_LEFT        = TANK_WIDTH - BULLET_WIDTH - GUN_X_OFFSET  // Mirrored muzzle facing left (= 11).
.const RELOAD_FRAMES            = msToFrames(250)  // 250 ms gun reload.
.const BULLET_Y_EXPIRE          = PROJECTILE_Y_TOP  // Expire above row 1 (spare the row-0 HUD).

// Muzzle flash (drawn by the FX engine when the gun fires). The flash window
// is 8 px wide with the barrel at its local cols 3-4, so its x = bullet x -
// MUZZLE_FLASH_GUN_X for BOTH facings (the art is symmetric): tank x facing
// right, tank x + 8 facing left. always over the muzzle. Top edge 4 px above
// the tank (rows 148-152, canvas cell rows 18-19); the bottom row's pixels
// flank the barrel bits, so plot and erase never touch the tank's pixels.

.const MUZZLE_FLASH_GUN_X       = 3             // Barrel column inside the flash window.
.const MUZZLE_FLASH_Y           = TANK_Y_LOCAL - 4  // Flash top edge (= 148).

// The bullet spawns just ABOVE the flash window (not at the barrel): the two
// must never share pixels, or the bullet's per-frame erase punches a 2-px
// hole through the flash centre (their set bits coincide at flash-local
// cols 3-4). The flash itself visually bridges the gap to the barrel; when
// the FX slot is busy (no flash drawn) the bullet briefly pops in 4 px high.
// accepted.

.const BULLET_SPAWN_Y           = MUZZLE_FLASH_Y - BULLET_HEIGHT  // = 145 (rows 145-147).

// Bomb (UAP). MAX_ACTIVE_BOMBS is a GLOBAL cap on simultaneous bombs
// (≤ UAP_COUNT): it bounds the canvas pool's peak cell demand so the
// dynamic-tile pool is not exhausted under heavy fire. It replaces the old
// per-UAP cap (the pool is global).

.const MAX_ACTIVE_BOMBS         = 3
.const BOMB_WIDTH               = 3
.const BOMB_HEIGHT              = 4
.const BOMB_ALIGN_TOL           = 6             // px window for "overhead" / "diagonal".
.const BOMB_ROLL_FRAMES         = msToFrames(200)  // Roll cadence.
.const BOMB_FIRE_CHANCE         = 180           // 180/256 ≈ 70% per roll WHEN aligned.
.const BOMB_TARGET_Y            = CANVAS_ROW_BOTTOM * 8  // Tank centre y (= 160). align/aim point.
.const BOMB_LAUNCH_X_OFF        = 7             // UAP centre (16/2) - bomb half (3/2).
.const BOMB_LAUNCH_Y_OFF        = 6
.const BOMB_Y_EXPIRE            = PROJECTILE_Y_BOTTOM  // Reach the ground → expire.
.const BOMB_X_MAX               = SCREEN_COLUMNS * 8 - BOMB_WIDTH  // Off-screen x guard (catches wrap).

// Scoring altitude bands: higher kills (lower y)
// score more. band_index (proj-lower.asm) maps y → 0 high / 1 med / 2 low; the
// per-band point tables (uap_band_points 100/50/25, bomb_band_points
// 200/100/50) live in score.asm. A bomb reaching the ground scores 0.

.const BAND_HIGH_Y              = 48            // y <  48 → high band.
.const BAND_MED_Y               = 88            // y <  88 → medium band, else low.

//==============================================================================
// Constants — Zero-Page Pool Map
//==============================================================================

// Structure-of-arrays zero-page pool. Base = $3F (= UAP_ZP_END; asserted in
// tank-vs-uap.asm); 7 bytes per slot. vy is stored per slot so the integrate
// is one uniform path. Bomb scratch + the roll timer follow.

.const PROJ_ZP_BASE             = $3f
.const proj_kind                = PROJ_ZP_BASE              // [PROJ_MAX] $00 free / $01 bullet / $80|owner.
.const proj_x                   = proj_kind + PROJ_MAX      // Integer position x.
.const proj_y                   = proj_x + PROJ_MAX         // Integer position y.
.const proj_vx                  = proj_y + PROJ_MAX         // Signed per-frame x step.
.const proj_vy                  = proj_vx + PROJ_MAX        // Signed per-frame y step.
.const proj_drawn_x             = proj_vy + PROJ_MAX        // Last rendered position (overlap-safe erase).
.const proj_drawn_y             = proj_drawn_x + PROJ_MAX
.const PROJ_ZP_END              = proj_drawn_y + PROJ_MAX

.const bomb_roll_timer          = PROJ_ZP_END               // Frames until the next bomb-roll pass.
.const bd_dx                    = bomb_roll_timer + 1       // Aim/launch scratch.
.const bd_dy                    = bd_dx + 1
.const bd_sign                  = bd_dy + 1                 // dx sign / stash.
.const bd_vx                    = bd_sign + 1               // Decided bomb x step.

// Collision scratch aliases. collide.asm and the overlay's check_bullet_bombs
// share these; collisions and bomb firing never run at the same point in the
// frame.

.const ch_px                    = bd_dx         // Bullet x.
.const ch_py                    = bd_dy         // Bullet y.
.const ch_slot                  = bd_sign       // Bullet projectile slot.
.const PROJ_ZP_SCRATCH_END      = bd_vx + 1

.errorif (PROJ_ZP_SCRATCH_END > $90), "projectile zero-page state overflows the game ZP range"
