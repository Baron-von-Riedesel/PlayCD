
;--- Play Audio CD with SB Cxh/Bxh commands on SoundBlaster 16.
;--- Public Domain, written by Andreas Grech.

	.286
	.model tiny
	.dosseg
	.stack 2048
	option casemap:none
	option proc:private
	.386

?SECSIZE equ 2352	;raw mode sector size
?DRIVER  equ 1		;1=support /D:xxx

VERSION textequ <"1.0">

;--- output buffer (=sample buffer) must fit in 64 kB:
;--- 65536 / 2352 = max 27 sectors;
;--- also, it must not cross a 64k border;
;--- see setupsamplebuffer() for details.

?BUFFERS equ 3	;sample buffer is a triple buffer

SAMPLEBUFFERLENGTH equ ?SECSIZE * ?BUFFERS * 4

;--- input buffer is in extended memory

INBUFSIZEKB equ 1024 ; XMS buffer's size in kB!

;--- each xms read/write has size SAMPLEBUFFERLENGTH / ?BUFFERS
;--- so the XMS ring buffer will wrap at:

INBUFSIZE equ (INBUFSIZEKB shl 10) / (SAMPLEBUFFERLENGTH / ?BUFFERS) * (SAMPLEBUFFERLENGTH / ?BUFFERS)

;--- SB defaults ( overwritten by BLASTER environment variable )
BASEADDR	EQU 220h	; base address
SBIRQ		EQU 5		; IRQ
DMALOW		EQU 1		; DMA channel
DMAHIGH 	EQU 5		; HDMA channel

MAXTRKS  equ 64	;max tracks - must be a multiple of 16

nSamplesPerSec equ 44100
wBitsPerSample equ 16

;--- CD-ROM access

IOCREAD  equ 03h     ;ioctl read cmd
READLONG equ 80h     ;read long cmd

IO_VOLSIZE   equ 8   ;ioctl get volume size
IO_DISKINFO  equ 10  ;ioctl get disk info
IO_TRKINFO   equ 11  ;ioctl get track info

HSG_MODE equ 00h
RB_MODE  equ 01h

COOKED   equ 00h
RAW      equ 01h

;--- DMA WRITE MODE
WANTEDMODE  EQU DMA_MODE_SINGLE + DMA_MODE_AUTOINIT + DMA_MODE_READ

PGMNAME textequ <"SB16CD">

BIOSTIMER equ 46Ch	; BIOS data address of current PIT value

lf equ 10

;--- structures

reqhdr  struct
len     db ?
subunit db ?
cmd     db ?
status  dw ?
res1    dd ?
res2    dd ?
reqhdr  ends

REDBOOK struct
union
	dd ?
struct
_f	db ?
_s	db ?
_m	db ?
ends
ends
REDBOOK ends

cmd03   struct      ;read ioctl
        reqhdr <>
mdesc   DB   ?      ; block devices: Media descriptor byte from BPB
taddr   DD   ?      ; Transfer address
numbyt  DW   ?      ; call: # bytes to transfer; return: # bytes transfered
cmd03   ends

cmd80   struct
        reqhdr <>
mode    db ?         ;addressing mode (0=HSG,1=red book)
address dd ?         ;transfer address
numsecs dw ?         ;number of sectors to read
stasecs REDBOOK <>   ;start of sectors to read
readmod db ?         ;00=cooked (2048),01=raw (2352)
intsize db ?         ;interleave size (no of sectors)
intskip db ?         ;interleave skip (no of sectors)
cmd80   ends

XMSBM struct	;XMS block move struct
dwSize dd ?
hSrc   dw ?
ofsSrc dd ?
hDst   dw ?
ofsDst dd ?
XMSBM ends

if ?DRIVER
DOSDRV struct
lpNext dd ?
wAttr  dw ?
wOfsStr dw ?
wOfsInt dw ?
name_  db 8 dup (?)
rsvd   db 3 dup (?)
bUnits db ?
DOSDRV ends
endif

	include dma.inc
	include sbequ.inc

;--- macros

CStr macro text:vararg
local sym
	.const
sym db text,0
	.code
	exitm <offset sym>
endm

WaitRead macro
LOCAL loopWait
	xor cx, cx
loopWait:
	in al, dx
	test al,80h
	loopzw loopWait		; Jump if bit7=0 - no data available
endm

WaitWrite macro
LOCAL loopWait
	xor cx,cx
loopWait:
	in al, dx
	test al, 80h
	loopnzw loopWait	; Jump if bit7=1 - writing not allowed
endm

WriteDSP macro Base, cmd
	mov dx, Base
	add dx, SB_DSPWRITE
	WaitWrite
	mov al, cmd
	out dx, al
endm

	.data

OldIntSB	dd 0	;old value of SB IRQ
OldInt15 dd 0	;old value of Int 15h
dwSampleBuffer	dd 0; linear address sample buffer
wData		dw MAXTRKS shr 4 dup (0) ;track type bits

