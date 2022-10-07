
;*** playcd - plays track(s) of an audio CD.
;*** Public Domain.
;*** main purpose of this program is to test the CD/DVD driver's
;*** support for Audio CDs.
;***
;*** to create the binary enter:
;***   jwasm -mz playcd.asm
;***
;*** Masm v6+ should work as well; you'll need a 16-bit
;*** OMF linker then (recommended: jwlink or OW WLINK):
;***   ml -c playcd.asm
;***   jwlink format dos file playcd.obj

	.286
	.model small
	.dosseg
	.386

cr	equ 13
lf	equ 10

;--- CStr(): macro to define a string constant

CStr macro text:VARARG
local sym
	.const
sym db text,0
	.code
	exitm <offset sym>
endm

;--- DOS device driver request header

reqhdr  struct
len     db ?
subunit db ?
cmd     db ?
status  dw ?
res1    dd ?
res2    dd ?
reqhdr  ends

;--- values for reqhdr.cmd
IOCREAD  equ 03h
PLAY     equ 84h
STOP     equ 85h	;stop playing

cmd03   struct		;read ioctl
        reqhdr <>
mdesc   DB   ?      ; block devices: Media descriptor byte from BPB
taddr   DD   ?      ; Transfer address
numbyt  DW   ?      ; call: # bytes to transfer; return: # bytes transfered
;start   DW   0      ; Starting sector number 
;volid   DD   0      ; DWORD ptr to requested vol ID if error 0FH
cmd03   ends

COMMENT ^
+-----------------------------------------------------------------+
| read ioctl input codes:                                         |
| Code       to Transfer                 Function                 |
|                                                                 |
|   0             5            Return Address of Device Header    |
|   1             6            Location of Head                   |
|   2             ?            Reserved                           |
|   3             ?            Error Statistics                   |
|   4             9            Audio Channel Info                 |
|   5           130            Read Drive Bytes                   |
|   6             5            Device Status                      |
|   7             4            Return Sector Size                 |
|   8             5            Return Volume Size                 |
|   9             2            Media Changed                      |
|  10             7            Audio Disk Info                    |
|  11             7            Audio Track Info                   |
|  12            11            Audio Q-Channel Info               |
|  13            13            Audio Sub-Channel Info             |
|  14            11            UPC Code                           |
|  15            11            Audio Status Info                  |
|  16-255        ?             Reserved                           |
+-----------------------------------------------------------------+
^

IO_AUCHINF   equ 4
IO_DEVSTAT   equ 6
IO_VOLSIZE   equ 8
IO_DISKINFO  equ 10
IO_TRKINFO   equ 11
IO_QCHANNEL  equ 12
IO_UPC       equ 14
IO_AUSTAT    equ 15

ioctl04 struct	;audio channel info
cmd     db ?
ich0    db ?    ;input channel for output channel 0
vol0    db ?    ;volume        for output channel 0
ich1    db ?    ;input channel for output channel 1
vol1    db ?    ;volume        for output channel 1
ich2    db ?    ;input channel for output channel 2
vol2    db ?    ;volume        for output channel 2
ich3    db ?    ;input channel for output channel 3
vol3    db ?    ;volume        for output channel 3
ioctl04 ends

ioctl06 struct	;device status
cmd     db ?
status  dd ?
ioctl06 ends

ioctl08 struct	;get volume size
cmd     db ?
sectors dd ?	;size in sectors
ioctl08 ends

ioctl10 struct	;audio disk info
cmd     db ?
first   db ?
last    db ?
union
leadout dd ?
struct
leadout_f db ?
leadout_s db ?
leadout_m db ?
ends
ends
ioctl10 ends

ioctl11 struct	;audio track info
cmd     db ?
track   db ?
union
start   dd ?
struct
start_f db ?
start_s db ?
start_m db ?
ends
ends
ctlinfo db ?
ioctl11 ends

ioctl12 struct	;audio q-channel info
cmd     DB ?
ctladr  DB ?         ; CONTROL and ADR byte
tno     DB ?         ; Track number (TNO)
index   DB ?         ; (POINT) or Index (X)
; Running time within a track
min     DB ?         ; (MIN)
sec     DB ?         ; (SEC)
frame   DB ?         ; (FRAME)
        DB ?         ; (ZERO)
