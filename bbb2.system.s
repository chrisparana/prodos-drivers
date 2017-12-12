;;; Disassembly of BYE.SYSTEM (Bird's Better Bye)
;;; Additions by Joshua Bell inexorabletash@gmail.com

        .setcpu "65C02"
        .include "apple2.inc"
        .include "prodos.inc"

        .feature c_comments

;;; Miscellaneous

COL80HPOS       := $57B

;;; I/O Soft Switches / Firmware

RAMRDOFF        := $C002        ; If 80STORE Off: Read Main Mem $0200-$BFFF
RAMRDON         := $C003        ; If 80STORE Off: Read Aux Mem $0200-$BFFF
RAMWRTOFF       := $C004        ; If 80STORE Off: Write Main Mem $0200-$BFFF
RAMWRTON        := $C005        ; If 80STORE Off: Write Aux Mem $0200-$BFFF
ALTZPOFF        := $C008        ; Main Stack and Zero Page
ALTZPON         := $C009        ; Aux Stack and Zero Page
ROMINNW         := $C082        ; Read ROM; no write
ROMINWB1        := $C089        ; Read ROM; write RAM bank 1

SLOT3           := $C300

;;; Monitor

SETTXT          := $FB39
TABV            := $FB5B
SETPWRC         := $FB6F
BELL1           := $FBDD
HOME            := $FC58
COUT            := $FDED
SETINV          := $FE80
SETNORM         := $FE84

;;; ASCII/Key codes
ASCII_TAB       := $9
ASCII_DOWN      := $A           ; down arrow
ASCII_UP        := $B           ; up arrow
ASCII_CR        := $D
ASCII_RIGHT     := $15          ; right arrow
ASCII_SYN       := $16          ; scroll text window up
ASCII_ETB       := $17          ; scroll text window down
ASCII_EM        := $19          ; move cursor to upper left
ASCII_ESCAPE    := $1B

;;; ------------------------------------------------------------

.define HI(char)        (char|$80)

.macro  HIASCII arg
        .repeat .strlen(arg), i
        .byte   .strat(arg, i) | $80
        .endrep
.endmacro

.macro  HIASCIIZ arg
        HIASCII arg
        .byte   0
.endmacro


;;; ------------------------------------------------------------

;;; ProDOS Technical Reference Manual, 5.1.5.2:
;;;
;;; ProDOS MLI call $65, the QUIT call, moves addresses $D100 through
;;; $D3FF from the second 4K bank of RAM of the language card to
;;; $1000, and executes a JMP to $1000. What initially resides in that
;;; area is Apple's dispatcher code.

;;; ------------------------------------------------------------
;;; Entry point
;;; ------------------------------------------------------------

        ;; Loads at $2000 but executed at $1000.

        .org    $2000

        jmp     install_and_quit
        install_src := *

;;; ------------------------------------------------------------
;;; Selector
;;; ------------------------------------------------------------

        .org    $1000
.proc bbb

        prefix  := $280         ; length-prefixed

        filenames       := $1400 ; each is length + 15 bytes
        read_buffer     := $2000 ; Also, start location for launched SYS files

        entry_pointer   := $60  ; 2 bytes
        block_entries   := $62
        active_entries  := $63  ; 2 bytes

        next_device_num := $65  ; next device number to try

        current_entry   := $67  ; index of current entry
        num_entries     := $68  ; length of |filenames|
        curr_len        := $69  ; length of current entry name
        curr_ptr        := $6C  ; address of current entry name (in |filenames|)

        prefix_depth    := $6B  ; 0 = root

        entry_length    := $6E
        entries_per_block := $6F
        file_count      := $70  ; 2 bytes

        entry_num       := $72
        page_start      := $73  ; index of first entry shown on screen

        max_entries     := 128  ; max # of entries; more are ignored
        types_table     := $74  ; high bit clear = dir, set = sys

        top_row         := 2    ; first row used on screen
        bottom_row      := 21   ; last row used on screen

;;; ------------------------------------------------------------

        cld                     ; ProDOS protocol for QUIT routine
        lda     ROMINNW         ; Page in ROM for reads, writes ignored

        lda     #$A0
        jsr     SLOT3           ; Activate 80-Column Firmware

        ;; Update system bitmap
        ldx     #BITMAP_SIZE-1  ; zero it all out
:       stz     BITMAP,x
        dex
        bpl     :-
        inc     BITMAP+BITMAP_SIZE-1 ; protect ProDOS global page
        lda     #%11001111           ; protect zp, stack, text page 1
        sta     BITMAP

        ;; Find device
        lda     DEVCNT          ; max device num
        sta     next_device_num
        lda     DEVNUM
        bne     check_device

next_device:
        ldx     next_device_num
        lda     DEVLST,x
        cpx     #1
        bcs     :+
        ldx     DEVCNT
        inx
:       dex
        stx     next_device_num

check_device:
        sta     on_line_params_unit
        MLI_CALL ON_LINE, on_line_params
        bcs     next_device

        stz     prefix_depth
        lda     prefix+1
        and     #$0F
        beq     next_device
        adc     #2
        tax

        ;; Resize prefix to length x and open the directory for reading
.proc resize_prefix_and_open
        stx     prefix
        lda     #'/'
        sta     prefix+1        ; ensure prefix is at least '/'
        sta     prefix,x        ; and ends with '/'
        stz     prefix+1,x      ; and is null terminated

        stz     num_entries

;;; From ProDOS Technical Reference Manual B.2.5
;;;
;;; Open(DirPathname, Refnum);               {Get reference number    }

        jsr     do_open
        bcc     :+

        ;; Open failed
fail:   lda     prefix_depth    ; root?
        beq     next_device
        jsr     pop_prefix      ; and go up a level
        bra     resize_prefix_and_open

        ;; Open succeeded
:       inc     prefix_depth

;;; ThisBlock       := Read512Bytes(RefNum); {Read a block into buffer}

        stz     read_params_request
        lda     #2
        sta     read_params_request+1
        jsr     do_read
        bcs     fail

;;; EntryLength     := ThisBlock[$23];       {Get directory info      }
;;; EntriesPerBlock := ThisBlock[$24];
;;; FileCount       := ThisBlock[$25] + (256 * ThisBlock[$26]) ;

        ;; Store entry_length (byte), entries_per_block (byte), file_count (word)
        ldx     #3
:       lda     read_buffer + DirectoryHeader::entry_length,x
        sta     entry_length,x
        dex
        bpl     :-

;;; EntryPoint      := EntryLength + $04;         {Skip header entry}
        clc
        lda     #<(read_buffer+4)
        adc     entry_length
        sta     entry_pointer
        lda     #>(read_buffer+4)
        adc     #0              ; TODO: Can skip this if entry_length << 256
        sta     entry_pointer+1

;;; BlockEntries    := $02;            {Prepare to process entry two}
        lda     #2
        sta     block_entries

;;; ActiveEntries   := $00;            {No active entries found yet }
        ;; just decrement file_count

;;; while ActiveEntries < FileCount do begin
        lda     file_count
        ora     file_count+1
        beq     close_dir

while_loop:

;;;      if ThisBlock[EntryPointer] <> $00 then begin  {Active entry}

        lda     (entry_pointer)
        beq     done_entry

;;;           ProcessEntry(ThisBlock[EntryPointer]);

        ;; Check file type
        ldy     #FileEntry::file_type
        lda     (entry_pointer),y
        cmp     #FileType::Directory
        beq     :+
        cmp     #FileType::System
        bne     finish_entry
:

        ;; Store type
        ldx     num_entries
        sta     types_table,x

        ;; Copy name
        jsr     update_curr_ptr
        ldy     #15           ; name length (length byte copied too)
:       lda     (entry_pointer),y
        sta     (curr_ptr),y
        dey
        bpl     :-
        iny                     ; Y = 0
        and     #%00001111      ; mask off name length (remove storage_type)
        sta     (curr_ptr),y    ; store length

        inc     num_entries

;;;           ActiveEntries := ActiveEntries + $01
finish_entry:
        dec     file_count
        bpl     :+
        dec     file_count+1
:

;;;      end;

done_entry:

;;;      if ActiveEntries < FileCount then  {More entries to process}
        lda     file_count
        ora     file_count+1
        beq     close_dir

;;;           if BlockEntries = EntriesPerBlock
        lda     block_entries
        cmp     entries_per_block
        bne     next_in_block

;;;                then begin           {ThisBlock done. Do next one}
;;;                     ThisBlock    := Read512Bytes(RefNum);
        jsr     do_read
        bcs     fail

;;;                     BlockEntries := $01;
        lda     #1
        sta     block_entries

;;;                     EntryPointer := $04
        lda     #<(read_buffer+4)
        sta     entry_pointer
        lda     #>(read_buffer+4)
        sta     entry_pointer+1

;;;                end
        bra     end_while

;;;                else begin           {Do next entry in ThisBlock }
next_in_block:

;;;                     EntryPointer := EntryPointer + EntryLength;
        clc
        lda     entry_pointer
        adc     entry_length
        sta     entry_pointer
        lda     entry_pointer+1
        adc     #0
        sta     entry_pointer+1

;;;                     BlockEntries := BlockEntries + $01
        inc     block_entries

;;;                end

end_while:
        ;; Check to see if we have room
        bit     num_entries     ; max is 128
        bpl     while_loop

;;; end;

close_dir:
;;; Close(RefNum);
        MLI_CALL CLOSE, close_params
        ;; fall through
.endproc

;;; ------------------------------------------------------------

.proc draw_screen
        jsr     SETTXT          ; TEXT
        jsr     HOME            ; HOME
        lda     #23             ; VTAB 23
        jsr     TABV

        ;; Print help text
        lda     #20             ; HTAB 20
        sta     CH
        ldy     #0              ; index into string buffer
        jsr     cout_string

        ;; Draw prefix
        jsr     home
        ldx     #0
:       lda     prefix+1,x
        beq     :+
        jsr     ascii_cout
        inx
        bne     :-

:       stz     current_entry
        stz     page_start
        lda     num_entries
        beq     keyboard_loop   ; no entries (empty directory)

        row_count := $6A

        cmp     #bottom_row     ; more entries than fit?
        bcc     :+
        lda     #(bottom_row - top_row + 1)
:       sta     row_count
        lda     #2
        sta     WNDTOP
        sta     WNDLFT
        lda     #22
        sta     WNDWDTH
        sta     WNDBTM
loop:   jsr     draw_current_line
        inc     current_entry
        dec     row_count
        bne     loop
        stz     current_entry
        beq     draw_current_line_inv
.endproc

;;; ------------------------------------------------------------

        ;; Remove level from prefix; returns new length in X
.proc pop_prefix
        ldx     prefix
loop:   dex
        lda     prefix,x
        cmp     #'/'
        bne     loop
        cpx     #1
        bne     done
        ldx     prefix
done:
        ;; Fall through...
.endproc

handy_rts:
        rts

;;; ------------------------------------------------------------

.proc down_common
        lda     current_entry
        inc     a
        cmp     num_entries           ; past the limit?
        bcs     handy_rts             ; yes, just redraw
        sta     current_entry         ; go to next

        lda     CV
        cmp     #bottom_row     ; at the bottom?
        bne     handy_rts
        inc     page_start      ; yes, adjust page and
        lda     #ASCII_ETB      ; scroll screen down
        jmp     COUT            ; implicit rts
.endproc

.proc on_down
        jsr     down_common
        bra     draw_current_line_inv
.endproc

;;; ------------------------------------------------------------

.proc on_up
        ldx     current_entry
        beq     draw_current_line_inv ; first one? just redraw
        dec     current_entry         ; go to previous

        lda     CV
        cmp     #top_row        ; at the top?
        bne     draw_current_line_inv ; if not, just draw
        dec     page_start      ; yes, adjust page and
        lda     #ASCII_SYN      ; scroll screen up
        jsr     cout
        ;; fall through
.endproc

;;; ------------------------------------------------------------

.proc on_alpha
loop:   lda     KBD
        and     #$5F            ; make ASCII and uppercase
        dec     a
        ldy     #1
        cmp     (curr_ptr),y    ; key < first char ?
        bcc     draw_current_line_inv

        jsr     down_common
        jsr     draw_current_line
        bra     loop
.endproc

;;; ------------------------------------------------------------

draw_current_line_inv:
        jsr     SETINV
        jsr     draw_current_line
        ;; fall through

;;; ------------------------------------------------------------

.proc keyboard_loop
        lda     KBD
        bpl     keyboard_loop
        sta     KBDSTRB
        jsr     SETNORM
        ldx     num_entries
        beq     :+              ; no up/down/return if empty

        pha
        jsr     draw_current_line
        pla

        cmp     #HI(ASCII_CR)
        beq     on_return
        cmp     #HI(ASCII_DOWN)
        beq     on_down
        cmp     #HI(ASCII_UP)
        beq     on_up

        cmp     #HI('A')
        bcs     on_alpha

:       cmp     #HI(ASCII_TAB)
        beq     next_drive
        cmp     #HI(ASCII_ESCAPE)
        bne     keyboard_loop
        ;; fall through
.endproc

;;; ------------------------------------------------------------

.proc on_escape
        jsr     pop_prefix      ; leaves length in X
        dec     prefix_depth
        bra     resize_prefix_and_open_jmp
.endproc

;;; ------------------------------------------------------------

next_drive:
        jmp     next_device

inc_resize_prefix_and_open:
        inx

resize_prefix_and_open_jmp:
        jmp     resize_prefix_and_open

;;; ------------------------------------------------------------

.proc on_return
        MLI_CALL SET_PREFIX, set_prefix_params
        bcs     next_drive
        ldx     current_entry
        jsr     update_curr_ptr

        ldx     prefix
:       iny
        lda     (curr_ptr),y
        inx
        sta     prefix,x
        cpy     curr_len
        bcc     :-
        stx     prefix

        ldy     current_entry
        lda     types_table,y
        bpl     inc_resize_prefix_and_open ; is directory???
        ;; nope, system file, so...

        ;; fall through
.endproc

;;; ------------------------------------------------------------

.proc launch_sys_file
        jsr     SETTXT
        jsr     HOME
        lda     #HI(ASCII_RIGHT) ; Right arrow ???
        jsr     COUT

        jsr     do_open
        bcs     next_drive
        lda     #$FF            ; Load up to $FFFF bytes
        sta     read_params_request
        sta     read_params_request+1
        jsr     do_read
        php
        MLI_CALL CLOSE, close_params
        plp
        bcs     next_drive
        jmp     read_buffer     ; Invoke the loaded code
.endproc

;;; ------------------------------------------------------------

.proc cout_string
loop:   lda     help_string,y
        beq     handy_rts2
        jsr     COUT
        iny
        bra     loop
.endproc

;;; ------------------------------------------------------------

;; Compute address/length of curr_ptr/curr_len
;; Call with entry index in X. Returns with Y = 0

.proc update_curr_ptr
        stz     curr_ptr+1
        txa
        asl     a
        rol     curr_ptr+1
        asl     a
        rol     curr_ptr+1
        asl     a
        rol     curr_ptr+1
        asl     a
        rol     curr_ptr+1
        sta     curr_ptr
        lda     #>filenames
        clc
        adc     curr_ptr+1
        sta     curr_ptr+1
        ldy     #0
        lda     (curr_ptr),y
        sta     curr_len
.endproc

handy_rts2:
        rts

;;; ------------------------------------------------------------

.proc draw_current_line
        lda     #2              ; hpos = 2
        sta     COL80HPOS

        ldx     current_entry   ; vpos = entry - page_start + 2
        txa
        sec
        sbc     page_start
        inc     a
        inc     a
        jsr     TABV

        lda     types_table,x
        bmi     name            ; is sys file?

        ;; Draw folder glyph
        stz     COL80HPOS
        lda     INVFLG
        pha
        ldy     #(folder_string - string_start) ; Draw folder glyphs
        jsr     cout_string
        pla
        sta     INVFLG

        ;; Draw the name
name:   jsr     space
        jsr     update_curr_ptr
loop:   iny
        lda     (curr_ptr),y
        jsr     ascii_cout
        cpy     curr_len
        bcc     loop

space:  lda     #HI(' ')
        bne     cout            ; implicit RTS
.endproc

home:   lda     #HI(ASCII_EM)   ; move cursor to top left

        ;; Sets high bit before calling COUT
ascii_cout:
        ora     #$80
cout:   jmp     COUT

;;; ------------------------------------------------------------

.proc do_open
        MLI_CALL OPEN, open_params
        lda     open_params_ref_num
        sta     read_params_ref_num
        rts
.endproc

.proc do_read
        MLI_CALL READ, read_params
        rts
.endproc

;;; ------------------------------------------------------------

        string_start := *
.proc help_string
        HIASCIIZ "RETURN: Select | TAB: Chg Vol | ESC: Back"
.endproc

        ;; Mousetext sequence: Enable, folder left, folder right, disable
.proc folder_string
        .byte   $0F,$1B,$D8,$D9,$18,$0E
        .byte   0               ; null terminated
.endproc

;;; ------------------------------------------------------------

.proc open_params
params: .byte   3
path:   .addr   prefix
buffer: .addr   $1C00
ref_num:.byte   0
.endproc
        open_params_ref_num := open_params::ref_num

.proc close_params
params: .byte   1
ref_num:.byte   0
.endproc

.proc on_line_params
params: .byte   2
unit:   .byte   $60
buffer: .addr   prefix+1
.endproc
        on_line_params_unit := on_line_params::unit

.proc set_prefix_params
params: .byte   1
path:   .addr   prefix
.endproc

.proc read_params
params: .byte   4
ref_num:.byte   1
buffer: .word   read_buffer
request:.word   0
trans:  .word   0
.endproc
        read_params_ref_num := read_params::ref_num
        read_params_request := read_params::request

;;; ------------------------------------------------------------

        .assert read_params::request - bbb <= $300, error, "Must fit in $300 bytes"

        .res    $13FF-*-2, 0
        .byte   $48,$AD         ; 72, 173 ???

.endproc

        .assert .sizeof(bbb) = $3FF, error, "Expected size is $3FF"

;;; ------------------------------------------------------------
;;; Installer
;;; ------------------------------------------------------------

        .org    $2402

.proc install_and_quit
        jsr     install
        MLI_CALL QUIT, params

.proc params
params: .byte   4
type:   .byte   0
res1:   .word   0
res2:   .byte   0
res3:   .addr   0
.endproc
.endproc

;;; ------------------------------------------------------------

.proc install
        src := install_src
        end := install_src + .sizeof(bbb)
        dst := $D100            ; Install location in ProDOS (bank 2)

        src_ptr := $19
        dst_ptr := $1B

        sta     ALTZPOFF
        lda     ROMIN
        lda     ROMIN
        lda     #>src
        sta     src_ptr+1
        lda     #<src
        sta     src_ptr
        lda     #>dst
        sta     dst_ptr+1
        lda     #<dst
        sta     dst_ptr

loop:   lda     (src_ptr)
        sta     (dst_ptr)
        inc     src_ptr
        bne     :+
        inc     src_ptr+1
:       inc     dst_ptr
        bne     :+
        inc     dst_ptr+1
:       lda     src_ptr+1
        cmp     #>end
        bne     loop
        lda     src_ptr
        cmp     #<end
        bne     loop
        lda     (src_ptr)       ; WTF??
        sta     (dst_ptr)
        sta     ALTZPOFF
        sta     ROMINWB1
        sta     ROMINWB1
        rts
.endproc
