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
//   The 3rd disk overlay, resident at $0259-$033B (227 B).
//
//   Loaded as the TAIL of the same .prg as the score overlay:
//   tank-vs-uap.asm's Overlay2 segment spans $0200-$033B contiguously (score
//   code + zero-padded gap + this file's bytes); KERNAL_LOAD of "P" pulls the
//   whole .prg in one shot, landing each byte at its assembled address.
//
//   IMPORTANT: this region overlaps KERNAL keyboard / system workspace
//   ($028D = SHFLAG, $028E = LSTSHF, the key buffer, etc.). The KERNAL
//   keyboard-scan IRQ writes those bytes. which would corrupt this code.
//   Two things keep that from happening: (1) main points CINV at the
//   (keyboard-free) sound ISR BEFORE load_overlay, so the scan can't run
//   during the disk load; (2) the game uses that same custom IRQ throughout
//   play and the restart, so the KERNAL scan never runs again.
//
//   Hosts game-state code that runs only between games (restart) or once at
//   boot (NMI hardening). not the per-frame hot path. The hot path stays in
//   the main PRG.
//
//*******************************************************************************

#importonce

#import "constants.asm"

//------------------------------------------------------------------------------
// high_save: the 6-byte high-score save buffer.
//
// Defined in tank-vs-uap.asm (resident UPPER-BLOCK RAM, not zero page).
// prepare_gameover writes it at game-over; enter_play reads it. It must be
// outside the zero-page game range because enter_play's init_zp_state wipes
// $02-$9B (including HIGH_DIG at $92-$97); the boot menu's KERNAL LOADs
// clobber that serial-load zero page too.
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
//
// Subroutine: prepare_gameover
//
// Description:
//
//   Reached by jmp from tank_game_over (collide.asm) when the last life burns
//   out. First lets the game-over jingle finish playing (its ~1.3 s of red
//   border is the game-over beat. keep it), THEN saves the LIVE high score
//   to high_save (the safe upper-block buffer) BEFORE the restart's
//   init_zp_state wipes HIGH_DIG ($92-$97), and hands off to page1_gameover
//   (resident.asm): the ZERO-DISK game-over screen. no "S" reload, no
//   banner loads, and (because "O" is therefore still resident at $033C) no
//   projectile-overlay reload on the restart either. enter_play restores
//   HIGH_DIG from high_save. Never returns here.
//
// Clobbers: not meaningful. never returns (control passes to page1_gameover).
//
//------------------------------------------------------------------------------

prepare_gameover:

    // Let the game-over jingle (seq_game_over on the Alto voice, ~1.3 s)
    // finish BEFORE the screen change: the red-border + jingle pause is the
    // game-over beat (a deliberate, specified pause). The sound ISR is still
    // running here (IRQ on, not yet sei'd), so it advances the jingle and
    // clears voice_active[Alto] (= SOUND_RAM_BASE) when the sequence hits
    // its 0-tick terminator. (Alto is the longest sound by far, so once it
    // is done every other voice is long silent too.)

!wait_jingle:

    lda SOUND_RAM_BASE                          // voice_active[VOICE_ALTO]: nonzero while
                                                // the jingle plays.
    bne !wait_jingle-

    // Save the live high score to high_save before enter_play's
    // init_zp_state wipes HIGH_DIG.

    ldx #$05

!sh:

    lda HIGH_DIG, x
    sta high_save, x
    dex
    bpl !sh-

    jmp page1_gameover                          // zero-disk game-over screen (resident.asm):
                                                // paint the resident banners, wait for a fresh
                                                // key, then enter_play.

