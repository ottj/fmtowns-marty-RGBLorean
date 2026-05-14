; SPDX-License-Identifier: MIT
;
; int93_tsr.asm — RGBLorean IVT-hook validation harness (Phase 2 first cut)
;
; Loaded as the IO.SYS-equivalent payload (sector 1, LBA=1) on the IC
; card image card_tsr.bin. The Marty BIOS maps the card image at segment
; 0xB000 and `jmp 0xB000:0x400` directly into sector 1 — no copy to low
; RAM. See iosys_stub.asm header for the full boot model.
;
; NOTE — this is currently a **diagnostic harness**, not the production
; CD-ROM TSR. It proves three things, in order:
;
;   1. Boot-model assumption is correct (we really do execute in place
;      from the card window, CS=0xB000).
;   2. The hook code is reachable at its installed (seg:off) address
;      via a manual `retf`-based far call ("Test A" / direct path).
;   3. Software `int` instructions dispatch through the IVT to our hook
;      ("Test B" / int path) — i.e. Tsugaru does NOT trap interrupts at
;      the emulator level for the slot we install into. We currently use
;      `int 0x80` to keep the test independent of any Marty-specific
;      `int 0x93` behaviour; the real CD-ROM hook will go on 0x93 once
;      we layer the function-code decode + mailbox forwarding on top.
;
; The harness is intentionally chatty: it deposits markers all over low
; RAM (DS=0 absolute writes — those land in real RAM regardless of CS)
; so each step can be confirmed in Tsugaru with `MD 0:NNN`. Future
; iterations will strip the markers once the corresponding behaviour is
; trusted.
;
; Markers (inspect with `MD 0:600`, `MD 0:700`, …):
;
;   0x0600 "RGBLOK!\0\4\0"     boot reached entry
;   0x0700 "INT93HK\0"         install path executed
;   0x0720 AH + "HOOK"         hook fired (AH=0x77 = direct path,
;                              AH=0x99 = int path; int path runs last
;                              so 0x99 wins on success)
;   0x0730 word                CS at install time
;   0x0732 word                installed offset (= hook label, biased
;                              by org 0x400 so it matches runtime IP)
;   0x0734 word                installed segment (= CS)
;   0x0738 "PRE\0"             reached the int 0x80 test
;   0x073C "POST"              int 0x80 returned through our hook's iret
;   0x0740 dword               saved original IVT entry — Marty BIOS
;                              defaults every unused vector to a common
;                              "unhandled interrupt" stub
;   0x0750 "TESTOK\0\0"        control returned to main after int test
;   0x0764 "DA"                direct-call test (Test A) returned
;
; Diagnostic interpretation when something breaks:
;   0x0720 == 5A5A5A5A5A       hook never fired in any path → install or
;                              boot model wrong (use MD B000:0 to verify
;                              we are loaded at 0xB000 and MD B000:<off>
;                              to verify hook code is there)
;   0x0764 missing             direct-call test crashed → hook code
;                              itself broken
;   0x0764 present, 0x073C
;          missing             direct-call works but `int` dispatch
;                              fails → emulator or BIOS intercepts that
;                              IVT slot (try a different vector)

bits 16
cpu 386

org 0x400                       ; runtime IP at entry (see header note)

int93_tsr_start:

