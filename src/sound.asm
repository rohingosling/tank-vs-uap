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
//   sound.asm. VIA2 Timer 1 IRQ + plain 4-voice sound engine.
//
//   A continuous-mode VIA2 T1 interrupt fires SLOTS_PER_FRAME times per frame
//   (~350 Hz PAL), doubling as the scheduler's budget clock. The ISR is
//   SOUND-ONLY: it touches no zero page and never scans the keyboard, so a
//   mid-blit interrupt cannot corrupt the canvas and interrupts can stay
//   enabled throughout.
//
//   Each voice steps a note sequence: a list of (register byte, ticks) pairs
//   in master_seq, terminated by a pair with ticks = 0 (which silences the
//   voice). Tone bytes are $80 | value, noise bytes $80 | colour, silence
//   $00. Long notes are split into ≤ 255-tick steps so the per-voice tick
//   counter stays a single byte. Plain 4-voice; the noise voice is shared by
//   the gun and all explosions (most-recent-wins). The tank engine is a
//   sequenced one-shot blip (sound_engine, ENGINE_BLIP_TICKS on Alto) fired
//   when a movement key (Z / C) is pressed. not a steady hum.
//
//   Placement-agnostic CODE/tables; voice state at SOUND_RAM_BASE
//   (uninitialised RAM).
//
//*******************************************************************************

#importonce

#import "constants.asm"

//==============================================================================
// Constants
//==============================================================================

//------------------------------------------------------------------------------
// Voice indices (registers are consecutive: VIC_SOUND_BASE + index).
//------------------------------------------------------------------------------

.const VOICE_ALTO               = 0
.const VOICE_TENOR              = 1
.const VOICE_SOPRANO            = 2
.const VOICE_NOISE              = 3

.const SOUND_VOLUME             = 10            // Global level 0-15 (one global volume).

//------------------------------------------------------------------------------
// Engine blip tone. Alto (lowest) voice.
//
// Lower value = lower pitch. Tunable by ear: 1 = deepest (~65 Hz), 16 = the
// original ($90). 4 is a deeper rumble. The engine is no longer a steady
// hum: it plays as a fixed ENGINE_BLIP_TICKS one-shot whenever a movement
// key (Z / C) is PRESSED (update_tank; nothing on release or while held),
// and is otherwise silent. a constant hum drowned out the other sounds.
//------------------------------------------------------------------------------

.const ENGINE_TONE_VALUE        = 4
.const ENGINE_TONE_BYTE         = $80 | ENGINE_TONE_VALUE
.const ENGINE_BLIP_TICKS        = 64            // Blip length in IRQ ticks (~183 ms at 350 Hz).

//------------------------------------------------------------------------------
// UAP dive beep. RISING Soprano warble (overlay3 `uap_dive_beep` renders;
// `uap_dive_pitch_step` in the upper block steps the pitch; hit_uap seeds it).
//
// Defined HERE (an early-imported module) NOT in overlay3: a .const defined in
// a LATER-imported module is "not yet defined" to earlier code. collide.asm
// (hit_uap) and the upper-block pitch step are imported before overlay3, so
// they could not see these if they lived there (the KickAss forward-const trap;
// same reason VIC_SOUND_* live in constants.asm).
//------------------------------------------------------------------------------

.const DIVE_BEEP_GATE_MASK      = $10           // Tick bit 4: 16 ticks = ~46 ms on, ~46 ms off.
.const DIVE_BEEP_PITCH_START    = $40           // First beep's Soprano value.
.const DIVE_BEEP_STEP           = $02           // Pitch rise per successive beep.
.const DIVE_BEEP_PITCH_INIT     = DIVE_BEEP_PITCH_START - DIVE_BEEP_STEP  // $3E: hit_uap seeds this so the first off->on edge yields $40.
.const DIVE_BEEP_PITCH_MAX      = $78           // Cap (value 120; 127 wraps to 0 on the VIC-I).

//------------------------------------------------------------------------------
// Voice state (RAM; arrays indexed by voice 0-3).
//------------------------------------------------------------------------------

.const voice_active             = SOUND_RAM_BASE        // 4 bytes: nonzero = sequencing.
.const voice_ticks              = SOUND_RAM_BASE + 4    // 4 bytes: ticks left on current step.
.const voice_seq_idx            = SOUND_RAM_BASE + 8    // 4 bytes: byte offset into master_seq.
.const sound_tick_lo            = SOUND_RAM_BASE + 12   // 16-bit free-running IRQ tick (budget clock).
.const sound_tick_hi            = SOUND_RAM_BASE + 13

//==============================================================================
// Subroutines — Sound Engine
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: sound_init
//
// Description:
//
//   Silences the voices, sets the volume, configures VIA2 Timer 1, installs
//   the ISR, and enables the IRQ.
//
// Clobbers: A, X (plus anything clobbered by overlay3_harden).
//
//------------------------------------------------------------------------------