//------------------------------------------------------------------------------
//
// Subroutine: enter_play_boot
//
// Description:
//
//   Boot-only entry to enter_play: loads the "O" projectile overlay → $033C
//   (overwriting the menu's "S" overlay) and falls through into enter_play.
//   It lives HERE, not at the end of start_menu, because the load overwrites
//   the very S overlay the menu executes from. the caller must already be
//   outside $033C-$03FB when the load runs (overlay3 is at $0259-$0313).
//   The game-over restart path jmp's straight to enter_play instead: "O" is
//   still resident there (the zero-disk game-over never reloads "S").
//
// Clobbers: not meaningful. falls into enter_play (never returns).
//
//------------------------------------------------------------------------------

enter_play_boot:

    ldx #<ovl_name
    ldy #>ovl_name
    lda #$01
    jsr load_file                               // "O" → $033C (load_file is resident in the
                                                // charset tail; CINV stays on sound_isr. no
                                                // keyboard scan. so it is safe).

    // Fall through to enter_play.

//------------------------------------------------------------------------------
//
// Subroutine: enter_play
//
// Description:
//
//   (Re)start a game: re-init state and enter the game loop. Reached via
//   enter_play_boot (above) from start_menu at boot, and by jmp from
//   page1_gameover at every game-over (the title / controls screens replay
//   is skipped for a quick turnaround). in both cases AFTER a keypress has
//   been consumed, so this does NO press-wait of its own (only the final
//   release gate before the game-start jingle + game_loop). Does NO disk
//   loads either: enter_play_boot loaded "O" → $033C at boot, and the
//   zero-disk game-over path never overwrites it, so the projectile overlay
//   is always already resident. The high score is preserved across the ZP
//   wipe via high_save. The in-flight jsr chain (abandoned on game-over) is
//   discarded via the SP reset.
//
//   The sound IRQ is masked for the whole re-init (sei ... cli): a sound ISR
//   firing mid-re-init corrupts renderer state (a hard-won lesson. do NOT
//   remove the sei/cli pair).
//
// Clobbers: not meaningful. never returns (control passes to
//           game_start_jingle, then game_loop in tank-vs-uap.asm).
//
//------------------------------------------------------------------------------

enter_play:

    // Mask interrupts and reset the stack. Keep NMI disabled (VIA1 IER), then
    // sei to mask the sound IRQ during re-init, and reset SP (the jmp here
    // abandoned the in-flight jsr chain). Do NOT clear VIA2's IER here: sei
    // already masks the sound IRQ during re-init, and clearing VIA2 IER would
    // leave the sound timer IRQ DISABLED after the cli (it is only enabled
    // once, in cold-start sound_init). so from the 2nd game on the ISR never
    // fires and sounds, once started, never advance to their terminator and
    // play forever.

    lda #$7f
    sta $911e                                   // VIA1 IER: keep NMI disabled.
    sei                                         // mask the sound IRQ during the re-init.
    ldx #$ff
    txs

    // Re-point NMINV at our clean handler (boot already did this, but the
    // restart abandons the stack, so re-assert it as belt-and-braces against
    // a stray NMI).

    lda #<overlay3_nmi_rti
    sta $0318
    lda #>overlay3_nmi_rti
    sta $0319

    // Silence sound. Write $00 to the four VIC voice registers AND zero the
    // voice-active flags (SOUND_RAM_BASE). otherwise, once the IRQ is
    // re-enabled (cli below), the sound ISR resumes sequencing the game-over
    // jingle and a voice plays forever. txa + eor #$ff yields A = $00 without
    // a literal $00 byte (X is still $FF from the txs).

    txa
    eor #$ff
    sta VIC_SOUND_BASE + 0
    sta VIC_SOUND_BASE + 1
    sta VIC_SOUND_BASE + 2
    sta VIC_SOUND_BASE + 3
    sta SOUND_RAM_BASE + 0                      // voice_active[0..3] = 0 → ISR sequences nothing.
    sta SOUND_RAM_BASE + 1
    sta SOUND_RAM_BASE + 2
    sta SOUND_RAM_BASE + 3

    // (The press-then-release any-key wait now lives in the menu, before
    // enter_play is reached; enter_play keeps only the final release gate
    // before game_loop, below.)

    // The high score was already saved to high_save (the safe upper-block
    // buffer): at game-over by prepare_gameover, or 0 at cold boot (.fill).
    // The boot menu's KERNAL LOADs clobbered HIGH_DIG's zero page ($92-$97)
    // and init_zp_state wipes it below, so we do NOT read HIGH_DIG here. we
    // wipe the ZP, then RESTORE HIGH_DIG from high_save.

    jsr init_zp_state                           // zeroes the ZP game range (incl. HIGH_DIG).

    ldx #$05