wBase	dw BASEADDR
wIrq	dw SBIRQ
wDmaL	dw DMALOW
wDmaH	dw DMAHIGH
wType	dw 0
wOldMask dw 0

bSBInit	db 0
bVerbose db 1
bHelp	db 0
bPaused	db 0
bExit	db 0
if ?DRIVER
drvname db 8 dup (' '),0
bUnit   db 0
	align word
drvstr  dd 0
drvint  dd 0
endif

	align word

wDmaBaseChn dw 0
wDmaCntChn  dw 0
wDmaPageChn dw 0
wDmaWriteMask dw 0
wDmaWriteMode dw 0
wDmaClearFlipFlop dw 0
wDrive dw 0		; CD drive #
if (INBUFSIZE / ?SECSIZE) GT 0ffffh
wSecsInBuf dd 0	; current sectors in read buffer
FMTSIB textequ <"lu">
else
wSecsInBuf dw 0	; current sectors in read buffer
FMTSIB textequ <"u">
endif

xmsdrv  dd 0	; XMS driver entry
xmswrite XMSBM <SAMPLEBUFFERLENGTH / ?BUFFERS,0,0,0,0>
xmsread  XMSBM <SAMPLEBUFFERLENGTH / ?BUFFERS,0,0,0,0>
req03   cmd03 <>	;ioctl
req80   cmd80 <>	;read long

	.const

pgtab db 87h, 83h, 81h, 82h, -1, 8bh, 89h, 8ah

szHelp label byte
	db PGMNAME," v", VERSION, " - read Audio CD data and send it to the SB16.",lf
	db "Usage: ",PGMNAME," [options] [track# ...]",lf
	db " options:",lf
	db " -? : this help",lf
if ?DRIVER
	db " -d:drvname[,unit] : call CD-ROM driver directly",lf
endif
	db " -q : no displays",lf
	db "If track# is omitted, all tracks are rendered.",lf
	db "ESC exits playing, SPACE pauses.",lf
	db 0

	.code

	include printf.inc

;--- copy PCM chunk from XMS input buffer to sample buffer;
;--- called by SB IRQ handler - be careful to modify registers.

fillsamplebuffer proc uses si bx eax

	mov si, offset xmsread
	cmp wSecsInBuf, 0   ; anything in read buffer?
	jz store_silence
	mov ah, 0Bh
	call xmsdrv         ; copy block

;--- adjust src offset for next read
	mov eax, [si].XMSBM.ofsSrc
	add eax, SAMPLEBUFFERLENGTH / ?BUFFERS
	cmp eax, INBUFSIZE
	jb @F
	mov eax, 0
@@:
	mov [si].XMSBM.ofsSrc, eax
	sub wSecsInBuf, SAMPLEBUFFERLENGTH / (?BUFFERS * ?SECSIZE) ;adjust input buffer

;--- adjust dst offset for next read
adj_dst:
	mov ax, word ptr [si].XMSBM.ofsDst+0
	add ax, SAMPLEBUFFERLENGTH / ?BUFFERS
	cmp ax, SAMPLEBUFFERLENGTH
	jnz @F
	mov ax, 0
@@:
	mov word ptr [si].XMSBM.ofsDst+0, ax
	ret
store_silence:
	pusha
	push es
	les di, [si].XMSBM.ofsDst
	mov cx, ( SAMPLEBUFFERLENGTH / ?BUFFERS ) shr 1
	xor ax, ax
	cld
	rep stosw
	pop es
	popa
	jmp adj_dst

fillsamplebuffer endp

;--- SB IRQ handler

sbirqproc proc
	push ax
	push dx
	push ds
	mov ax, cs
	mov ds, ax

	sti
	call fillsamplebuffer

	mov dx, [wBase]
if 1
	mov ax, SB_DSPINTACK	; VSB is happy with 22Eh or 22Fh, but real SB needs 22Eh for 8 bit!
	cmp wDmaBaseChn, 10h
	jb @F
endif
	mov ax, SB16_DSPINTACK
@@:
	add dx, ax
	in al, dx
	mov al, 020h
	cmp [wIrq], 8
	jb @F
	out 0A0h, al
@@:
	out 020h, al
	pop ds
	pop dx
	pop ax
	IRET
sbirqproc endp

;--- copy environment variable - used for BLASTER variable

GetEnvironmentVariable proc stdcall uses es si di pVar:ptr, pOut:ptr, wSize:word

	mov ah, 51h
	int 21h
	mov es, bx
	mov es, es:[2Ch]
	xor di, di
	mov si, pVar
	mov bx, si
	.while byte ptr [bx]
		inc bx
	.endw
	sub bx, si
nextvar:
	mov cx, bx
	push si
	push di
	repz cmpsb
	jz found
skipvar:
	pop di
	pop si
	mov al, 0
	or cx,-1
	repnz scasb
	cmp byte ptr es:[di],0
	jnz nextvar
	xor ax, ax
	ret