sound_init:

    // Boot-time NMI hardening. Closes the NMI-stack-leak window for the
    // entire game, not just the restart path (enter_play). See
    // overlay3_harden for the full explanation.

    jsr overlay3_harden

    sei

    // Clear ALL 14 sound-state bytes in one indexed loop: voice_active[4] /
    // voice_ticks[4] / voice_seq_idx[4] / sound_tick_lo / sound_tick_hi are
    // declared CONSECUTIVELY at SOUND_RAM_BASE + 0..13 (above), and for
    // X = 0..3 the same pass silences the four VIC voice registers
    // ($900A-$900D, consecutive). 17 bytes vs 34 unrolled.

    lda #$00
    ldx #$0d

!clear:

    sta voice_active, x
    cpx #$04
    bcs !state+                                 // X >= 4: state byte only, no VIC register.
    sta VIC_SOUND_BASE, x

!state:

    dex
    bpl !clear-

    lda #SOUND_VOLUME
    sta VIC_VOLUME

    // VIA2 T1 continuous mode (ACR bit 6 = 1, bit 7 = 0).

    lda VIA2_AUX_CONTROL
    and #%01111111
    ora #%01000000
    sta VIA2_AUX_CONTROL

    lda #<VIA2_T1_LATCH
    sta VIA2_TIMER1_LATCH_LOW                   // Low LATCH only; the counter loads below.

    // NOTE: CINV (the IRQ vector) is set to sound_isr in main, BEFORE
    // load_overlay, so the keyboard scan can't run during the disk load and
    // corrupt the overlay3 region. It does not need to be re-set here.

    lda #$7f                                    // Clear all VIA2 interrupt enables.
    sta VIA2_INTERRUPT_ENABLE
    lda #$c0                                    // Enable Timer 1 only.
    sta VIA2_INTERRUPT_ENABLE

    lda #>VIA2_T1_LATCH                         // 6522: a T1C-H write loads the high LATCH,
    sta VIA2_TIMER1_COUNTER_HIGH                //   transfers BOTH latches into the counter
                                                //   (→ start counting), and clears the T1 flag.
                                                //   so one write replaces the old explicit
                                                //   high-latch + counter-low/high stores.

    cli
    rts

//------------------------------------------------------------------------------
//
// Subroutine: sound_isr
//
// Description:
//
//   The VIA2 T1 interrupt handler. Entered via CINV with A, X, and Y already
//   saved by the KERNAL ($FF72). Sound only. touches no zero page.
//
//   Increments the 16-bit free-running tick counter (the scheduler's budget
//   clock), then steps each active voice: when the current step's tick count
//   expires, the voice advances to the next (register byte, ticks) pair in
//   master_seq; a ticks value of 0 is the terminator and silences the voice.
//
// Clobbers: None. restores A, X, Y from the KERNAL stack frame and exits
//           via RTI.
//
//------------------------------------------------------------------------------

sound_isr:

    lda VIA2_TIMER1_COUNTER_LOW                 // ACK: reading T1C-L clears the T1 flag.

    inc sound_tick_lo
    bne !ticked+
    inc sound_tick_hi

!ticked:

    ldx #$03

!voice:

    lda voice_active, x
    beq !next+
    dec voice_ticks, x
    bne !next+

    // Current step expired → advance to the next (register byte, ticks) pair.
    // (Compact: two INCs + LDY abs,X save 1 byte over LDA/CLC/ADC/STA/TAY.)

    inc voice_seq_idx, x
    inc voice_seq_idx, x
    ldy voice_seq_idx, x
    lda master_seq + 1, y                       // Next step's ticks.
    beq !end+                                   // 0 → terminator: silence the voice.
    sta voice_ticks, x
    lda master_seq, y                           // Next step's register byte.
    sta VIC_SOUND_BASE, x

!next:

    dex
    bpl !voice-

    pla
    tay
    pla
    tax
    pla
    rti
!end:                                           // A is already $00 (the BEQ that reached here
                                                // branched on Z, so the LDA that set Z loaded
                                                // $00). STA leaves Z untouched, so the BEQ below
                                                // is taken back into !next unconditionally.
                                                // replacing the old 'jmp !next+' (saves 1 byte).
    sta VIC_SOUND_BASE, x
    sta voice_active, x
    beq !next-

//------------------------------------------------------------------------------
//
// Subroutine: sound_play
//
// Description:
//
//   Starts the sequence at master_seq offset A on voice X. Atomic with
//   respect to the ISR: interrupts are masked around the voice-state update
//   (php/sei ... plp).
//
// Parameters:
//
//   A - Byte offset of the sequence into master_seq.
//   X - Voice index (0-3).
//
// Clobbers: A, Y. X is preserved.
//
//------------------------------------------------------------------------------

sound_play:

    php
    sei
    sta voice_seq_idx, x
    tay
    lda master_seq, y                           // First register byte.
    sta VIC_SOUND_BASE, x
    lda master_seq + 1, y                       // First step's ticks.
    sta voice_ticks, x
    lda #$01
    sta voice_active, x
    plp
    rts

