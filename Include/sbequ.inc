
;--- offsets for SBBASE

SB_MIXER		equ 04h
SB_DSPRESET		equ 06h
SB_DSPREAD		equ 0Ah
SB_DSPWRITE		equ 0Ch	;bit 7 indicates write buffer status
SB_DSPSTATUS	equ 0Eh	;bit 7 indicates read buffer status, int ack
SB_DSPINTACK	equ 0Eh	;int ack 8bit
SB16_DSPINTACK	equ 0Fh	;int ack 16bit

;--- DSP commands

DSP_DMADAC8BIT   		equ 014h	;SB: initiate DMA 8 bit transfer
;--- 02x commands are for DAC/ADC 
;--- 03x commands are for MIDI
DSP_SETTIMECONST 		equ 040h	;SB:
DSP_SETOUTSAMPLERATE	equ 041h	;SB16: send rate with high byte first
DSP_SETINPSAMPLERATE	equ 042h	;SB16:
DSP_CONTAUTOINIT8BIT    equ 045h	;SB16:
DSP_CONTAUTOINIT16BIT   equ 047h	;SB16:
DSP_SINGLECYCLEOUT16	equ 0B0h	;SB16: 16 bit single-cycle for output
DSP_AUTOINITOUT16		equ 0B6h	;SB16: 16 bit autoinit for output
DSP_SINGLECYCLEOUT8		equ 0C0h	;SB16: 8 bit single-cycle for output
DSP_AUTOINITOUT8 		equ 0C6h	;SB16: 8 bit autoinit for output
DSP_PAUSE8BIT           equ 0D0h	;SB: halt 8 bit DMA transfer
DSP_ENABLESPEAKER		equ 0D1h	;SB:
DSP_DISABLESPEAKER		equ 0D3h	;SB:
DSP_CONTINUE8BIT        equ 0D4h	;SB: continue 8 bit DMA transfer
DSP_PAUSE16BIT          equ 0D5h	;SB16: halt 16 bit DMA transfer
DSP_CONTINUE16BIT       equ 0D6h	;SB16: continue 16 bit DMA transfer
DSP_IDENTIFY            equ 0E0h	;SB: 
DSP_VERSION             equ 0E1h	;SB: 

;--- DSP mode setting (0Bx, 0Cx) commands mode bits
;--- bit 4: 1=signed, 0=unsigned
;--- bit 5: 1=stereo, 0=mono

DSP_MODE_UNSIGNED   	equ 00000b
DSP_MODE_SIGNED			equ 10000b
DSP_MODE_MONO  			equ 000000b
DSP_MODE_STEREO			equ 100000b