found:
	cmp byte ptr es:[di],'='
	jnz skipvar
	add sp, 2*2
	inc di
	mov si, di
	mov di, pOut
	mov cx, wSize
	mov bx, ds
	push es
	pop ds
	mov es, bx
@@:
	lodsb
	stosb
	cmp al,0
	loopnz @B
	mov ds, bx
	mov ax, di
	sub ax, pOut
	ret
GetEnvironmentVariable endp

;--- convert string to number
;--- si:src text
;--- cl:base (10/16)
;--- out:number in EAX
;---     si -> behind number
;--- Z if no valid digit found

atoi proc uses bx
	mov bx, si
	xor edx, edx
	movzx ecx, cl
nextdigit:
	lodsb
	sub al, '0'
	jb exit
	cmp al, 9
	jbe ok
	cmp cl, 16
	jnz exit
	sub al, 7
	cmp al, 15
	ja exit
ok:
	imul edx, ecx
	movzx eax, al
	add edx, eax
	jmp nextdigit
exit:
	dec si
	mov eax, edx
	cmp si, bx
	ret
atoi endp

;--- scan BLASTER variable, overwrite
;--- default values in wBase, wIrq, wDmaL, wDmaH, wType

ScanBlasterVar proc stdcall uses si pVar:ptr
	mov si, pVar
	or bx, -1
	.while (byte ptr [si])
		lodsb
		.if (al == ' ')
			or bx,-1
			.continue
		.endif
		.if ((al >= 'a') && (al <= 'z'))
			sub al,20h
		.endif
		.if (bx == -1)
			mov cl,16
			.if (al == 'A')
				mov bx, offset wBase
			.elseif (al == 'I')
				mov bx, offset wIrq
				mov cl,10
			.elseif (al == 'D')
				mov bx, offset wDmaL
			.elseif (al == 'H')
				mov bx, offset wDmaH
			.elseif (al == 'T')
				mov bx, offset wType
			.endif
			.continue
		.endif
		dec si
		call atoi
		jz numdone
		.if (bx != -1)
			mov [bx], ax
		.endif
numdone:
	.endw
	ret
ScanBlasterVar endp

;--- send device driver request

SendReq proc stdcall uses bx req:ptr BYTE

	mov bx,req
	push ds
	pop es
if ?DRIVER
	cmp word ptr drvint+2,0
	jz @F
	mov al, bUnit
	mov [bx].reqhdr.subunit, al
	call [drvstr]
	call [drvint]
	ret
@@:
endif
	mov cx,wDrive
	clc 			;XP needs this
	mov ax,1510h	;send dev. req.
	int 2Fh
	ret

SendReq endp

;--- check CD.
;--- returns: NC: ok
;---           C: no audio CD

ioctl08 struct	;get volume size
cmd     db ?
sectors dd ?	;size in sectors
ioctl08 ends

getvolsize proc

local ctl08:ioctl08

;--- get volume size
	mov req03.len, sizeof cmd03
	mov req03.cmd, IOCREAD
	lea ax, ctl08
	mov word ptr req03.taddr+0, ax
	mov word ptr req03.taddr+2, ss
	mov req03.numbyt, sizeof ioctl08
	mov ctl08.cmd, IO_VOLSIZE	;get volume size
	mov ctl08.sectors, 0
	invoke SendReq, addr req03
	jc error
	test req03.status, 8000h
	jnz error
	mov eax, ctl08.sectors
	clc
	ret
error:
	invoke printf, CStr("IOCTL volume size: failed [%X]",lf), req03.status
	stc
	ret

getvolsize endp

ioctl10 struct	;audio disk info
cmd     db ?
first   db ?
last    db ?
leadout REDBOOK <>
ioctl10 ends

getdiskinfo proc

local ctl10:ioctl10

	mov req03.len, sizeof cmd03
	mov req03.cmd, IOCREAD
	lea ax, ctl10
	mov word ptr req03.taddr+0, ax
	mov word ptr req03.taddr+2, ss
	mov req03.numbyt, sizeof ioctl10
	mov ctl10.cmd, IO_DISKINFO
	invoke SendReq, addr req03
	jc error
	test req03.status, 8000h
	jnz error
	mov al, ctl10.first
	mov ah, ctl10.last
	mov edx, ctl10.leadout
	clc
	ret
error:
	invoke printf, CStr("IOCTL disk info: failed [%X]",lf), req03.status
	stc
	ret

getdiskinfo endp

ioctl11 struct	;audio track info
cmd     db ?
track   db ?
start   REDBOOK <>
ctlinfo db ?    ; bit 6=1 -> data track
ioctl11 ends

;--- out: eax=start sector, edx=start (MSF), cx=0 if audio, 1 if data

gettrackinfo proc stdcall track:word