; Running time on the disk
amin    DB ?         ; (AMIN) or (PMIN)
asec    DB ?         ; (ASEC) or (PSEC)
aframe  DB ?         ; (AFRAME) or (PFRAME)
ioctl12 ends

ioctl14 struct	;UPC code
cmd     DB ?
ctladr  DB ?         ; CONTROL and ADR byte
upcean  DB 7 dup (?) ; UPC/EAN code
                     ; last 4 bits are zero; the low-order nibble of byte 7
        DB ?         ; Zero
aframe  DB ?         ; Aframe
ioctl14 ends

ioctl15 struct	;audio status
cmd     DB ?
status  DW ?         ; status bits
union
startl  DD ?         ; start for next resume
struct
startl_f DB ?
startl_s DB ?
startl_m DB ?
ends
ends
union
endl    DD ?         ; end for next resume
struct
endl_f  DB ?
endl_s  DB ?
endl_m  DB ?
ends
ends
ioctl15 ends

cmd84   struct      ;play audio
        reqhdr <>
mode    db ?        ;addressing mode (see below)
stasecs dd ?        ;number of first sector to play
numsecs dd ?        ;sectors to play
cmd84   ends

HSG_MODE equ 00h
RB_MODE  equ 01h	;redbook mode

cmd85   struct      ;stop play audio
        reqhdr <>
cmd85   ends

	.data

drive   dw 0
bTrack  db -1
bOption db 0
adrcnt  dd 16 dup (0)	;counter for all Q-Channel ADR modes

OPT_NOWAIT equ 1	;just start playing, don't wait
OPT_NOBUSY equ 2	;don't check busy flag
OPT_STOP   equ 4	;stop audio playing

	align word
req03   cmd03  <<>,,buffer>
req84   cmd84  <>
req85   cmd85  <>

	.data?

buffer  db 130 dup (?)	;130=max for read ioctl
	org buffer
ioc04   ioctl04 <>
	org buffer
ioc06   ioctl06 <>
	org buffer
ioc08   ioctl08 <>
	org buffer
ioc10   ioctl10 <>
	org buffer
ioc11   ioctl11 <>
	org buffer
ioc12   ioctl12 <>
	org buffer
ioc14   ioctl14 <>
tmpstr  db 14 dup (?)
	org buffer
ioc15   ioctl15 <>

	.code

	include printf.inc

;--- convert redbook address in EAX to LBA

CvtLBA proc
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
	add ax,dx		;now ax contains seconds

;--- convert seconds to frames
	mov dl,75
	mul edx
	mov dl,150		;add "frame" value by subtracting it from "2 sec" offset
	sub dl,cl
	sub eax,edx
	ret
error:
	mov eax,100*60*75	;error, set value to max (450.000)
	ret
CvtLBA endp

;--- send device driver request (via MSCDEX)

SendReq proc stdcall req:ptr BYTE

	mov bx,req
	push ds
	pop es
	mov cx,drive
	clc 			;XP needs this
	mov ax,1510h	;send dev. req.
	int 2Fh
	ret

SendReq endp

;--- get cmdline parameters
;--- ES=PSP

getparam proc near
	mov bx,0080h
nextchar:
	inc bx
	mov al,es:[bx]
	cmp al,cr
	jz done
	cmp al,0
	jz done
	cmp al,'/'
	jz @F
	cmp al,'-'
	jz @F
	cmp al,' '
	jz nextchar
	cmp al,9
	jz nextchar
	call getnum
	jnc settno
parerr:
	stc
	ret
@@:
	inc bx
	mov al,es:[bx]
	or al,20h
	cmp al,'n'
	jz opt_n
	cmp al,'b'
	jz opt_b
	cmp al,'s'
	jz opt_s
	jmp parerr
opt_n:
	or bOption, OPT_NOWAIT
	jmp nextchar
opt_b:
	or bOption, OPT_NOBUSY
	jmp nextchar
opt_s:
	or bOption, OPT_STOP
	jmp nextchar
settno:
	mov bTrack, al
	dec bx
	jmp nextchar
done:
	clc
	ret
getnum:
	xor dx,dx