; ----------------------------------------------------------------
; Entry — RAM physical 0x400
; ----------------------------------------------------------------
entry:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x1000

    ; Marker 1: "RGBLOK!\0\4\0" + version 4
    mov word [0x600], 0x4752    ; 'R' 'G'
    mov word [0x602], 0x4C42    ; 'B' 'L'
    mov word [0x604], 0x4B4F    ; 'O' 'K'
    mov word [0x606], 0x0021    ; '!' '\0'
    mov word [0x608], 0x0004    ; stub version 4

    ; Marker 2: "INT93HK\0"
    mov word [0x700], 0x4E49    ; 'I' 'N'
    mov word [0x702], 0x3954    ; 'T' '9'
    mov word [0x704], 0x4833    ; '3' 'H'
    mov word [0x706], 0x004B    ; 'K' '\0'

    ; ----------------------------------------------------------------
    ; Save original int 0x93 vector at 0:0x0200/0x0202 to 0:0x0740/0x0742.
    ; (DS=0, so the absolute addressing below reads from linear 0x24C.)
    ; ----------------------------------------------------------------
    mov ax, [0x0200]            ; original offset
    mov [0x740], ax
    mov ax, [0x0202]            ; original segment
    mov [0x742], ax

    ; ----------------------------------------------------------------
    ; Install our hook handler at 0:0x0200 as (segment=CS, offset=hook).
    ;
    ; NASM -f bin gives `hook` its file offset; combined with our actual
    ; CS at runtime, (CS, hook) resolves to linear = CS*16 + hook =
    ; base_of_our_code + file_offset_of_hook, which is correct regardless
    ; of whether the BIOS entered us with CS=0/IP=0x400 or CS=0x40/IP=0.
    ; ----------------------------------------------------------------
    mov word [0x0200], hook      ; install offset = file offset of hook
    mov [0x0202], cs             ; install segment = our CS

    ; Diagnostic: echo back what we just installed so we can see CS and
    ; the actual offset/segment landed in the IVT.
    mov ax, cs
    mov [0x730], ax              ; 0x730 = our CS at install time
    mov ax, [0x0200]
    mov [0x732], ax              ; 0x732 = installed offset
    mov ax, [0x0202]
    mov [0x734], ax              ; 0x734 = installed segment

    ; Sentinel at 0x720-0x724 ("ZZZZZ") so we can tell if the hook ran
    ; (the hook overwrites these with 0xAH + "HOOK").
    mov word [0x720], 0x5A5A
    mov word [0x722], 0x5A5A
    mov byte [0x724], 0x5A

    ; "PRE\0" marker
    mov word [0x738], 0x5250    ; 'P' 'R'
    mov word [0x73A], 0x0045    ; 'E' '\0'

    ; ----------------------------------------------------------------
    ; Test A: bypass the `int` instruction entirely — manually set up
    ; the stack and `retf` into the hook's installed seg:off. Hook ends
    ; with `iret`, which expects flags+cs+ip — so we push them first.
    ;
    ; If the hook fires here, then the hook *code* at its installed
    ; address is reachable and works. If it doesn't, either we're not
    ; actually loaded at CS*16, or the installed seg:off is wrong.
    ; ----------------------------------------------------------------
    mov ah, 0x77                 ; AH=0x77 marks the direct-call path
    pushf
    push cs
    push word .after_direct      ; ip for hook's iret to return to
    push word [0x0202]           ; hook segment (= CS)
    push word [0x0200]           ; hook offset
    retf                         ; pops cs:ip from top → jumps to hook
.after_direct:
    mov word [0x764], 0x4144     ; "DA" — direct call returned

    sti

    ; ----------------------------------------------------------------
    ; Test B: regular `int` dispatch through IVT.
    ; ----------------------------------------------------------------
    mov ah, 0x99
    int 0x80

    ; "POST" marker if int returned
    mov word [0x73C], 0x4F50    ; 'P' 'O'
    mov word [0x73E], 0x5453    ; 'S' 'T'

    ; ----------------------------------------------------------------
    ; Hook returned. Drop "TESTOK\0\0" marker.
    ; ----------------------------------------------------------------
    mov word [0x750], 0x4554    ; 'T' 'E'
    mov word [0x752], 0x5453    ; 'S' 'T'
    mov word [0x754], 0x4B4F    ; 'O' 'K'
    mov word [0x756], 0x0000    ; '\0' '\0'

    cli
.halt:
    hlt
    jmp short .halt

; ----------------------------------------------------------------
; Hook handler — entered when something calls int 0x93. Logs AH,
; drops "HOOK" marker, IRETs. Does NOT chain (see top-of-file note).
; ----------------------------------------------------------------
hook:
    push ax
    push bx
    push ds

    xor bx, bx
    mov ds, bx                   ; DS = 0 for absolute marker writes

    mov [0x720], ah              ; log AH at 0:0x720
    mov word [0x721], 0x4F48     ; 'H' 'O'
    mov word [0x723], 0x4B4F     ; 'O' 'K'

    pop ds
    pop bx
    pop ax
    iret

; Pad to one full 1024-byte Marty sector
    times 1024 - ($ - int93_tsr_start) db 0xFF