local ctl11:ioctl11

	mov req03.len, sizeof cmd03
	mov req03.cmd, IOCREAD
	lea ax, ctl11
	mov word ptr req03.taddr+0, ax
	mov word ptr req03.taddr+2, ss
	mov req03.numbyt, sizeof ioctl11
	mov ctl11.cmd, IO_TRKINFO
	mov ax, track
	mov ctl11.track, al
	invoke SendReq, addr req03
	jc error
	test req03.status, 8000h
	jnz error
	mov eax, ctl11.start
	call Rb2Lba   ; convert RedBook in EAX to LBA
	mov edx, ctl11.start
	xor cx, cx
	test ctl11.ctlinfo, 40h
	jnz error2
	ret
error:
	invoke printf, CStr("IOCTL track info(%u): failed [%X]",lf), track, req03.status
	stc
	ret
error2:
	inc cx
	clc
	ret
gettrackinfo endp

;--- read CD and copy sectors to XMS input buffer
;--- out: NC: read ok

cdread proc stdcall uses si bx max:dword

	mov req80.len, sizeof cmd80
	mov req80.cmd, READLONG
	mov req80.mode, HSG_MODE
	mov eax, max
	sub eax, req80.stasecs
	jz exit
	.if eax > SAMPLEBUFFERLENGTH / (?BUFFERS * ?SECSIZE)
		mov eax, SAMPLEBUFFERLENGTH / (?BUFFERS * ?SECSIZE)
	.endif
	mov req80.numsecs, ax
	mov req80.readmod, RAW

	invoke SendReq, addr req80
	jc error
	test req80.status, 8000h
	jnz error

;--- if no full chunk was read, fill the rest with "silence"

	movzx eax, req80.numsecs
	add req80.stasecs, eax
	.if ax < SAMPLEBUFFERLENGTH / ( ?BUFFERS * ?SECSIZE)
		imul ax, ?SECSIZE
		push di
		les di, req80.address
		mov cx, SAMPLEBUFFERLENGTH / ?BUFFERS
		add di, ax
		sub cx, ax
		shr cx, 1
		xor ax, ax
		cld
		rep stosw
		pop di
;		invoke printf, CStr("read %u sectors only, rest of buffer cleared",lf), req80.numsecs
	.endif

;--- copy the sectors to XMS input buffer

	mov si, offset xmswrite
	mov ah, 0Bh
	call xmsdrv
;--- adjust offset for next write op
	mov eax, [si].XMSBM.ofsDst
	add eax, SAMPLEBUFFERLENGTH / ?BUFFERS
	cmp eax, INBUFSIZE
	jb @F
	mov eax, 0
@@:
	mov [si].XMSBM.ofsDst, eax
	add wSecsInBuf, SAMPLEBUFFERLENGTH / (?BUFFERS * ?SECSIZE)	;adjust input buffer sector count
exit:
	clc
	ret
error:
	invoke printf, CStr("Read long(%lu): failed [%X]",lf), req80.stasecs, req80.status
	stc
	ret
cdread endp

;--- set DMA registers
;--- WriteMask      DMABase + 10 * DMAWidth
;--- WriteMode      DMABase + 11 * DMAWidth
;--- ClearFlipFlop  DMABase + 12 * DMAWidth
;--- BaseChn        DMABase + DMAWidth * channel
;--- CntChn         DMABase + DMAWidth * channel + DMAWidth
;--- PageChn        channel PAGE

setdmaports proc uses ebx

	movzx ebx, wDmaH
	mov edx, 0	; edx=DMABase (0/C0)
	mov ecx, 1	; ecx=DMAWidth (1/2)
	cmp ebx, 4
	jb @F
	mov dx, 0C0h
	inc ecx
@@:
	mov eax, 10			; single mask register
	imul eax, ecx
	add eax, edx
	mov wDmaWriteMask, ax ; bits 0-1 select channel, bit 2 sets status
	mov ax, 11			; mode register
	imul eax, ecx
	add eax, edx
	mov wDmaWriteMode, ax
	mov ax, 12			; flip flop
	imul eax, ecx
	add eax, edx
	mov wDmaClearFlipFlop, ax
	mov al, [ebx+pgtab]	; al=page register
	mov ah, 0
	mov wDmaPageChn, ax
	mov eax, ebx
	and al, 3
	shl eax, 1
	imul eax, ecx
	add eax, edx
	mov wDmaBaseChn, ax	; address register
	add eax, ecx
	mov wDmaCntChn, ax	; cnt register
	ret
setdmaports endp

GetDmaChannel proc
	mov al, byte ptr wDmaH
	sub al, 4
	ret
GetDmaChannel endp

;--- setup sample buffer.
;--- will calculate linear address of sample buffer.
;--- linear address (=dwSampleBuffer) is used for DMAcontroller page & offset.
;--- out: ax=segment address of sample buffer.

setupsamplebuffer proc uses esi

