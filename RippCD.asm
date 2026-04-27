
;--- rip Audio and Mixed Mode CDs.
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
?CUE     equ 1		;1=support /C (write a .cue file)

VERSION  textequ <"1.0">

;--- read buffer size - buffer must fit in 64 kB:
;--- 65536 / 2352 = max 27 sectors;

BUFFERLENGTH equ ?SECSIZE * 16

MAXTRKS  equ 64	;max tracks - must be a multiple of 16

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

PGMNAME textequ <"RippCD">

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

RIFFHDR struct
chkId   dd ?
chkSiz  dd ?
format  dd ?
RIFFHDR ends

RIFFCHKHDR struct
subchkId    dd ?
subchkSiz   dd ?
RIFFCHKHDR ends

WAVEFMT struct
        RIFFCHKHDR <>
wFormatTag      dw ?
nChannels       dw ?
nSamplesPerSec  dd ?
nAvgBytesPerSec dd ?
nBlockAlign     dw ?
wBitsPerSample  dw ?
WAVEFMT ends

WAVEHDR struct
rh  RIFFHDR <>
wf  WAVEFMT <>
rch RIFFCHKHDR <>
WAVEHDR ends

;--- macros

CStr macro text:vararg
local sym
	.const
sym db text,0
	.code
	exitm <offset sym>
endm

	.data

OldInt15 dd 0	;old value of Int 15h
wData    dw MAXTRKS shr 4 dup (0) ;track type bits

bVerbose db 1	;0=/q option active
bHelp   db 0	;1=/? option active
bExit   db 0	;1=ESC pressed
bSingle db 0	;1=single file mode
if ?CUE
bCue    db 0	;1=create cue sheet
endif
bData   db 0	;1=current track is data
bError  db 0	;1=stop at cd read errors
cntData db 0	;# of data tracks written
if ?DRIVER
drvname db 8 dup (' '),0
bUnit   db 0
	align word
drvstr  dd 0
drvint  dd 0
endif

	align word

wDrive dw 0		; CD drive #
pFN    dw offset szDefFNm
req03   cmd03 <>	;ioctl
req80   cmd80 <>	;read long

	.const

szHelp label byte
	db PGMNAME," v",VERSION," - read (audio) CD data and write it to a file.",lf
	db "Usage: ",PGMNAME," [options] [track# ...]",lf
	db " options:",lf
	db " -? : this help",lf
	db " -c : write cue sheet",lf
if ?DRIVER
	db " -d:drvname[,unit] : call optical driver directly",lf
endif
	db " -e : stop at read errors",lf
	db " -o:prefix : set prefix for output filename(s)",lf
	db " -q : no status displays",lf
	db " -s : write all tracks in one file",lf
	db "If track# is omitted, all tracks are ripped.",lf
	db "Defaults for prefix is '~TRK' & '~CD' (for -s)",lf
	db "ESC terminates prematurely.",lf
	db 0
szDefFNm db "~TRK",0
szDefFNs db "~CD",0

	.code

	include printf.inc
	include vsprintf.inc

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
	.if eax > BUFFERLENGTH / ?SECSIZE
		mov eax, BUFFERLENGTH / ?SECSIZE
	.endif
	mov req80.numsecs, ax
	and ax, ax
	jz exit
	mov req80.readmod, RAW
	invoke SendReq, addr req80
	jc error
	test req80.status, 8000h
	jnz error
	movzx eax, req80.numsecs
	add req80.stasecs, eax
exit:
	clc
	ret
error:
	movzx eax, req80.numsecs
	add req80.stasecs, eax
	invoke printf, CStr("Read long(%lu): failed [%X]",lf), req80.stasecs, req80.status
	stc
	ret
cdread endp

;--- convert LBA address in EAX to RB

Lba2RB proc uses bx
	cdq
	mov ecx, 75
	div ecx
	mov bl, dl
	cdq
	mov ecx, 60
	div ecx
	mov bh, dl
	shl eax, 16
	mov ax, bx
	ret
