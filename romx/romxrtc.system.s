;;; ROMX ProDOS RTC Driver
;;; Based on:
;;; * Ver 0.91
;;; * Ver 0.92 Added ZIP slowdowns - 11-Aug-2021 -
;;; Modifications by Joshua Bell inexorabletash@gmail.com
;;; * Converted to ca65 syntax and adapted to driver wrapper.
;;; * Driver core rewritten to ensure that $220 and up are saved/restored.

        .setcpu "6502"
        .linecont +
        .feature string_escapes

        .include "apple2.inc"
        .include "apple2.mac"
        .include "opcodes.inc"

        .include "../inc/apple2.inc"
        .include "../inc/macros.inc"
        .include "../inc/prodos.inc"

;;; Uncomment the following to "fake" a clock with a fixed date.
;;; Used for testing without a real ROMX around.
;;; FAKE_CLOCK = 1

;;; ************************************************************
        .include "../inc/driver_preamble.inc"
;;; ************************************************************

ZipSlo        :=  $C0E0       ; ZIP CHIP slowdown

;;; ROMX locations
FWReadClock   :=  $D8F0       ; Firmware clock driver routine
SigCk         :=  $DFFE       ; ROMX sig bytes
SEL_MBANK     :=  $F851       ; Select Main bank reg

;;; ============================================================
;;;
;;; Driver Installer
;;;
;;; ============================================================

        .define PRODUCT "ROMX Clock"

;;; ============================================================
;;; Ensure there is not a previous clock driver installed.

.proc maybe_install_driver
        lda     MACHID
        and     #$01            ; existing clock card?
        beq     detect_romx     ; nope, check for ROMX

        rts                     ; yes, done!
.endproc

;;; ------------------------------------------------------------

.proc detect_romx
        ;; Preserve date/time
        ldy     #3              ; copy 4 bytes
:       lda     DATELO,y
        sta     saved,y
        dey
        bpl     :-

.ifndef FAKE_CLOCK
        ;; Try to detect ROMX and RTC
        bit     ROMIN2          ; enable ROM
        bit     ZipSlo          ; disable ZIP
        bit     $FACA           ; enable ROMXe, temp bank 0
        bit     $FACA
        bit     $FAFE

        lda     SigCk           ; Check for ROMX signature bytes
        cmp     #$4A
        bne     not_found
        lda     SigCk+1
        cmp     #$CD
        bne     not_found
        lda     FWReadClock     ; is RTC code there?
        cmp     #$AD
        php
        bit     SEL_MBANK       ; restore original bank
        plp
        bne     not_found
.endif
        jmp     install_driver  ; found clock!

not_found:
        ;; Restore date/time
        ldy     #3
:       lda     saved,y
        sta     DATELO,y
        dey
        bpl     :-

        ;; Show failure message
        jsr     log_message
        scrcode PRODUCT, " - Not Found."
        .byte   0

        rts

saved:  .byte   0, 0, 0, 0
.endproc

;;; ------------------------------------------------------------
;;; Install ROMX RTC Driver. Copy into address at DATETIME vector,
;;; update the vector and update MACHID bits to signal a clock
;;; is present.

.proc install_driver
        ptr := $A5

        ;; Update absolute addresses within driver
        lda     DATETIME+1
        sta     ptr
        lda     DATETIME+2
        sta     ptr+1

        lda     ptr
        clc
        adc     RELOC1
        sta     RELOC1
        lda     ptr + 1
        adc     RELOC1 + 1
        sta     RELOC1 + 1

        lda     ptr
        clc
        adc     RELOC2
        sta     RELOC2
        lda     ptr + 1
        adc     RELOC2 + 1
        sta     RELOC2 + 1

        ;; Copy driver into appropriate bank
        lda     RWRAM1
        lda     RWRAM1
        ldy     #ClockDrvSize-1

loop:   lda     ClockDrv,y
        sta     (ptr),y
        dey
        bpl     loop

        ;; Set the "Recognizable Clock Card" bit
        lda     MACHID
        ora     #$01
        sta     MACHID

        lda     #OPC_JMP_abs
        sta     DATETIME

        ;; Invoke the driver to init the time
        jsr     DATETIME

        lda     ROMIN2

        ;; Display success message
        jsr     log_message
        scrcode PRODUCT, " - "
        .byte   0

        ;; Display the current date
        jsr     cout_date

        rts                     ; done!
.endproc

;;; ============================================================
;;; ROMX RTC driver - Relocated into ProDOS clock driver space
;;; ============================================================

;;; The first ~$20 bytes of $200 (input buffer) are safe to
;;; overwrite. They are also used by the built-in Thunderclock
;;; slot-clock driver in ProDOS ($200-$20C).