//------------------------------------------------------------------------------
// Per-event entry points.
//
// A columnar dispatcher table: one line per event. select the voice, select
// the sequence offset, and jump to sound_play.
//------------------------------------------------------------------------------

sound_gun:            ldx #VOICE_NOISE;    lda #seq_gun - master_seq;            jmp sound_play
sound_air_explosion:  ldx #VOICE_NOISE;    lda #seq_air_explosion - master_seq;  jmp sound_play
sound_ping:           ldx #VOICE_SOPRANO;  lda #seq_ping - master_seq;           jmp sound_play
sound_bomb_drop:      ldx #VOICE_TENOR;    lda #seq_bomb_drop - master_seq;      jmp sound_play
sound_engine:         ldx #VOICE_ALTO;     lda #seq_engine - master_seq;         jmp sound_play

// sound_bomb_ground stays removed (a grounded bomb just expires. no sound,
// and no score either), and sound_bomb_tank/seq_bomb_tank (zero callers since
// the sustained burn replaced the one-shot crack) were deleted outright to
// fund sound_game_over's silence loop below.
//
// The game-START jingle IS wired, but has no dispatcher here:
// game_start_jingle (tank-vs-uap.asm) dispatches seq_game_start inline
// (ldx/lda/jsr sound_play) and falls through into game_loop.

//------------------------------------------------------------------------------
//
// Subroutine: sound_game_over
//
// Description:
//
//   Hard-silences ALL four voices (active flags AND registers) before
//   starting the game-over jingle, so nothing leaks into it. Sequenced
//   one-shots self-terminate, but the DIRECT-WRITE voices do not: a diving
//   wreck's dive beep (uap_dive_beep's $900C Soprano write) or a grounded
//   wreck's burn hiss ($900D Noise write) holds its last level forever once
//   game-over abandons the game loop that toggles it. Per voice
//   the active flag is cleared BEFORE its register, so a mid-loop ISR pass
//   cannot re-write the register; sound_play re-arms Alto atomically
//   (php/sei).
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

sound_game_over:

    lda #$00
    ldx #$03

!silence:

    sta voice_active, x
    sta VIC_SOUND_BASE, x
    dex
    bpl !silence-

    ldx #VOICE_ALTO
    lda #seq_game_over - master_seq
    jmp sound_play

// sound_engine (the dispatcher table above) replaced the old
// sound_engine_on / sound_engine_off direct-write pair: the engine is now a
// sequenced ENGINE_BLIP_TICKS one-shot fired on a movement-key press
// (update_tank), so it self-terminates via the sequencer. no "off" routine,
// no held continuous tone, and Alto needs no hand-over from the sequencer.

//==============================================================================
// Data
//==============================================================================

//------------------------------------------------------------------------------
// master_seq. every event as (register byte, ticks) pairs, terminated by
// ticks = 0.
//
// Durations are wall-clock ms resolved to IRQ ticks at assembly time; notes
// longer than 255 ticks are split into equal steps of the same pitch.
//------------------------------------------------------------------------------

master_seq:

seq_gun:                                        // Noise crack.
    .byte $80 | 64,  msToTicks( 50 ),   $00, $00

seq_air_explosion:                              // Noise low blast.
    .byte $80 | 8,   msToTicks( 200 ),  $00, $00

seq_ping:                                       // Soprano metal ping (high: value $78 = 120).
    .byte $80 | $78, msToTicks( 10 ),   $00, $00

seq_bomb_drop:                                  // Tenor: La, Me.
    .byte $80 | 90,  msToTicks( 20 ),   $80 | 77, msToTicks( 20 ),   $00, $00

seq_game_over:                                  // Alto: Tea, Sew, Me (100 ms each), Doe (1000 ms = 2 × 500).
    .byte $80 | 94,  msToTicks( 100 ),  $80 | 85, msToTicks( 100 ),  $80 | 77, msToTicks( 100 ),  $80 | 64, msToTicks( 500 ),  $80 | 64, msToTicks( 500 ),  $00, $00

seq_game_start:                                 // Tenor: Doe, Me, Sew (100 ms each), Tea (500 ms). a rising mirror of the game-over figure.
    .byte $80 | 64,  msToTicks( 100 ),  $80 | 77, msToTicks( 100 ),  $80 | 85, msToTicks( 100 ),  $80 | 94, msToTicks( 500 ),  $00, $00

seq_engine:                                     // Alto rumble blip: Z / C key press (64 ticks ≈ 183 ms).
    .byte ENGINE_TONE_BYTE, ENGINE_BLIP_TICKS,  $00, $00

// seq_bomb_ground (4 B) + seq_bomb_tank (4 B) removed: a grounded bomb has no
// sound (and no score), and the bomb-hits-tank one-shot crack was replaced by
// the sustained burn.

.errorif (* - master_seq) > 255, "master_seq exceeds 255 bytes (voice_seq_idx is 8-bit)"
