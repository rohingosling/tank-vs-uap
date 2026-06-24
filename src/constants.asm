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
//   constants.asm. shared hardware registers, memory map, and tunable game
//   constants.
//
//   Single source of truth, imported by every module (#importonce). These
//   values encode the memory map, the zero-page plan, and the hardware
//   truths the VIC-20 imposes.
//
//*******************************************************************************

#importonce

//------------------------------------------------------------------------------
// VIC-I registers.
//------------------------------------------------------------------------------

.const VIC_RASTER               = $9004         // Raster line, bits 8-1 (non-destructive read).
.const VIC_MEMORY_POINTERS      = $9005         // Charset / screen address selector.
.const VIC_AUX_COLOUR_VOLUME    = $900E         // Aux colour (7-4) | sound volume (3-0).
.const VIC_SCREEN_BORDER_COLOUR = $900F         // Background (7-4) | reverse (3) | border (2-0).

//------------------------------------------------------------------------------
// VIA2 ($9120) — Timer 1.
//
// Used as a free-run cycle counter for the blit benchmark (no
// interrupt yet; the continuous-mode sound IRQ arrives later).
//------------------------------------------------------------------------------

.const VIA2_TIMER1_COUNTER_LOW  = $9124         // T1C-L (reading also acknowledges the T1 flag).
.const VIA2_TIMER1_COUNTER_HIGH = $9125         // T1C-H.
.const VIA2_TIMER1_LATCH_LOW    = $9126         // T1L-L.
.const VIA2_TIMER1_LATCH_HIGH   = $9127         // T1L-H.
.const VIA2_TIMER2_COUNTER_LOW  = $9128         // T2C-L (free-run cycle counter for benchmarks;
.const VIA2_TIMER2_COUNTER_HIGH = $9129         //        T1 is busy driving the sound IRQ).
.const VIA2_AUX_CONTROL         = $912B         // ACR: bit 6 = T1 continuous, bit 5 = T2 mode.
.const VIA2_INTERRUPT_FLAGS     = $912D         // IFR.
.const VIA2_INTERRUPT_ENABLE    = $912E         // IER: write $7F to clear all, $C0 to enable T1.

//------------------------------------------------------------------------------
// VIA2 keyboard matrix (input.asm).
//
// Columns are driven on Port B (output); rows are read on Port A (input).
// Drive a column low, then a pressed key pulls its row bit low.
//------------------------------------------------------------------------------

.const VIA2_PORTB               = $9120         // Keyboard columns (output).
.const VIA2_PORTA               = $9121         // Keyboard rows (input).
.const VIA2_DDRB                = $9122         // Port B direction.
.const VIA2_DDRA                = $9123         // Port A direction.

//------------------------------------------------------------------------------
// KERNAL IRQ vector + file I/O (overlay loader).
//------------------------------------------------------------------------------

.const CINV                     = $0314         // IRQ vector (KERNAL $FF72 saves A/X/Y, jmp here).
.const KERNAL_SETLFS            = $FFBA         // Set logical file / device / secondary address.
.const KERNAL_SETNAM            = $FFBD         // Set filename (A = length, X/Y = pointer).
.const KERNAL_LOAD              = $FFD5         // Load (A = 0); carry set + A = errno on failure.

//------------------------------------------------------------------------------
// Disk code overlay (the disk-first ceiling-breaker).
//
// Loaded from the .d64 into the cassette buffer ($033C-$03FB, 192 B of free
// RAM. never used, since the game is disk-only), which holds code/data that
// would otherwise overflow the $1xxx blocks.
//------------------------------------------------------------------------------

.const OVERLAY_BASE             = $033C         // Cassette buffer start.
.const OVERLAY_TOP              = $03FB         // Last usable byte (192 B region).
.const OVERLAY2_BASE            = $0200         // BASIC input buffer start (free after SYS).
.const OVERLAY2_TOP             = $0258         // Last usable byte of the score region (~89 B).
.const OVERLAY3_BASE            = $0259         // KERNAL workspace gap, validated 2026-06-04 to
.const OVERLAY3_TOP             = $033B         //   survive boot-time KERNAL_LOAD (227 B). Loaded
                                                //   as the tail of the same .prg as the score
                                                //   overlay (zero-padded gap) so no new
                                                //   load_overlay code is needed; KERNAL_LOAD "P"
                                                //   pulls the whole thing.
.const PAGE1_BASE               = $0100         // Page-1 resident overlay ("R"): the 6502 stack
.const PAGE1_TOP                = $01D7         //   page's unused floor. The stack itself uses
                                                //   only the top of the page (~12-15 B below the
                                                //   SP = $FF reset each restart; KERNAL LOAD's own
                                                //   depth stays above ~$01E0), so $0100-$01D7 is
                                                //   safe for boot-loaded code/data. Verified
                                                //   empirically by diffing $0100-$01D7 against
                                                //   resident.prg after game-over cycles.