;--- alloc double the size of the sample buffer;
;--- this ensures that within that chunk is a region that won't
;--- cross the 64kB barrier.
	mov bx, (SAMPLEBUFFERLENGTH * 2) shr 4
	mov ah, 48h
	int 21h
	jc memerr
	movzx eax, ax
	shl eax, 4
	mov esi, eax
	add eax, SAMPLEBUFFERLENGTH-1   ; eax -> last byte of buffer
	mov edx, esi
	shr eax, 16
	shr edx, 16
	cmp ax, dx		; 64kb segment overrun?
	jz no_overrun
	shl eax, 16		; yes - set sample buffer to start of 64k segment
	mov esi, eax
no_overrun:
	mov dwSampleBuffer, esi
	mov eax, esi
	shr eax, 4
	ret
memerr:
	invoke printf, CStr("not enough DOS memory",lf)
	stc
	ret
setupsamplebuffer endp

;--- reset SB DSP - used to check if SB exists
;--- out: NC if DSP found, C if not.

ResetDSP proc
	mov dx, [wBase]
	add dx, SB_DSPRESET
	mov al, 1
	out dx, al			; start DSP reset

	in al, dx
	in al, dx
	in al, dx
	in al, dx			; wait 3 æsec

	xor al, al
	out dx, al			; end DSP Reset

	mov dx, [wBase]
	add dx, SB_DSPSTATUS
	WaitRead
	mov dx, [wBase]
	add dx, SB_DSPREAD
	in al, dx
	cmp al, 0aah		; if there is a SB then it returns 0AAh
	je @F
	stc
	ret
@@:
	clc
	ret
ResetDSP endp

;--- read DSP - used to get the DSP version

ReadDSPWord proc stdcall bCmd:byte

	WriteDSP [wBase], bCmd
	mov dx, [wBase]
	add dx, SB_DSPSTATUS
	WaitRead
	mov dx, [wBase]
	add dx, SB_DSPREAD
	in al, dx
	mov ah, al
	mov dx, [wBase]
	add dx, SB_DSPSTATUS
	WaitRead
	mov dx, [wBase]
	add dx, SB_DSPREAD
	in al, dx
	ret

ReadDSPWord endp

;--- convert redbook address in EAX to LBA

Rb2Lba proc
	mov cx,ax		;Save "seconds" & "frames" in CX-reg.
	shr eax,16		;"minute" value to AX
	cmp ax,99		;Is "minute" value too large?
	ja error
	cmp ch,60		;Is "second" value too large?
	ja error
	cmp cl,75		;Is "frame" value too large?
	ja error

;--- convert minute value to seconds
	mov edx,60
	mul dl
	mov dl,ch		;add "second" value.
	add ax,dx		;now ax has seconds

;--- convert seconds to frames
	mov dl,75
	mul edx			;now eax has frames

	mov dl, cl
	add eax, edx	;add "frame" value

	sub eax, 2*75	;subtract 2 sec leadin

	ret
error:
	mov eax,100*60*75	;error, set value to max (450.000)
	ret
Rb2Lba endp

;--- get current PIT timer 0 value

gettimer proc uses ds
	mov ax, 0
	mov ds, ax
	mov eax, ds:[BIOSTIMER]
	ret
gettimer endp

;--- reset SB hardware

ResetSB proc
	call ResetDSP
	.if CARRY?
		invoke printf, CStr('No SoundBlaster found at 0x%x',lf), [wBase]
		stc
		ret
	.endif

;--- check if it's a SB16
	invoke ReadDSPWord, DSP_VERSION
	.if ax < 400h
		invoke printf, CStr('No SB16 found, DSP version=%X',lf), ax
		stc
		ret
	.endif
	ret
ResetSB endp

;--- init SB hardware, including ISA DMA

InitSB proc uses bx

	WriteDSP [wBase], DSP_ENABLESPEAKER
;
;--- setup isr
;
	mov al, byte ptr [wIrq]
	.if ( al < 8 )
		add al, 8
	.else
		add al, 68h
	.endif
	push es
	mov ah, 35h
	int 21h
	mov word ptr [OldIntSB+0], bx
	mov word ptr [OldIntSB+2], es
	pop es
	mov dx, offset sbirqproc
	mov ah, 25h
	int 21h
;
;--- enable sound IRQ
;
	in al, 021h
	mov ah, al
	in al, 0A1h
	xchg al,ah
	mov wOldMask, ax

	mov dx, 21h
	mov bx, [wIrq]
	cmp bx, 8
	jb @F
	mov dx, 0A1h
	sub bx, 8
@@:
	in al, dx
	btr ax, bx
	out dx, al
;
; Setup ISA DMA controller
;
; 1. Mask DMA Channel
;
	call GetDmaChannel
	or al, DMA_MASK_DISABLE_CHN	; bit 2 sets mask, bits 0-1 select channel
	mov dx, wDmaWriteMask
	out dx, al
;
; 2. Clear FlipFlop
;
	mov dx, wDmaClearFlipFlop
	out dx, al
