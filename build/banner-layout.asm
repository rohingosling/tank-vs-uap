//============================================================================================
//  banner-layout.asm  --  pre-generated banner layout data. DO NOT HAND-EDIT.
//  Per-banner cell positions + sizes (id order: title, author, press, gameover, controls),
//  imported by src/screens.asm.
//============================================================================================

#import "constants.asm"

banner_name:                                 // single-char PETSCII disk names.
        .byte $54, $41, $4b, $47, $43        // T A K G C
banner_slot:                                 // first charset cell code (= load-address pool slot).
        .byte $15, $29, $32, $15, $3c
banner_cw:                                   // cells wide  (incl. any horizontal sub-cell pad).
        .byte 10, 9, 10, 8, 2
banner_ch:                                   // cells tall  (incl. any vertical sub-cell pad).
        .byte 2, 1, 1, 1, 4
banner_scr_lo:                               // screen address of the top-left cell.
        .byte <(SCREEN_RAM + 3*SCREEN_COLUMNS + 6)    // banner-title.prg: px (50,24)
        .byte <(SCREEN_RAM + 6*SCREEN_COLUMNS + 6)    // banner-author.prg: px (55,48)
        .byte <(SCREEN_RAM + 15*SCREEN_COLUMNS + 6)    // banner-press.prg: px (51,120)
        .byte <(SCREEN_RAM + 10*SCREEN_COLUMNS + 7)    // banner-gameover.prg: px (62,80)
        .byte <(SCREEN_RAM + 9*SCREEN_COLUMNS + 10)    // banner-controls.prg: px (80,72)
banner_scr_hi:
        .byte >(SCREEN_RAM + 3*SCREEN_COLUMNS + 6)
        .byte >(SCREEN_RAM + 6*SCREEN_COLUMNS + 6)
        .byte >(SCREEN_RAM + 15*SCREEN_COLUMNS + 6)
        .byte >(SCREEN_RAM + 10*SCREEN_COLUMNS + 7)
        .byte >(SCREEN_RAM + 9*SCREEN_COLUMNS + 10)
        // Guard banner_load's no-carry name-pointer calc: banner_name + max id (4) must not
        // cross a page.
        .errorif ((<banner_name) > $fb), "banner_name within 4 bytes of a page end -- banner_load name pointer would be wrong"