Lba2RB endp

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

;--- deinit SB hardware

if ?DRIVER

;--- store optical driver name

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

itoa proc stdcall uses di pOut:ptr, num:byte
	cld
	mov di, pOut
	movzx ax, num
	mov cx, 10
	cwd
	div cx
	and al, al
	jz @F
    add al, '0'
	stosb
@@:
	mov al, dl
	add al, '0'
	stosb
	mov al, 0
	stosb
	lea ax, [di-1]
	ret
itoa endp

strcpy proc stdcall uses si di pDst:ptr, pSrc:ptr
	mov di, pDst
	mov si, pSrc
	cld
@@:
	lodsb
	stosb
	and al,al
	jnz @B
	ret
strcpy endp

CreateFile proc stdcall uses bx si di pPrefix:ptr, trackno:byte

local szFN[256]:byte

	invoke strcpy, addr szFN, pPrefix
	lea di, szFN
	.while byte ptr [di]
		inc di
	.endw
	.if !bSingle
		invoke itoa, di, trackno
		mov di, ax
	.endif
	.if bData
		mov si, CStr(".bin")
    .else
		mov si, CStr(".wav")
    .endif
	mov cx, 5
	rep movsb

	mov bx, 2001h  ;access mode & sharing - 2001=write only, no int 24h
	mov cx, 0      ;attributes - 0=normal file
	mov dx, 12h    ;action - b4=create, b1=truncate -> create always
	lea si, szFN
	mov di, 0      ;alias hint
	mov ax,716Ch
	stc
	int 21h
	jnc @F
	.if ax == 7100h
		mov ax,6c00h
		int 21h
		jc error1
	.endif
@@:
	.if !bData
		mov bx, ax
		mov dx, sizeof RIFFHDR + sizeof WAVEFMT + sizeof RIFFCHKHDR
		mov cx, 0
		mov ax, 4200h
		int 21h
		mov ax, bx
	.endif
	ret
error1:
	invoke printf, CStr("create file failed",lf)
	stc
	ret
CreateFile endp

CloseFile proc stdcall uses bx si hFile:word, priffhdr:ptr, pwavefmt:ptr, pdatahdr:ptr

	.if !bData
		mov bx, hFile
		mov cx, 0
		mov dx, 0
		mov ax, 4200h
		int 21h

		mov si, pdatahdr
		mov eax, [si].RIFFCHKHDR.subchkSiz
		mov si, priffhdr
		add [si].RIFFHDR.chkSiz, eax

		mov dx, si
		mov cx, sizeof RIFFHDR
		mov ah, 40h
		int 21h
		jc error2

		mov dx, pwavefmt
		mov cx, sizeof WAVEFMT
		mov ah, 40h
		int 21h
		jc error2

		mov dx, pdatahdr
		mov cx, sizeof RIFFCHKHDR
		mov ah, 40h
		int 21h
		jc error2
	.endif

	mov bx, hFile
	mov ah, 3Eh
	int 21h
	ret
error2:
	invoke printf, CStr("write file hdr failed",lf)
	stc
	ret
CloseFile endp

writeData proc stdcall uses bx si di handle:word

	mov ax, req80.numsecs
	and ax, ax
	jz exit
	imul ax, ?SECSIZE
	push ds
	lds dx, req80.address
	mov cx, ax
	mov bx, handle
	mov ah, 40h
	int 21h
	pop ds
	jc error2
	cmp ax, cx
	jnz error2
exit:
	ret
error2:
	invoke printf, CStr("write file failed",lf)
	stc
	ret
writeData endp

if ?CUE

sprintf proc c pBuffer:ptr, pFmt:ptr, args:vararg

	invoke vsprintf, pBuffer, pFmt, addr args
	ret

sprintf endp

;--- track# in cue sheet must start with 1 and be consecutive