;
; 3. Write Transfer Mode
;
	call GetDmaChannel
	or al, WANTEDMODE
	mov dx, wDmaWriteMode
	out dx, al
;
; 4. Write Page Number
;
	mov al, byte ptr [dwSampleBuffer+2]
;	cmp wDmaBaseChn, 10h
;	jb @F
;	shr eax, 1	; for 16-bit DMA, skip lowest bit
;@@:
	mov dx, wDmaPageChn
	out dx, al
;
; 5. Write Base Address
;
	mov ax, word ptr [dwSampleBuffer]
	mov dx, wDmaBaseChn
	cmp dx, 10h
	jb @F
	shr eax, 1	; for 16-bit DMA, skip lowest bit
@@:
	out dx, al
	mov al, ah
	out dx, al
;
; 6. Write Sample Length - 1
;
	mov dx, wDmaCntChn
	mov bx, SAMPLEBUFFERLENGTH
	cmp dx, 10h
	jb @F
	shr bx, 1	; for 16-bit DMA, skip lowest bit
@@:
	dec bx
	mov al, bl
	out dx, al
	mov al, bh
	out dx, al
;
; 7. Demask Channel
;
	call GetDmaChannel
	or al, DMA_MASK_ENABLE_CHN	; this is actually zero
	mov dx, wDmaWriteMask
	out dx, al
;
; Setup SoundBlaster
;
; 1. Set Samplerate
;
	WriteDSP [wBase], DSP_SETOUTSAMPLERATE
	mov bx, nSamplesPerSec
	WaitWrite
	mov al,bh
	out dx,al
	WaitWrite
	mov al,bl
	out dx,al
;
; 2. play 16bit stereo B6 30 XX XX
;
	WaitWrite
	mov ax, 030B6h				;B6,30 = DMA DAC 16bit autoinit, stereo, signed
	out dx, al
	WaitWrite
	mov al, ah					;AL = stereo signed / mono unsigned
	out dx, al
	mov bx, SAMPLEBUFFERLENGTH / ?BUFFERS
	shr bx, 1
	dec bx
	WaitWrite
	mov al, bl					; LOWER PART SAMPLELENGTH
	out dx, al
	WaitWrite
	mov al, bh					; HIGHER PART SAMPLELENGTH
	out dx, al

	mov bSBInit, 1

	clc
	ret

InitSB endp

;--- deinit SB hardware

ExitSB proc

	cmp bSBInit, 0
	jz exit    
	call ResetDSP
;--- restore PIC masks
	mov ax, wOldMask
	out 21h, al
	mov al, ah
	out 0A1h, al

;--- RESTORE IRQ
	mov al, byte ptr [wIrq]
	.if ( al < 8 )
		add al, 8
	.else
		add al, 68h
	.endif
	push ds
	lds dx, [OldIntSB]
	mov ah, 25h
	int 21h
	pop ds
exit:
	ret
ExitSB endp

if ?DRIVER

;--- store CD-ROM driver name

getdrvname proc uses di
	mov di, offset drvname
	mov cx, sizeof drvname - 1
	lodsb
nextchr:
	cmp al,'a'
	jb @F
	and al,not 20h
@@:
	stosb
	lodsb
	cmp al,','
	jz getunit
	and al,al
	loopnz nextchr
	ret
getunit:
	lodsb
	cmp al,'0'
	jb error
	cmp al,'9'
	ja error
	sub al,'0'
	mov bUnit, al
	clc
	ret
error:
	stc
	ret
getdrvname endp
endif

	assume ds:nothing,ss:nothing

myint15 proc
	pushf
	cmp ah,4fh
	jz @F
defint15:
	popf
	jmp [OldInt15]
@@:
	cmp al,1          ;ESC?         
	jz is_esc
	cmp al,39h        ;SPACE?
	jnz defint15
	inc [bPaused]
	popf
	push bp
	mov bp,sp
	and byte ptr [bp+2+2+2],not 1 ;clear CF
	pop bp
	iret
is_esc:
	mov [bExit], 1
	jmp defint15
myint15 endp

	assume ds:DGROUP, ss:DGROUP

main proc c argc:word, argv:ptr

local dwTimer:dword
local dwSectors:dword
local track:byte
local cnttrk:byte
local first:byte
local last:byte
local leadout:REDBOOK
local start:REDBOOK
local trks[MAXTRKS]:byte
local szVar[4*MAXTRKS]:byte

	mov track,0
	mov cnttrk,0

;--- install keyboard check

	mov ax, 3515h
	int 21h
	mov word ptr [OldInt15+0], bx
	mov word ptr [OldInt15+2], es
	mov dx, offset myint15
	mov ax, 2515h
	int 21h

	mov ax, 4300h
	int 2Fh
	test al, 80h
	.if ZERO?
		invoke printf, CStr("no XMM installed",lf)
		jmp exit
	.endif
	mov ax, 4310h
	int 2Fh
	mov word ptr xmsdrv+0, bx
	mov word ptr xmsdrv+2, es

	push ds
	pop es
	cld