nextdigit:
	mov al,es:[bx]
	cmp al,'0'
	jb nodigit
	cmp al,'9'
	ja nodigit
	sub al,'0'
	shl dx,1
	mov cx,dx
	shl dx,2
	add dx,cx
	mov ah,0
	add dx,ax
	inc bx
	jmp nextdigit
nodigit:
	cmp al,' '
	jz @F
	cmp al,9
	jz @F
	cmp al,cr
	jz @F
	stc
@@:
	mov ax,dx
	ret
getparam endp


main proc c

local	startRB:dword	;start in redbook format
local	endRB:dword		;end in redbook format
local	numsecs:dword	;sectors to play
local	dwTimer:dword
local	starttrack:byte
local	endtrack:byte

	call getparam
	jnc @F
	invoke printf, CStr("usage: PLAYCD [ options ] <trackno>",lf,"options are:",lf)
	invoke printf, CStr("    -b: ignore busy flag (use ESC to stop!)",lf)
	invoke printf, CStr("    -n: don't wait for play audio command to finish",lf)
	invoke printf, CStr("    -s: stop playing audio",lf)
	invoke printf, CStr("   if <trackno> isn't specified, all tracks are played",lf)
	jmp exit
@@:
;--- call MSCDEX to see if there's a CD/DVD at all
	mov ax, 1500h
	mov bx, 0000
	int 2Fh
	cmp bx, 0000
	jnz @F
	invoke printf, CStr("no CD-ROM drive found",lf)
	jmp exit
@@:
	mov drive, cx

	test bOption, OPT_STOP
	jnz stopplaying

;--- get audio channel info
	mov req03.len, sizeof cmd03
	mov req03.cmd, IOCREAD
	mov req03.numbyt, sizeof ioctl04
	mov ioc04.cmd, IO_AUCHINF	;get audio channel info
	invoke SendReq, addr req03
	jnc @F
	invoke printf, CStr("IOCTL audio channel info call failed [%X]",lf), ax
	jmp exit
@@:
	invoke printf, CStr("IOCTL audio channel info [%X]: ch0=%02X/%02X ch1=%02X/%02X ch2=%02X/%02X ch3=%02X/%02X",lf),
		req03.status, ioc04.ich0, ioc04.vol0, ioc04.ich1, ioc04.vol1, ioc04.ich2, ioc04.vol2, ioc04.ich3, ioc04.vol3

;--- get device params
	mov req03.len, sizeof cmd03
	mov req03.cmd, IOCREAD		; IOCTL input
	mov req03.numbyt, sizeof ioctl06
	mov ioc06.cmd, IO_DEVSTAT	; get device status
	invoke SendReq, addr req03
	jnc @F
	invoke printf, CStr("IOCTL device status call failed [%X]",lf), ax
	jmp exit
@@:
	invoke printf, CStr("IOCTL device status [%X]: params=%08lX",lf), req03.status, ioc06.status
	test ioc06.status, 1
	jz @F
	invoke printf, CStr("status[0]=1: door is open",lf)
	jmp exit
@@:
	test ioc06.status, 10h
	jnz @F
	invoke printf, CStr("status[4]=0: no support to play audio - ignored!",lf)
;--- don't exit, try to play anyway!
;	jmp exit
@@:
	test req03.status, 200h	;busy?
	jz @F
	invoke printf, CStr("status[9]=1: device busy - will try to stop playing",lf)
;--- stop audio playing
stopplaying:
	mov req85.len, sizeof cmd84
	mov req85.subunit, 0
	mov req85.cmd, STOP
	invoke SendReq, addr req85
	invoke printf, CStr("Stop Audio [%X]",lf), req85.status
	jmp exit
@@:

;--- get volume size
	mov req03.len, sizeof cmd03
	mov req03.cmd, IOCREAD
	mov req03.numbyt, sizeof ioctl08
	mov ioc08.cmd, IO_VOLSIZE	;get volume size
	invoke SendReq, addr req03
	jnc @F
	invoke printf, CStr("IOCTL volume size call failed [%X]",lf), ax
	jmp novolsize
@@:
	invoke printf, CStr("IOCTL volume size [%X]: sectors=%lu",lf), req03.status, ioc08.sectors
novolsize:

;--- get disk info, set endRB, starttrack and endtrack values
	mov req03.len, sizeof cmd03
	mov req03.cmd, IOCREAD
	mov req03.numbyt, sizeof ioctl10
	mov ioc10.cmd, IO_DISKINFO	;get disk info
	invoke SendReq, addr req03
	jnc @F
	invoke printf, CStr("IOCTL disk info call failed [%X]",lf), ax
	jmp exit
@@:
	invoke printf, CStr("IOCTL disk info [%X]: tracks %u-%u, leadout=%02u:%02u:%02u",lf), req03.status, ioc10.first, ioc10.last, ioc10.leadout_m, ioc10.leadout_s, ioc10.leadout_f
	mov eax, ioc10.leadout
	mov endRB, eax
	test req03.status, 8000h
	jnz exit
	mov al, bTrack
	cmp al, -1
	jnz @F
	mov al, ioc10.first
@@:
	mov starttrack, al
	mov al, ioc10.last
	mov endtrack, al

;--- get UPC disk info
	mov req03.len, sizeof cmd03
	mov req03.cmd, IOCREAD
	mov req03.numbyt, sizeof ioctl14
	mov ioc14.cmd, IO_UPC	;get UPC code
	invoke SendReq, addr req03
	jnc @F
	invoke printf, CStr("IOCTL UPC call failed [%X]",lf), ax
	jmp noupc
@@:
	test req03.status, 8000h
	jz @F
	invoke printf, CStr("IOCTL UPC code [%X]",lf), req03.status
	jmp noupc
@@:
;--- convert UPC BCD string to ASCII
	lea si, ioc14.upcean
	lea di, tmpstr
	push ds
	pop es
	mov cx, 7
nextbyte:
	lodsb
	db 0d4h, 10h	;aam 10h
	add ax, 3030h
	xchg al, ah
	stosw
	loop nextbyte
	mov [di-1], cl	;terminate ASCII with 0
	invoke printf, CStr("IOCTL UPC code [%X]: CA=%02X UPC=%s",lf), req03.status, ioc14.ctladr, addr tmpstr
noupc:

;--- get audio status info
	mov req03.len, sizeof cmd03
	mov req03.cmd, IOCREAD
	mov req03.numbyt, sizeof ioctl15
	mov ioc15.cmd, IO_AUSTAT	;get audio status
	invoke SendReq, addr req03
	jnc @F
	invoke printf, CStr("IOCTL audio status call failed [%X]",lf), ax
	jmp noaustat
@@:
	test req03.status, 8000h
	jz @F
	invoke printf, CStr("IOCTL audio status [%X]",lf), req03.status
	jmp noaustat
@@:
	invoke printf, CStr("IOCTL audio status [%X]: status=%04X start=%02u:%02u:%02u end=%02u:%02u:%02u",lf),
		req03.status, ioc15.status,
		ioc15.startl_m, ioc15.startl_s, ioc15.startl_f,
		ioc15.endl_m, ioc15.endl_s, ioc15.endl_f
noaustat:

;--- get info for first track to be played, set startRB value
	mov req03.len, sizeof cmd03
	mov req03.cmd, IOCREAD
	mov req03.numbyt, sizeof ioctl11
	mov ioc11.cmd, IO_TRKINFO	;get track info
	mov al, starttrack
	mov ioc11.track, al
	invoke SendReq, addr req03
	jnc @F
	invoke printf, CStr("IOCTL track %u info call failed [%X]",lf), starttrack, ax
	jmp exit
@@:
	invoke printf, CStr("IOCTL track %u info [%X]: start=%02u:%02u:%02u, ctlinfo=%X",lf), starttrack, req03.status, ioc11.start_m, ioc11.start_s, ioc11.start_f, ioc11.ctlinfo
	test req03.status, 8000h
	jnz exit
;--- usually a cd starts at 00:02:00 (redbook), but we play it safe
	mov eax, ioc11.start
	mov startRB, eax
	mov al, ioc11.ctlinfo
	test al, 40h		;data track?
	jz @F
	invoke printf, CStr("track %u is a data track",lf), ioc11.track
	jmp exit
@@:
;--- is track the last one? 
	mov al, starttrack
	cmp al, endtrack
	jnc islasttrack
;--- or is the whole disk to be played?
	cmp bTrack, -1
	jz islasttrack
;--- then we don't need start of next track