writecue proc stdcall uses bx si di tracks:byte, pTracks:ptr, pSectors:ptr

local rb:REDBOOK
local pExt:word
local start:dword
local hFile:word
local curTrk:word
local szFN[256]:byte

	cmp tracks, 0
	jz exit
	mov si, pFN
	lea di, szFN
@@:
	lodsb
	stosb
	and al,al
	jnz @B
	dec di
	mov pExt, di
	mov eax,"euc."
	stosd
	mov al,0
	stosb
	mov bx, 2001h  ;access mode & sharing - 2001=write only, no int 24h
	mov cx, 0      ;attributes - 0=normal file
	mov dx, 12h    ;action - b4=create, b1=truncate -> create always
	lea si, szFN
	mov di, 0      ;alias hint
	mov ax,716Ch
	stc
	int 21h
	jnc @F
	.if ax == 7100h
		mov ax,6c00h
		int 21h
		jc error1
	.endif
@@:
	mov hFile, ax
	.if bSingle
		lea si, szFN
		call writefileline
	.endif

	mov si, pTracks
	mov di, pSectors
	mov curTrk, 1
	.while tracks
		lodsb
		push si
		lea si, szFN
		.if !bSingle
			push ax
			call writefileline2
			pop ax
		.endif
		.if al == -1
			mov dx, CStr("MODE1/2352")
		.else
			mov dx, CStr("AUDIO")
		.endif
		invoke sprintf, si, CStr(" TRACK %02u %s",13,10), curTrk, dx
		call writeline
		mov eax, [di]
		.if curTrk == 1 || !bSingle
			mov start, eax
		.endif
		sub eax, start
		call Lba2RB
		mov rb, eax
		lea si, szFN
		invoke sprintf, si, CStr(" INDEX 01 %02u:%02u:%02u",13,10), rb._m, rb._s, rb._f
		call writeline
		pop si
		inc curTrk
		add di, sizeof dword
		dec tracks
	.endw
	mov bx, hFile
	mov ah, 3Eh
	int 21h
exit:
	ret
error1:
	invoke printf, CStr("create CUE file failed",lf)
	ret
writeline:
	mov cx, ax
	mov bx, hFile
	mov dx, si
	mov ah, 40h
	int 21h
	retn
writefileline:
	.if cntData
		invoke sprintf, si, CStr('FILE "%s.bin" BINARY',13,10), pFN
	.else
		invoke sprintf, si, CStr('FILE "%s.wav" WAVE',13,10), pFN
	.endif
	call writeline
	retn
writefileline2:
	.if al == -1
		invoke sprintf, si, CStr('FILE "%s%u.bin" BINARY',13,10), pFN, curTrk
	.else
		invoke sprintf, si, CStr('FILE "%s%u.wav" WAVE',13,10), pFN, curTrk
	.endif
	call writeline
	retn
writecue endp
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
	jmp defint15
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
local currtrk:byte
local first:byte
local last:byte
local hFile:word
local leadout:REDBOOK
local start:REDBOOK
local trks[MAXTRKS]:byte
local szVar[4*MAXTRKS]:byte
local wavehdr:WAVEHDR

	mov track,0
	mov cnttrk,0
	mov hFile, -1

;--- install keyboard check

	mov ax, 3515h
	int 21h
	mov word ptr [OldInt15+0], bx
	mov word ptr [OldInt15+2], es
	mov dx, offset myint15
	mov ax, 2515h
	int 21h

	push ds
	pop es
	cld

	xor ax, ax
	lea di, wavehdr
	mov cx, sizeof WAVEHDR shr 1
	rep stosw

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
		.if al > '0' && al <= '9'
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
			.elseif ah == 's'
				mov bSingle, 1
if ?CUE
			.elseif ah == 'c'
				mov bCue, 1
endif
			.elseif ah == 'e'
				mov bError, 1