;--- get BLASTER settings

	invoke GetEnvironmentVariable, CStr("BLASTER"), addr szVar, sizeof szVar
	.if ax
		invoke ScanBlasterVar, addr szVar
	.endif

;--- scan cmdline args

	mov bx, argv
	add bx, 2
	lea di, trks
	push ds
	pop es
	.while word ptr [bx] && cnttrk < MAXTRKS
		mov si, [bx]
		add bx, 2
		lodsw
		.if al >= '0' && al <= '9'
			sub si,2
			mov cl,10
			call atoi
			.if byte ptr [si]
				invoke printf, CStr("invalid digit: %s",lf), si
				jmp exit
			.endif
			stosb
			inc cnttrk
		.elseif al == '/' || al == '-'
			or ah,20h
			.if ah == "q"
				mov bVerbose, 0
if ?DRIVER
			.elseif ah == 'd' && byte ptr [si] == ':' && byte ptr [si+1] > ' '
				inc si   ;skip the ':'
				call getdrvname
				.if CARRY?
					mov bHelp, 1
				.endif
endif
			.else
				mov bHelp, 1
			.endif
		.else
			mov bHelp, 1
		.endif
	.endw

	cmp bHelp, 0
	jz @F
	invoke printf, CStr("%s"), offset szHelp
	jmp exit
@@:

if ?DRIVER
	.if drvname[0] > ' '
		mov ah,52h
		int 21h
		add bx,22h
		.repeat
			mov ax, es:[bx].DOSDRV.wAttr ;check driver attributes
			and ah, 0C0h
			cmp ah, 0C0h	;character device & IOCTL supported?
			jnz skipdev
			lea di, [bx].DOSDRV.name_
			lea si, drvname
			mov cx, 8
			repz cmpsb
			jnz skipdev
			mov ax, es:[bx].DOSDRV.wOfsStr
			mov dx, es:[bx].DOSDRV.wOfsInt
			mov word ptr drvstr+0, ax
			mov word ptr drvint+0, dx
			mov word ptr drvstr+2, es
			mov word ptr drvint+2, es
			.break
skipdev:
			les bx, es:[bx].DOSDRV.lpNext
		.until bx == -1
		.if word ptr [drvint+2] == 0
			invoke printf, CStr("Driver %s not found"), addr drvname
			jmp exit
		.endif
		jmp skipcdrchk
	.endif
endif

;--- CD-ROM installed?

	mov ax,1500h
	mov bx,0000
	int 2Fh
	cmp bx,0000
	jnz @F
	invoke printf, CStr("no CD-ROM drive found",lf)
	jmp exit
@@:
	mov wDrive, cx

skipcdrchk:
	call ResetSB	; SB hardware ok?
	jc exit

;--- SB: setup DMA-controller ports

	call setdmaports

;--- SB: setup dwSampleBuffer

	call setupsamplebuffer
	jc exit
	mov word ptr xmsread.ofsDst+0, SAMPLEBUFFERLENGTH / ?BUFFERS * (?BUFFERS - 1)
	mov word ptr xmsread.ofsDst+2, ax
	push es
	mov es, ax
	xor di, di
	mov cx, SAMPLEBUFFERLENGTH shr 1
	xor ax, ax
	rep stosw
	pop es

;--- get read buffer memory (XMS)

if INBUFSIZEKB LT 10000h
	mov ah, 9
	mov dx, INBUFSIZEKB
else
	mov ah, 89h
	mov edx, INBUFSIZEKB
endif
	call xmsdrv
	.if !ax
		invoke printf, CStr("not enough XMS memory",lf)
		jmp exit
	.endif
	mov xmswrite.hDst, dx
	mov xmsread.hSrc, dx

;--- we need a read buffer in conv memory as well
	mov bx, (SAMPLEBUFFERLENGTH / ?BUFFERS) shr 4
	mov ah, 48h
	int 21h
	.if CARRY?
		invoke printf, CStr("out of DOS memory",lf)
		jmp exit
	.endif
	mov word ptr xmswrite.ofsSrc+0, 0
	mov word ptr xmswrite.ofsSrc+2, ax
	mov word ptr req80.address+0, 0
	mov word ptr req80.address+2, ax

	.if bVerbose
		invoke printf, CStr("SB base=%X, irq=%u, dma=%u, hdma=%u",lf), wBase, wIrq, wDmaL, wDmaH
		invoke printf, CStr("sample buffer linear address=%lX",lf), [dwSampleBuffer]
		invoke printf, CStr("DMA ports addr/cnt/page=%X/%X/%X",lf), wDmaBaseChn, wDmaCntChn, wDmaPageChn
	.endif