//------------------------------------------------------------------------------
// VIC-I sound.
//
// The four voices are consecutive, so a voice index 0-3 addresses its
// register as VIC_SOUND_BASE + index.
//------------------------------------------------------------------------------

.const VIC_SOUND_BASE           = $900A         // 0 Alto, 1 Tenor, 2 Soprano, 3 Noise.
.const VIC_VOLUME               = $900E         // Bits 0-3 global volume (bits 4-7 aux colour).

//------------------------------------------------------------------------------
// Memory map.
//------------------------------------------------------------------------------

.const BASIC_STUB_BASE          = $1001         // Load address; holds "10 SYS 4110".
.const MAIN_ENTRY               = $100E         // = 4110: where the SYS call lands.
.const CODE_LOWER_BASE          = $100E         // Lower code/data block ($100E-$13FF, ~1010 B).
.const CHARSET_BASE             = $1400         // 1 KB custom character set (128 chars × 8 bytes).
.const CODE_UPPER_BASE          = $1800         // Upper code/data block ($1800-$1DFF, 1536 B).
.const SCREEN_RAM               = $1E00         // 22 × 23 = 506 cells.
.const COLOUR_RAM               = $9600         // 506 colour nybbles (low nybble used).

//------------------------------------------------------------------------------
// Screen geometry.
//------------------------------------------------------------------------------

.const SCREEN_COLUMNS           = 22
.const SCREEN_ROWS              = 23
.const SCREEN_CELLS             = SCREEN_COLUMNS * SCREEN_ROWS  // 506.

//------------------------------------------------------------------------------
// Scoring.
//
// Two 6-digit decimal counters ([0] = MSB .. [5] = units) live in zero page:
// the current score (SCORE_DIG, reset each game) and the high score
// (HIGH_DIG, which persists across games within a session. only the
// cold-boot init_zp_state clears it). Each is DISPLAYED (digit + 1 = screen
// code) on row 0, both zero-padded to six cells: current at cols 5-10, high
// at cols 16-21. See score.asm (add_score) + update_high (tank-vs-uap.asm).
//------------------------------------------------------------------------------

// $8C-$8F is in the safe game zero-page range; $90-$97 reuses KERNAL
// I/O zero page (ST, STKEY, serial/tape timing). That is safe HERE only
// because the sole KERNAL I/O is the boot overlay load, main runs
// init_zp_state AFTER that load (clearing these), and the game does no
// further KERNAL I/O (the keyboard is read via the VIA, the IRQ is the
// custom sound ISR). Any future KERNAL call during gameplay must relocate
// these 12 bytes.

.const SCORE_DIG                = $8C           // ZP: 6 bytes, current score.
.const HIGH_DIG                 = $92           // ZP: 6 bytes, high score.
.const SCORE_DISP               = SCREEN_RAM + 0 * SCREEN_COLUMNS + 5   // $1E05, row 0, cols 5-10.
.const HIGH_DISP                = SCREEN_RAM + 0 * SCREEN_COLUMNS + 16  // $1E10, row 0, cols 16-21.
.const score_pts                = $8B           // ZP scratch (after lives at $8A).

// Entity dimensions needed by geometry constants
// before the sprite modules are imported.

.const TANK_WIDTH               = 16
.const TANK_HEIGHT              = 16

// UAP slot counts (needed by the scheduler's ENTITY_COUNT before uap.asm is
// imported).

.const UAP_MAX                  = 4             // Hard slot count (RAM sizing).
.const UAP_COUNT                = 4             // Active UAPs this build (≤ UAP_MAX).

.const BULLET_WIDTH             = 2
.const BULLET_HEIGHT            = 3

//------------------------------------------------------------------------------
// Charset slot layout.
//
// $00-$14 static glyphs, $15-$7F dynamic tile pool. POOL_SLOTS is the
// *actual* pool size (worst-case simultaneous cells); $15..$7F is the
// maximum. (History: the "LEVEL" label glyphs at $15-$18 went with the level
// system; the pool-exhaustion sentinel that then held $15 was deleted too.
// exhaustion has skipped-and-self-healed since the sentinel write was
// dropped, so the saltire glyph was dead debug weight and its slot joined
// the pool.)
//------------------------------------------------------------------------------

.const BLANK_CELL               = $00           // Charset slot 0: the blank screen cell marker.
.const POOL_FIRST_SLOT          = $15           // First dynamic pool slot (the retired sentinel's cell).

// The pool is right-sized to the gameplay simultaneous-cell worst case
// (tank + UAPs + projectiles + FX), well under the max ($15-$7F). Shrinking
// it frees the charset tail (CHARSET_TAIL_BASE onward) as code RAM -- the
// cheapest way to reclaim space.

.const POOL_LAST_SLOT           = $43           // 47 dynamic pool slots ($15-$43).
.const POOL_SLOTS               = POOL_LAST_SLOT - POOL_FIRST_SLOT + 1  // 47.

// First free byte after the (static + pool) charset data. a usable code/data
// gap up to $1800.