!resthigh:

    lda high_save, x
    sta HIGH_DIG, x
    dex
    bpl !resthigh-

    jsr init_video
    jsr canvas_init
    jsr draw_hud                                // redraws the HUD, incl. the high field
                                                // as "000000".
    jsr init_lives

    // Refresh the high-score DISPLAY from the restored HIGH_DIG
    // (digit + 1 = screen code), since draw_hud just reset it to zeros.

    ldx #$05

!disphigh:

    lda HIGH_DIG, x
    clc
    adc #$01
    sta HIGH_DISP, x
    dex
    bpl !disphigh-

    jsr tank_init
    jsr uap_init
    jsr proj_init

    // (init_video above already set the VIC charset/screen pointer + black
    // border, and nothing since touches $9005/$900F. so the old
    // belt-and-braces re-assert here was dropped to make room for
    // prepare_gameover under the $0314 limit.)

    // Wait for the restart key to be RELEASED before handing control to the
    // game. The "any key" that started this game is still held here; without
    // this wait, the first scan_keys would see it and. if it was B (fire).
    // launch a bullet on frame 1. The fresh game is already drawn (above), so
    // it just shows until the player lets go.

!waitrelease:

    jsr restart_key_down
    bne !waitrelease-

    cli                                         // re-enable the sound IRQ (the jingle needs
                                                // the ISR).
    jmp game_start_jingle                       // play the game-start jingle over the frozen
                                                // field, then fall through into game_loop
                                                // (tank-vs-uap.asm).

//------------------------------------------------------------------------------
//
// Subroutine: restart_key_down
//
// Description:
//
//   ANY-key test. Drive ALL keyboard columns low and read the rows: with no
//   key down every row floats high ($FF); any pressed key pulls its row low.
//   (VIA2 PORTA is purely the 8 keyboard rows on the VIC-20.) Leaves
//   PORTB = $00; the game's scan_keys re-drives column 4 on the next frame,
//   so no lasting effect.
//
// Outputs:
//
//   A - Non-zero (Z clear) if any key is down.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

restart_key_down:

    lda #$00
    sta VIA2_PORTB                              // drive all columns low.
    lda VIA2_PORTA                              // read rows ($FF = nothing pressed).
    eor #$ff                                    // → non-zero if any row is low (any key down).
    rts

//------------------------------------------------------------------------------
//
// Subroutine: overlay3_nmi_rti
//
// Description:
//
//   Do-nothing NMI handler, installed at NMINV ($0318) by overlay3_harden
//   (boot) and re-asserted in enter_play. Stops a stray RESTORE (or any
//   VIA1-mediated NMI) from dropping the player into BASIC. KERNAL's NMI
//   dispatcher pushes A, X, Y before JMP-ing through NMINV, so we pop those
//   3 bytes before RTI.
//
//------------------------------------------------------------------------------

overlay3_nmi_rti:

    pla                                         // discard KERNAL's pushed Y.
    pla                                         // discard KERNAL's pushed X.
    pla                                         // discard KERNAL's pushed A.
    rti                                         // pop status + PC (the HW-pushed values).

//------------------------------------------------------------------------------
//
// Subroutine: overlay3_harden
//
// Description:
//
//   One-shot NMI hardening, called once at boot from sound_init. Silences
//   VIA1 (the NMI source) and points NMINV at overlay3_nmi_rti, so a
//   RESTORE-key NMI during play can't drop the player to BASIC.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