;--- get volume size info (# of sectors);
;--- also, get TOC info ( first track, last track) in AL/AH

	invoke getvolsize
	.if !CARRY?
;		mov dwSectors, eax
		.if bVerbose
			invoke printf, CStr("IOCTL volume size: sectors=%lu",lf), eax
		.endif
	.else
;		mov dwSectors, 80*60*75
	.endif

	invoke getdiskinfo
	.if !CARRY? && ah >= al
		mov first, al
		mov leadout, edx
		mov cl, ah
		sub cl, al
		inc cl
		.if cl <= MAXTRKS
			mov last, ah
		.else
			add al, MAXTRKS
			mov last, al
			invoke printf, CStr("IOCTL disk info: tracks > %u, will be skipped",lf), MAXTRKS
		.endif
		.if bVerbose
			mov eax, leadout
			call Rb2Lba
			mov edx, eax
			invoke printf, CStr("IOCTL disk info: tracks=%u-%u, leadout=%lu (%02u:%02u:%02u)",lf),
				first, last, edx, leadout._m, leadout._s, leadout._f
		.endif
	.else
		mov first, 1
		mov last, 1
		mov leadout, 795974h
	.endif

;--- get TOC infos for all tracks

	lea di, szVar
	movzx bx, first
	.while bl <= last
		movzx eax, bl
		invoke gettrackinfo, ax
		jc exit
		stosd
		.if cx
			mov ax,bx
			sub al,first
			bts wData,ax
		.endif
		inc bx
	.endw

	mov eax, leadout
	call Rb2Lba   ; convert RedBook in EAX to LBA
	stosd

;--- if no track given, play the full CD
	.if !cnttrk
		push ds
		pop es
		lea di, trks
		lea cx, trks+MAXTRKS
		mov al, first
@@:
		stosb
		inc al
		cmp di, cx
		jz @F
		cmp al, last
		jbe @B
@@:
		lea ax, trks
		xchg ax, di
		sub ax, di
		mov cnttrk, al
	.endif

	call gettimer
	mov dwTimer, eax

	mov dwSectors, 0
	lea si, trks
	movzx bx, cnttrk
	.while 1
		mov eax, req80.stasecs
		.if eax >= dwSectors
			.if bx
				dec bx
				lodsb
				.if al < first || al > last
					invoke printf, CStr("IOCTL track info(%u): track invalid, skipped",lf), byte ptr [si-1]
					.continue
				.endif                
				sub al, first
				movzx di, al
				shl di, 2
				mov ecx, dword ptr [szVar][di]
				mov eax, dword ptr [szVar][di][4]
				mov req80.stasecs, ecx
				mov dwSectors, eax
				.if bVerbose && bSBInit
					invoke printf, CStr(10)
				.endif
				.if bVerbose
					invoke printf, CStr("IOCTL track info(%u): start=%lu end=%lu",lf),
						byte ptr [si-1], req80.stasecs, dwSectors
				.endif
				shr di, 2
				bt wData, di
				.if CARRY?
					.if bVerbose
						invoke printf, CStr("IOCTL track info(%u): data track",lf), byte ptr [si-1]
					.endif
					mov dwSectors, 0
					.continue
				.endif

				.if !bSBInit
					call InitSB	; init SB hardware
				.endif
			.else
				.break .if ( !wSecsInBuf )
			.endif
		.endif
		.if wSecsInBuf < ( INBUFSIZE / ?SECSIZE ); free space in input buffer?
			invoke cdread, dwSectors
			jc exit
			.if bVerbose
				call gettimer
				sub eax, dwTimer
				.if eax >= 5
					add dwTimer, eax
					invoke printf, CStr("curr sector: %6lu [%3",FMTSIB,"]",13), req80.stasecs, wSecsInBuf
				.endif
			.endif
		.endif
		.if bExit
			jmp exit
		.elseif bPaused == 1
			WriteDSP [wBase], DSP_PAUSE16BIT
		.elseif bPaused > 1
			mov bPaused, 0
			WriteDSP [wBase], DSP_CONTINUE16BIT
		.else
			int 28h
		.endif
	.endw
	.if bVerbose
		invoke printf, CStr(10)
	.endif
exit:
	call ExitSB
	.if xmswrite.hDst
		mov dx,xmswrite.hDst
		mov ah,0Ah
		call xmsdrv
	.endif
	push ds
	lds dx,[OldInt15]
	mov ax,2515h
	int 21h
	pop ds

;--- clear kbd buffer
	.repeat
		mov ah,1
		int 16h
		.if !ZERO?
			mov ah,0
			int 16h
			and ah,ah
		.endif
	.until ZERO?
	ret

main endp

	include setargv.inc

start:
	mov ax,cs
	mov ds,ax
	mov cx,ss
	sub cx,ax
	shl cx,4
	mov ss,ax
	add sp,cx

	mov bx, sp
	shr bx, 4
	add bx, 10h
	mov ah, 4Ah
	int 21h
	call _setargv
	invoke main, [_argc], [_argv]
	mov ax,04c00h
	int 21h

	END start