if ?DRIVER
			.elseif ah == 'd' && byte ptr [si] == ':' && byte ptr [si+1] > ' '
				inc si   ;skip the ':'
				call getdrvname
				.if CARRY?
					mov bHelp, 1
				.endif
endif
			.elseif ah == 'o' && byte ptr [si] == ':' && byte ptr [si+1] > ' '
				inc si   ;skip the ':'
				mov pFN, si
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
	.if bSingle && pFN == offset szDefFNm
		mov pFN, offset szDefFNs
	.endif

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

;--- CD-ROM extensions installed?

	mov ax,1500h
	mov bx,0000
	int 2Fh
	cmp bx,0000
	jnz @F
	invoke printf, CStr("no optical drive found",lf)
	jmp exit
@@:
	mov wDrive, cx

skipcdrchk:

;--- we need a read buffer in conv memory
	mov bx, BUFFERLENGTH shr 4
	mov ah, 48h
	int 21h
	.if CARRY?
		invoke printf, CStr("out of DOS memory",lf)
		jmp exit
	.endif
	mov word ptr req80.address+0, 0
	mov word ptr req80.address+2, ax

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

;--- if no track given, ripp the full CD
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
	.while !bExit
		mov eax, req80.stasecs
		.if eax >= dwSectors
			.if bSingle == 0 && hFile != -1
				invoke CloseFile, hFile, addr wavehdr.rh, addr wavehdr.wf, addr wavehdr.rch
				mov hFile, -1
			.endif
			.if bx
				dec bx
				lodsb
				mov currtrk, al
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
					mov bData, 1
					mov byte ptr [si-1],-1
					inc cntData
if ?CUE
					.if !bCue
endif
						mov dwSectors, 0
						.continue
if ?CUE
					.endif
endif
				.else
					mov bData, 0
				.endif
			.else
				.break
			.endif
		.endif

		invoke cdread, dwSectors
		.if CARRY?
			cmp bError, 0
			jnz exit
		.endif
		.if bVerbose
			call gettimer
			sub eax, dwTimer
			.if eax >= 5
				add dwTimer, eax
				invoke printf, CStr("curr sector: %6lu",13), req80.stasecs
			.endif
		.endif

		.if hFile == -1
			invoke CreateFile, pFN, currtrk
			.if ax == -1
				jmp exit
			.endif
			mov hFile, ax
			mov wavehdr.rh.chkId, "FFIR"
			mov wavehdr.rh.chkSiz, sizeof WAVEHDR - 8	;filesize in bytes - 8
			mov wavehdr.rh.format, "EVAW"
			mov wavehdr.wf.subchkId, " tmf"
			mov wavehdr.wf.subchkSiz, sizeof WAVEFMT - 8
			mov wavehdr.wf.wFormatTag, 1    ;1=PCM uncompressed
			mov wavehdr.wf.nChannels, 2
			mov wavehdr.wf.nSamplesPerSec, 44100
			mov wavehdr.wf.nAvgBytesPerSec, ?SECSIZE * 75
			mov wavehdr.wf.nBlockAlign, 2 * 16 / 8   ;channels * ((bitspersample +7)/8
			mov wavehdr.wf.wBitsPerSample, 16
			mov wavehdr.rch.subchkId, "atad"
			mov wavehdr.rch.subchkSiz, 0    ;init, will be updated during writes
		.endif

		invoke writeData, hFile
		jc exit
		movzx eax, ax
		add wavehdr.rch.subchkSiz, eax
	.endw
	.if bVerbose
		invoke printf, CStr(10)
	.endif
exit:
	.if hFile != -1
		.if bSingle && cntData ;option -s set and any data track found?
			mov bData, 1       ;then ensure that no .wav header is written
		.endif
		invoke CloseFile, hFile, addr wavehdr.rh, addr wavehdr.wf, addr wavehdr.rch
		mov hFile, -1
	.endif
if ?CUE
	.if bCue
		invoke writecue, cnttrk, addr trks, addr szVar
	.endif
endif
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