overlay3_harden:

    lda #$7f                                    // clear all VIA1 enable bits → deassert the
                                                // NMI line.
    sta $911e
    lda #<overlay3_nmi_rti
    sta $0318
    lda #>overlay3_nmi_rti
    sta $0319
    rts

//------------------------------------------------------------------------------
//
// Subroutine: uap_dive_beep
//
// Description:
//
//   RISING metallic beep while a shot-down UAP DIVES to the ground. Each
//   successive beep steps UP in pitch: a per-dive accumulator (uap_vx_lo[x],
//   reused scratch during the dive) starts at DIVE_BEEP_PITCH_START ($40) and
//   rises by DIVE_BEEP_STEP on every new beep, capped at DIVE_BEEP_PITCH_MAX
//   ($78). The stepping (on each beep's off->on edge) is done by
//   uap_dive_pitch_step (upper block); THIS routine only gates and renders.
//
//   The on/off warble is the RAM-free power-of-2 trick: ONE bit of the
//   free-running 350 Hz IRQ tick (DIVE_BEEP_GATE_MASK bit 4 = 16 ticks ~46 ms
//   on / off; NO timer, NO zero page; the half-period is tunable only in
//   power-of-2 ticks. bit 5 = ~91 ms, bit 3 = ~23 ms). Called every DIVING
//   frame from uap_dive_step (uap-dive.asm); the per-dive pitch is seeded in
//   hit_uap (collide.asm). Silenced when the dive ends (ground crash or tank
//   crash); the ground burn that follows is a steady Noise hiss, not this beep.
//   Lives here in overlay3 (resident); the sequencer leaves Soprano alone
//   between bomb-intercept pings, so the direct $900C writes hold (a rare ping
//   during a dive briefly shares the voice). (Place BELOW the $0314 boot-load
//   limit. see the note at the end of this file.)
//
// Clobbers: A, Y (X is preserved).
//
//------------------------------------------------------------------------------

// DIVE_BEEP_* constants live in sound.asm (an early-imported module) so the
// charset-tail / upper-block users (collide.asm, uap_dive_pitch_step) can
// reference them. see the note there.

uap_dive_beep:

    jsr uap_dive_pitch_step                     // step the per-dive pitch on a new beep's edge
                                                //   (uap_vx_lo[x]; upper block). Preserves X.
    lda sound_tick_lo
    and #DIVE_BEEP_GATE_MASK                    // gate bit 4: $00 (off) or $10 (on).
    beq !silence+                               // off half-period → silence (A = $00).
    lda uap_vx_lo, x                            // on half → the current rising pitch value.
    ora #$80                                    // enable bit → $80 | pitch.

!silence:

    sta VIC_SOUND_BASE + VOICE_SOPRANO
    rts

//------------------------------------------------------------------------------
//
// Subroutine: uap_crash_end
//
// Description:
//
//   End of a UAP's ground burn: silence the burn hiss (Noise), then respawn
//   the UAP off-screen. Tail-jmps to uap_reset_offscreen (X = slot,
//   preserved). (The dive beep on Soprano was already silenced when the dive
//   ended. see uap_dive_step.)
//
// Clobbers: A (X = the slot is preserved into uap_reset_offscreen).
//
//------------------------------------------------------------------------------

uap_crash_end:

    lda #$00
    sta VIC_SOUND_BASE + VOICE_NOISE
    jmp uap_reset_offscreen

//------------------------------------------------------------------------------
// NOTE: do NOT grow this overlay past $0313.
//
// The Overlay2 .prg is KERNAL-LOADed to $0200 at boot; any byte at $0314+
// overwrites live KERNAL vectors used DURING that load. CINV ($0314, the
// IRQ vector main just pointed at sound_isr) and the I/O vectors incl.
// ILOAD ($0330). crashing the load itself. (F6's update_difficulty lives
// in the resident $18D2 gap instead; see tank-vs-uap.asm.)
//------------------------------------------------------------------------------