StubLoc       :=  $0200       ; RAM stub for ROMX (<$20 bytes)

;;; ROMX Firmware writes RTC data into this fixed location.
;;; It risks conflicting with some applications (e.g. A2DeskTop),
;;; so the data is saved/restored around clock reads.

RTC_BUF       :=  $02B0

ClockDrv:
        ;; --------------------------------------------------
        ;; Enter driver

        php
        sei

        ;; --------------------------------------------------
        ;; Copy the stub to RAM, and preserve RTC_BUF

        ldx     #RamStubEnd-RamStub-1 ; copy stub to RAM
        RELOC1 := *+1
:       lda     RamStub - ClockDrv,x ; self-modified during relocation
        sta     StubLoc,x
        lda     RTC_BUF,x       ; save `RTC_BUF` too (way more than needed)
        pha
        dex
        bpl     :-

        ;; --------------------------------------------------
        ;; Read the clock into `RTC_BUF`

        jsr     StubLoc

        ;; --------------------------------------------------
        ;; Strip non-number bits, convert decimal to binary, push to stack

        ldy     #6
bufloop:
        lda     RTC_BUF,y

        RELOC2 := *+1
        and     MaskTable-1 - ClockDrv,y ; self-modified during relocation

        ;; BCD to Binary
        ;; On entry, A=BCD value &00-&99
        ;; On exit,  A=binary value 0-99
        ldx     #$FF            ; Start with result=-1
        sec                     ; Prepare for subtraction
        sed                     ; Switch to Decimal arithmetic
:       inx                     ; Add 1 to result
        sbc     #1              ; Subtract 1 with BCD arithmetic
        bcs     :-              ; Loop until BCD value < 0
        cld                     ; Switch back to Binary arithmetic
        txa                     ; return in A

        ;; Push to stack
        pha
        dey
        bne     bufloop         ; 6..1

        ;; --------------------------------------------------
        ;; Pull and place values into ProDOS time locations

        ;; (`RTC_BUF`+0 is not pushed)

        pla                     ; `RTC_BUF`+1 = minute
        sta     TIMELO

        pla                     ; `RTC_BUF`+2 = hour
        sta     TIMEHI

        pla                     ; `RTC_BUF`+3 = weekday (unused)

        pla                     ; `RTC_BUF`+4 = day
        sta     DATELO

        pla                     ; `RTC_BUF`+5 = month
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a               ; MSB will merge into DATEHI
        ora     DATELO          ; merge with day
        sta     DATELO

        pla                     ; `RTC_BUF`+6 = year
        sta     DATEHI
        rol     DATEHI          ; merge with MSB from month

        ;; --------------------------------------------------
        ;; Restore what was originally at `RTC_BUF`

        ldx     #0
:       pla
        sta     RTC_BUF,x
        inx
        cpx     #RamStubEnd-RamStub
        bne     :-

        ;; --------------------------------------------------
        ;; Exit driver

        plp
        rts

MaskTable:
        .byte   $7f, $3f, $07, $3f, $1f, $ff
        ;; .... min  hour wkdy date mnth year (`RTC_BUF` bytes 1..6)

RamStub:
.ifndef FAKE_CLOCK
        ;; Really read the ROMX RTC

        bit     ROMIN2          ; enable ROM
        bit     ZipSlo          ; disable ZIP
        bit     $FACA           ; enable ROMXe, temp bank 0
        bit     $FACA
        bit     $FAFE
        jsr     FWReadClock     ; Call ROMX to read clock
        bit     SEL_MBANK       ; restore original bank
        bit     LCBANK1         ; restore LC w/write
        bit     LCBANK1
.else
        ;; No ROMX RTC around? Provide fake data for testing.
        ;; October 5, 2021 12:34:56

        lda     #$56            ; sec
        sta     RTC_BUF+0
        lda     #$34            ; min
        sta     RTC_BUF+1
        lda     #$12            ; hr
        sta     RTC_BUF+2
        lda     #$05            ; date
        sta     RTC_BUF+4
        lda     #$10            ; month
        sta     RTC_BUF+5
        lda     #$21            ; year
        sta     RTC_BUF+6
.endif

        rts
RamStubEnd := *
        .assert RamStubEnd - RamStub < $20, error, "Stub too long"

ClockDrvEnd := *
ClockDrvSize = ClockDrvEnd - ClockDrv

        .assert ClockDrvSize <= 125, error, \
            .sprintf("Clock driver must be <= 125 bytes, was %d bytes", ClockDrvSize)

;;; ************************************************************
        .include "../inc/driver_postamble.inc"
;;; ************************************************************