;--- get info for next track, modify endRB value
	mov req03.len, sizeof cmd03
	mov req03.cmd, IOCREAD
	mov req03.numbyt, sizeof ioctl11
	mov ioc11.cmd, IO_TRKINFO	;get track info
	mov al, starttrack
	inc al
	mov ioc11.track, al
	invoke SendReq, addr req03
	jnc @F
	invoke printf, CStr("IOCTL track %u info call failed [%X]",lf), ioc11.track, ax
	jmp exit
@@:
	invoke printf, CStr("IOCTL track %u info [%X]: start=%02u:%02u:%02u, ctlinfo=%X",lf), ioc11.track, req03.status, ioc11.start_m, ioc11.start_s, ioc11.start_f, ioc11.ctlinfo
	test req03.status, 8000h
	jnz exit
	mov eax,ioc11.start
	mov endRB, eax

islasttrack:
	mov eax, startRB
	call CvtLBA
	mov esi, eax
	mov eax, endRB
	call CvtLBA
	sub eax, esi
	mov numsecs, eax
	invoke printf, CStr("start sector=%lu, num sectors=%lu",lf), esi, eax

;--- play track(s)
	mov req84.len, sizeof cmd84
	mov req84.subunit, 0
	mov req84.cmd, PLAY
	mov req84.mode, RB_MODE
	mov eax, startRB
	mov req84.stasecs, eax
	mov eax, numsecs
	mov req84.numsecs, eax
	invoke SendReq, addr req84
	jnc @F
	invoke printf, CStr("Play Audio failed [%X]",lf), req84.status
	jmp exit
@@:
	invoke printf, CStr("Play Audio [%X]",lf), req84.status

	test bOption, OPT_NOWAIT
	jnz exit

;--- wait until playing has terminated

nextloop:
	call gettick
	mov dwTimer, eax
;--- read and display q-channel info in a loop
	mov req03.len, sizeof cmd03
	mov req03.cmd, IOCREAD
	mov req03.numbyt, sizeof ioctl12
if 1 ;clear the buffer (XP returns success, but won't supply any values) 
	xor eax, eax
	mov dword ptr ioc12+0, eax
	mov dword ptr ioc12+4, eax
	mov dword ptr ioc12+7, eax
endif
	mov ioc12.cmd, IO_QCHANNEL	;get q-channel info
	invoke SendReq, addr req03
	jnc @F
	invoke printf, CStr("IOCTL Q-channel info call failed",lf)
	jmp exit
@@:
;--- the TNO field is displayed in hex, because it's supposed to be BCD
	invoke printf, CStr("IOCTL Q-channel info [%X]: CA=%02X TNO=%02X X=%02X track=%02u:%02u:%02u disk=%02u:%02u:%02u",cr),
		req03.status, ioc12.ctladr, ioc12.tno, ioc12.index, ioc12.min, ioc12.sec, ioc12.frame, ioc12.amin, ioc12.asec, ioc12.aframe
;--- increase counter, use ADR value as index
	movzx eax, ioc12.ctladr
	and al, 0Fh
	inc adrcnt[eax*4]

dowait:
;--- is a key pressed?
	mov ah, 01h
	int 16h
	jz @F
	mov ah,00
	int 16h
	cmp ah,01
	jnz @F
	invoke printf, CStr(lf)
	jmp stopplaying
@@:
	call gettick
	sub eax, dwTimer
	cmp eax, 5
	jb dowait
	test bOption, OPT_NOBUSY
	jnz nextloop
	test req03.status, 0200h
	jnz nextloop

exit:
	invoke printf, CStr(lf)
;--- display Q-channel info counters 
	mov si, offset adrcnt
	xor di, di
nextcnt:
	lodsd
	and eax, eax
	jz @F
	invoke printf, CStr("Q-channel info, mode %u: read %lu times",lf), di, eax
@@:
	inc di
	cmp di, 16
	jb nextcnt
	ret
gettick:
	push ds
	push 0
	pop ds
	mov eax, ds:[46ch]
	pop ds
	retn

main endp

;--- init code.
;--- to set the "small" memory model, register SS must equal DS (=DGROUP)

start:
	mov ax, @data
	mov ds, ax
	mov bx, ss
	sub bx, ax
	shl bx, 4
	mov ss, ax
	add sp, bx
	call main
	mov ax,4c00h
	int 21h

	.stack 800h

	END start