.const CHARSET_TAIL_BASE        = CHARSET_BASE + ( POOL_FIRST_SLOT + POOL_SLOTS ) * 8  // $1620.

//------------------------------------------------------------------------------
// Canvas play region.
//
// Moving entities stay inside rows 1-20; rows 0 (HUD) and 21 (ground) are
// static glyphs.
//------------------------------------------------------------------------------

.const CANVAS_ROW_TOP           = 1
.const CANVAS_ROW_BOTTOM        = 20
.const PROJECTILE_Y_TOP         = 8             // Pixel y of the first canvas row (row 1 × 8).
.const PROJECTILE_Y_BOTTOM      = 164           // = 168 - bomb_height; bake the constant in to avoid edge underflow.

//------------------------------------------------------------------------------
// Colours.
//------------------------------------------------------------------------------

// The 8 standard VIC-I foreground colours (low nybble of each colour-RAM
// byte).

.const COLOUR_BLACK             = 0
.const COLOUR_WHITE             = 1
.const COLOUR_RED               = 2
.const COLOUR_CYAN              = 3
.const COLOUR_PURPLE            = 4
.const COLOUR_GREEN             = 5
.const COLOUR_BLUE              = 6
.const COLOUR_YELLOW            = 7

// Per-role aliases. Re-point
// any role here to re-tune the whole palette in one place.

.const CANVAS_COLOUR            = COLOUR_WHITE  // Play area + all moving entities (rows 1-20).
.const GROUND_TILE_COLOUR       = COLOUR_GREEN  // Row 21 ground line ($0B).
.const SCORE_LABEL_COLOUR       = COLOUR_BLUE   // Row 0 "SCORE" label cells.
.const HIGH_LABEL_COLOUR        = COLOUR_BLUE   // Row 0 "HIGH" label cells.
.const LEVEL_LABEL_COLOUR       = COLOUR_BLUE   // Row 22 "LEVEL" label cells.
.const LABEL_COLON_COLOUR       = COLOUR_PURPLE  // All HUD label colons ($0D).
.const SCORE_DIGIT_COLOUR       = COLOUR_CYAN   // Row 0 current-score digits.
.const HIGH_DIGIT_COLOUR        = COLOUR_CYAN   // Row 0 high-score digits.
.const LEVEL_DIGIT_COLOUR       = COLOUR_CYAN   // Row 22 level digit.
.const LIVES_ICON_COLOUR        = COLOUR_CYAN   // Row 22 lives icons.

// $900F = $08: background black, normal (non-reverse) display, black border.

.const SCREEN_BORDER_COLOUR_VALUE  = ( COLOUR_BLACK << 4 ) | ( 1 << 3 ) | COLOUR_BLACK

// $9005 = $FD → charset @ $1400, screen @ $1E00, colour @ $9600.

.const VIC_MEMORY_POINTERS_VALUE   = $FD

//------------------------------------------------------------------------------
// Region-independent timing.
//
// Express velocities and durations in wall-clock units; resolve per-frame
// integer arithmetic at assembly time from FRAME_RATE_HZ. floor() every
// split. KickAssembler '/' is floating-point.
//------------------------------------------------------------------------------

.const FRAME_RATE_HZ            = 50            // PAL primary; NTSC build: -define FRAME_RATE_HZ=60.
.const SLOTS_PER_FRAME          = 7             // IRQ ticks per frame (the scheduler budget unit).
.const TICK_RATE_HZ             = FRAME_RATE_HZ * SLOTS_PER_FRAME  // 350 Hz PAL.
.const FRAME_CYCLES             = 22160         // PAL cycles/frame (NTSC ≈ 17040).

// VIA2 T1 continuous-mode latch: one IRQ per tick. The 6522 adds 2 cycles of
// reload overhead.

.const VIA2_T1_LATCH            = floor( FRAME_CYCLES / SLOTS_PER_FRAME ) - 2

// ms → IRQ ticks / frames; px/sec → 8.8 fixed-point per-frame delta.

.function msToTicks( ms )       { .return floor( ms * TICK_RATE_HZ / 1000 ) }
.function msToFrames( ms )      { .return floor( ms * FRAME_RATE_HZ / 1000 ) }
.function pxPerSecToDelta( v )  { .return floor( v * 256 / FRAME_RATE_HZ ) }

//------------------------------------------------------------------------------
// Upper-block RAM state map ($1800-$1DFF).
//
// Module state is uninitialised RAM (not emitted to the .prg); these are
// fixed base addresses so modules never collide. Code is placed below the
// charset (lower block) or, when it overflows, above the canvas RAM via
// UPPER_CODE_BASE.
//------------------------------------------------------------------------------

.const CANVAS_RAM_BASE          = CODE_UPPER_BASE  // $1800 (canvas scratch, ~170 B).
.const SOUND_RAM_BASE           = $18B0         // Sound voice state (~14 B).
.const RANDOM_RAM_BASE          = $18D0         // RNG state (2 B).
.const UPPER_CODE_BASE          = $1900         // Upper-block code ($1900-$1DFF free).
