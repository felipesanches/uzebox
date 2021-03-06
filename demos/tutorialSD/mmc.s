#include <avr/io.h>
#include "defines.h"

// SD/SPI stuff
#define SPI_PORT	PORTB
#define SPI_DDR		DDRB

#define SD_CS_PORT	PORTD
#define SD_CS_DDR	DDRD

#define SD_SCK    7
#define SD_MOSI   5
#define SD_MISO   6
#define SD_CS     6

// command values to be used with mmccommand
#define SD_CMD_GO_IDLE_STATE        0
#define SD_CMD_SEND_OP_COND         1
#define SD_CMD_APP_SEND_OP_COND     1
#define SD_CMD_SEND_IF_COND         8
#define SD_CMD_SEND_CSD             9
#define SD_CMD_SEND_CID             10
#define SD_CMD_STOPTRANSMISSION     12
#define SD_CMD_SET_BLOCKLEN         16
#define SD_CMD_READ_SINGLE_BLOCK    17
#define SD_CMD_READ_MULTIPLE_BLOCK  18
#define SD_CMD_WRITE_SINGLE_BLOCK   24
#define SD_CMD_WRITE_MULTIPLE_BLOCK 25
#define SD_CMD_APP_CMD              55
#define SD_CMD_READ_OCR             58

#define SD_DATA_TOKEN 0xFE

.section .bss
    sd_512_byte_count:     .word 1

.global sdDirectRead
.global sdFindFileFirstSector
.global sdFindFileFirstSectorFlash

.global sdCardSkipBytes
.global sdCardGetLong
.global sdCardGetInt
.global sdCardGetChar
.global sdCardGetByte
.global sdCardSendByteFF
.global sdCardSendByte
.global sdCardAssertCS
.global sdCardDeassertCS
.global sdCardSendCommand
.global sdCardInitNoBuffer
.global sdCardCueSectorAddress
.global sdCardCueByteAddress
.global sdCardStopTransmission


; void mmcDirectRead(uint8_t *dest, uint16_t count, uint8_t span, uint8_t run);
;
; Inputs
;     Dest  R24:25 = Address in RAM data will be copied too
;     Count R22:23 = How many bytes to transfer from SD to RAM
;     Span  R20    = How many bytes of destination to skip/span after each "run"
;     Run   R18    = How many bytes to copy in a row before doing a skip/span
;
; Returns
;     Void
;
; Modifies
;     byte_count (the 512 byte counter for keeping track of SD reads)
;     RAM pointed to by *dest
;
; Trashed
;     R0, R19, R21, R22, R23, R24, R25, R26, R27, R30, R31
;
;
; Register Usage
;  r0  = thisRun
;  r1  = zero
;  ...
;  r18 = run
;  r19 = local flags  Bit 0 = SPDR already read
;  r20 = span
;  r21 = 0xFF         Constant to send out SPI port
;  r22 = count(lo)
;  r23 = count(hi)
;  r24 = trash        (starting location for *dest(lo) before move to r26)
;  r25 = byteRead     (starting location for *dest(hi) before move to r27)
;  r26 = *dest(lo)
;  r27 = *dest(hi)
;  r28 =
;  r29 =
;  r30 = 512ByteCounter(lo)
;  r31 = 512ByteCounter(hi)
;
;
; For interest C version took 108 words and blocked on in(SPDR) taking 27..34 clocks per byte
/*
void readSDBytes2(uint8_t *dest, uint16_t count, uint8_t span, uint8_t run)
{
	uint8_t thisRun = run;

	while(count != 0) {
		*dest++ = sd_get_byte();
		thisRun--;
		if (thisRun == 0) {
			thisRun = run;
			dest += span;
		}
		count--;
	}
}
*/

; Things that have to happen apart from the obvious from the C code above
;
;    For every OUT(SPDR) there must be an IN(SPDR)
;    There must be at minimum 18 clocks between the OUT and the IN
;    For each IN you need to store the byte at the address pointed to by Z
;    You should only update the address of Z with run/span after the first write
;    For every OUT/IN there must be a check to see if 512 bytes have been read
;    IF 512 Bytes have been read you must "Get a Data Token"
;        (note: mmcDataToken has been modified so that it leaves R30:31 as ZERO
;               this is the 512ByteCounter and it should be zero afterwards
;               origionally this was done here, but moving it to mmcDataToken
;               means we could
;
;               rjmp  mmcDataToken  <<< rjmp rather than rcall and steal its RET
;
;               instead of
;
;               rcall mmcDataToken  <<< an extra Call and a return over above version
;               clr   R30
;               clr   R31
;               ret
;
;    For maximum speed you should do the (n+1)th OUT directly after the nth IN
;
;    ie:
;        Preamble:
;            <set up>
;            ...
;        Loop:
;            out
;            <do something>
;            in
;            store
;            <test end condition and exit>
;            rjmp Loop
;        Exit:
;            <clean up>
;            ...
;
;    Can never be as fast as
;
;        Preamble:
;            <set up>
;            out      <<<< first out
;            ...
;        Loop:
;            <test end condition and exit>
;            in       <<<< Zero clocks wasted between IN and OUT
;            out
;            store
;            <do something>
;            rjmp Loop
;        Exit:
;            in       <<<< Last in
;            store    <<<< last store
;            <clean up>
;            ...
;
;    Doing the OUT STRAIGHT after the IN like this presents a problem.
;    Every 512 bytes there has to be "sd_DataToken" BETWEEN the IN and the OUT
;
;          IN     <<< Get Byte 510
;          OUT    <<< Cue Byte 511
;          STORE  <<< Store byte 510
;          ...
;          IN     <<< Get Byte 511
;          OUT    <<< Cue Byte 512
;          STORE  <<< Store byte 511
;          ...
;          IN     <<< Get Byte 512
;          <GET DATA TOKEN>            <<<<< We have to be able to fit the data token in there
;          OUT    <<< Cue Byte 0
;          STORE  <<< Store byte 512
;          ...
;          IN     <<< Get Byte 0
;          OUT    <<< Cue Byte 1
;          STORE  <<< Store byte 0
;          ...
;          ...
;
;    So we chnage it so the IN can be skipped (based on a flag) and move the test for 512bytes in front of the IN
;
;      Loop:
;          Clear Skip Flag
;          Test 512 Bytes
;          If 512Bytes True then
;              in                  <<<< This IN only happens once every 512 bytes
;              sd_DataToken
;              Set Skip Flag
;          <something>
;          If Skip Flag Clear
;              in                  <<<< This IN happens 511 out of 512 times
;          Out
;          ...
;          rjmp loop
;
; Something else unorthodox
;
;    add    r26, r20
;    brcc   mmcDirectReadLoop
;    adc    r27, r1
;    rjmp   mmcDirectReadLoop
;
;    is used rather than just
;
;    add    r26, r20
;    adc    r27, r1
;    rjmp   mmcDirectReadLoop
;
;    Even though it takes one more cycle if the 8 bit add overflows and costs one extra word.  It is one clock
;    shorter for the most common case of no overflow.  This lets the standard/common case of run=1 be 18
;    clocks rather than 19 clocks.
;

.section .text.sd_direct_read_section
sdDirectRead:                                 ;                                                             Clocks between out(SPDR) and in(SPDR) for case
sd_direct_read:                               ;                                                             First     Normal    First512  Normal512
    ldi    r21, 0xFF                          ;                                                                       Run !run            Run !Run
    out    _SFR_IO_ADDR(SPDR), r21            ; Send out an 0x00 on SPI bus                                  .         .    .    .         .    .
    mov    r0, r18                            ; thisRun = run                                                1         .    .    1         .    .
    movw   r26, r24                           ; move *dest to r25 for use of "ST X+"                         2         .    .    2         .    .
    lds    r30, sd_512_byte_count+0           ; Get the 512ByteCounter into Z                                4         .    .    4         .    .
    lds    r31, sd_512_byte_count+1           ;                                                              6         .    .    7         .    .
    rjmp   .                                  ; waste 2 clock cycles to make 18 clocks to next in(SPDR)      8         .    .    8         .    .
                                              ;                                                              .         .    .    .         .    .
sd_direct_read_loop:                          ;                                                              .         .    .    .         .    .
    cbr    r19, (1<<0)                        ; Clear the SPDR already read flag                             9         9    9    9         9    9
    adiw   r30, 1                             ; Inc the 512ByteCounter                                      11        11   11   11        11   11
    sbrc   r31, 1                             ; if 512cnt != 512 then don't                                 13        13   13   12        12   12
    rcall  sd_direct_read_hit_512             ; (in(SPDR), GetToken, Set SPDR Read flag, clear R30:31)       .         .    .   15        15   15
                                              ;                                                              .         .    .    .         .    .
    subi   r22, 1                             ; count--                                                     14        14   14    .         .    .
    sbci   r23, 0                             ;                                                             15        15   15    .         .    .
    breq   sd_direct_read_cleanup             ; if(count==0) exit the loop                                  16        16   16    .         .    .
                                              ;                                                              .         .    .    .         .    .
    sbrs   r19, 0                             ; if we have already read SPDR (because 512cnt) then skip     17        17   17    .         .    .
    in     r25, _SFR_IO_ADDR(SPDR)            ; read the byte waiting in SPDR after 18 clocks elapsed       18 :)     18   18    .         .    .

    out    _SFR_IO_ADDR(SPDR), r21            ; Send the next 0x00 out the SPI bus                           .         .    .    .         .    .
    st     X+, r25                            ; Save the byte read from SPDR to X                            .         2    2    .         2    2
                                              ;                                                              .         .    .    .         .    .
    dec    r0                                 ; thisRun--                                                    .         3    3    .         3    3
    brne   sd_direct_read_run_end             ; if(thisRun != 0) then skip the run/span maths                .         4    5    .         4    5
    mov    r0, r18                            ; otherwise thisRun = run                                      .         5    .    .         5    .
    add    r26, r20                           ;           *dest += span                                      .         6    .    .         6    .
    brcc   sd_direct_read_loop                ;                                                              .         8    .    .         8    .
    adc    r27, r1                            ;                          *? becomes +2 every 256th byte      .         *?   .    .         *?   .
    rjmp   sd_direct_read_loop                ; start loop again         *? which makes total 20 not 18      .         *?   .    .         *?   .
sd_direct_read_run_end:                       ;                                                              .         .    .    .         .    .
    nop                                       ; waste 1 clock                                                .         .    6    .         .    6
    rjmp   sd_direct_read_loop                ; start loop again                                             .         .    8    .         .    8

sd_direct_read_cleanup:
    sbrs   r19, 0                             ; Check to see if SPDR is already read
    in     r25, _SFR_IO_ADDR(SPDR)            ; if not then read SPDR
    st     X+, r25                            ; Save the byte read from SPDR to X
    sts    sd_512_byte_count+0, r30           ; Save the 512ByteCounter back to RAM
    sts    sd_512_byte_count+1, r31
    ret

sd_direct_read_hit_512:                       ;                                                              .         .    .   16        16   16
    nop                                       ; waste 1 clock                                                .         .    .   17        17   17
    sbr    r19, (1<<0)                        ; set the SPDR already read into r25 flag                      .         .    .   18        18   18
    in     r25, _SFR_IO_ADDR(SPDR)            ; in(SPDR)

	rcall  sd_card_send_byte_ff               ; ??????? GET CRC AND STUFF ?????  Investigate why SD fails but UZEM works without this implicit
	rcall  sd_card_send_byte_ff

    rjmp   sd_card_get_data_token             ; rjmp not rcall to reuse the RET at end of datatoken
                                              ; note: sd_datatoken resets 512Cnt in R30:31 back to zero

/*
	sd_cuesector(0x000);	// Get the MBR

	mmcSkipBytes(offsetof(MBR, partition1)+ offsetof(PartitionEntry, startSector));			// Skip the execCode and a few other bytes

	long bootRecordSector = mmcGetLong();   // sector that the boot record starts at

	sd_stoptransmission();					// stop reading the MBR
	sd_cuesector(bootRecordSector);		// and start reading the boot record

	mmcSkipBytes(offsetof(BootRecord, bytesPerSector));

	int  bytesPerSector    = mmcGetInt();
	char sectorsPerCluster = mmcGetChar();
	int  reservedSectors   = mmcGetInt();
	mmcSkipBytes(1);
	int  maxRootDirectoryEntries = mmcGetInt();
	mmcSkipBytes(3);
	int sectorsPerFat = mmcGetInt();

	long dirTableSector = bootRecordSector + reservedSectors + (sectorsPerFat * 2);

	sd_stoptransmission();
	sd_cuesector(dirTableSector);

	uint8_t fileFound = 1;

	do {
		if(fileFound == 0) {
			mmcSkipBytes(21);
			fileFound = 1;
		}

		for(uint8_t i = 0; i<11; i++){
			if(sd_get_byte() != fileName[i]) fileFound = 0;
		}

	} while (fileFound == 0);

	mmcSkipBytes(15);

	int firstCluster = mmcGetInt();

	sd_stoptransmission();

	return(dirTableSector+((maxRootDirectoryEntries * 32)/bytesPerSector)+((firstCluster-2)*sectorsPerCluster));
*/

.section .text.sd_find_file_section

sdFindFileFirstSectorFlash:
sd_find_file_first_sector_flash:
	bset	6					; set the T flag in SREG to indicate we are looking at string in FLASH
	rjmp	sd_find_file_first_sector_common

sdFindFileFirstSector:
sd_find_file_first_sector:
	bclr	6					; clear the T flag in SREG to indicate we are looking at string in RAM
sd_find_file_first_sector_common:
	push	r2					; Save R2 as it will be overwritten by SPC
	push	r16					; Save R16:17 as it will be overwritten by MaxFilesToSearchFor
	push	r17
	push	r28					; Save R28:29 as it will be overwritten by the String Index Pointer
	push	r29
	push	r24					; Save the address pointing too the String (could be flash or RAM)
	push	r25


// sd_cuesector(0x000);
	rcall 	sd_find_clear_r22_23_24_25
	rcall	sd_card_cue_sector_address
// mmcSkipBytes(offsetof(MBR, partition1)+ offsetof(PartitionEntry, startSector));
	ldi		r24, 0xC6
	ldi		r25, 0x01
	rcall	sd_card_skip_bytes
//long bootRecordSector = mmcGetLong();
	rcall	sd_card_get_long
	movw	r26, r24			; Save the high word of the boot sector to r26:27 (which is untouched by StopTransmission)
	movw	r18, r22			; Save the low word to r18:19
//sd_stoptransmission();
	rcall	sd_card_stop_transmission
//sd_cuesector(bootRecordSector);
	movw	r24, r26
	movw	r22, r18
	rcall	sd_card_cue_sector_address
//mmcSkipBytes(offsetof(BootRecord, bytesPerSector));
	ldi		r24, 0x0B
	rcall	sd_card_skip_bytes_max_256
//int  bytesPerSector    = mmcGetInt();
	rcall	sd_card_get_int							; We divide BytesPerSector by 32 for a re-arrange of the later maths
	ldi		r23, 0x20								; ((maxRootDirectoryEntries * 32)/bytesPerSector)
	rcall	sd_find_div_r2425_by_r23_result_r0		; The result of this is at most 8 bits (BPS is 128..4096)
//char sectorsPerCluster = mmcGetChar();
	rcall	sd_card_get_char
	mov		r2, r24
//int  reservedSectors   = mmcGetInt();
	rcall	sd_card_get_int							; Get reserved sectors and add it straight to R12:19:26:26
	rcall	sd_find_add_r2425_to_r1819_r2627			; which now contains (bootRecordSector + reservedSectors)
//mmcSkipBytes(1);
	ldi		r24, 0x01
	rcall	sd_card_skip_bytes_max_256
//	int  maxRootDirectoryEntries = mmcGetInt();
	rcall	sd_card_get_int
	movw	r16, r24								; Make a copy of Max Root Dir Entries for NumFilesToCheck

	mov		r23, r0									; Do the second part of the maths for
	rcall	sd_find_div_r2425_by_r23_result_r0		; ((maxRootDirectoryEntries * 32)/bytesPerSector)
													; leaving the result in R0 (If you try to custom format a disk
													; with 4096 RDE and only 256 BPS this will fail.  All sensible
													; "round" binary values will work
//mmcSkipBytes(3);
	ldi		r24, 0x03
	rcall	sd_card_skip_bytes_max_256
//int sectorsPerFat = mmcGetInt();
	rcall	sd_card_get_int							; Sectors per fat then divide by two
	lsl		r24										; and then add to (bootRecordSector + reservedSectors)
	rol		r25
	rcall	sd_find_add_r2425_to_r1819_r2627
//long dirTableSector = bootRecordSector + reservedSectors + (sectorsPerFat * 2);
//sd_stoptransmission();
	rcall	sd_card_stop_transmission


//sd_cuesector(dirTableSector);
	movw	r24, r26
	movw	r22, r18
	rcall	sd_card_cue_sector_address

	movw	r24, r0									; Now that we have finished "cueing" the DirTable we can continue the maths
	rcall	sd_find_add_r2425_to_r1819_r2627			; dirTableSector + ((maxRootDirectoryEntries * 32)/bytesPerSector)

	pop		r21								; pop the base address of the 8.3 filename string
	pop		r20

sd_find_file_for_each_dir_entry_loop:
	movw	r28, r20						; Get the base address of the filename into the index_backup
	ldi		r22, 11							; number of chars to check (11 = 8+3)
	cbr		r23, (1<<0)						; clear the search for file flag
sd_find_file_text_search_loop:
	rcall	sd_card_get_char				; Get the first byte from the SD card to compare

	movw	r30, r28
	brts	sd_find_file_text_search_loop_not_ram
	ld		r25, Z+							; get the first byte of the search string to compare
sd_find_file_text_search_loop_not_ram:
	brtc	sd_find_file_text_search_loop_not_flash
	lpm		r25, Z+
sd_find_file_text_search_loop_not_flash:

	movw	r28, r30

	cp		r24, r25						; compare the two bytes

	breq	sd_find_file_text_not_equal	; and if not matched then set dirty flag
	sbr		r23, (1<<0)
sd_find_file_text_not_equal:
	dec		r22
	brne	sd_find_file_text_search_loop	; continue for all 11 bytes

	sbrs	r23, 0							; if the dirty flag was not set (ie: all 11 chars matched)
	rjmp	sd_find_file_text_found		; then we have found the file

	subi	r16, 1							; subtract ONE from NumFilesToCheck
	sbc		r17, r1

	brne	sd_find_file_keep_searching
	rcall	sd_find_clear_r22_23_24_25
	rjmp	sd_find_file_file_not_found

sd_find_file_keep_searching:
	ldi		r24, 21							; other wise skip fwd 21 bytes to the next directory entry (11 + 21 = 32)
	rcall	sd_card_skip_bytes_max_256

	rjmp	sd_find_file_for_each_dir_entry_loop	; and continue

sd_find_file_text_found:

//mmcSkipBytes(15);
	ldi		r24, 15							; Skip FWD to read the address of the first cluster of this file
	rcall	sd_card_skip_bytes_max_256

//int firstCluster = mmcGetInt();
	rcall	sd_card_get_int

	subi	r24, 2							; (firstCluster-2)
	sbc		r25, r1

sd_find_file_mul_by_BPS_loop:					; Do a really dumb multiply by successive adds.
	rcall	sd_find_add_r2425_to_r1819_r2627	; This smaller code because we already have a function for the add
	dec		r2									; so looping back x many SectorsPerCluster (in r2) manages a 8x16->24
	brne	sd_find_file_mul_by_BPS_loop		; in only 3 words (even though it could take 4000 cycles)
												; Note: This IS a 24 bit result for any file past the 40 megabyte mark

;sd_stoptransmission();
	rcall	sd_card_stop_transmission


;return(dirTableSector+((maxRootDirectoryEntries * 32)/bytesPerSector)+((firstCluster-2)*sectorsPerCluster));
	movw	r22, r18
	movw	r24, r26

sd_find_file_file_not_found:
	pop		r29								; restore the registers we used
	pop		r28
	pop		r17
	pop		r16
	pop		r2
	ret

sd_find_clear_r22_23_24_25:
	ldi		r22, 0x00
	ldi		r23, 0x00
	movw	r24, r22
	ret

sd_find_div_r2425_by_r23_result_r0:					; This is a dumb divide only works for values with 1 high bit
	lsr		r25										; AFAIK this is OK for the FAT maths as MaxRDE can only be 512, 1024, 2048 or 4096
	ror		r24
	lsr		r23
	brcc	sd_find_div_r2425_by_r23_result_r0
	mov		r0, r24
	ret

sd_find_add_r2425_to_r1819_r2627:
	add		r18, r24
	adc		r19, r25
	adc		r26, r1
	adc		r27, r1
	ret






.section .text.sd_card_common_section
sd_card_skip_bytes_max_256:
	ldi		r25, 0x00
sdCardSkipBytes:
sd_card_skip_bytes:
	movw	r22, r24

sd_card_skip_bytes_loop:
	rcall	sd_card_get_byte
	subi	r22, 1
	sbci	r23, 0
	brne	sd_card_skip_bytes_loop
	ret

sdCardGetLong:
sd_card_get_long:
    rcall   sd_card_get_int     ; First two bytes from SD card and move to R22:23
    movw    r22, r24
                                ; Fall through to GetInt to receive 3rd and 4th bytes
sdCardGetInt:
sd_card_get_int:
    rcall   sd_card_get_byte    ; First byte from SD card to temp location in R20 (3rd byte of GetLong)
    mov     r20, r24
    rcall   sd_card_get_byte    ; Second byte from SD card to temp location in R21 (4th byte of GetLong)
    mov     r21, r24
    movw    r24, r20            ; Move R20:21 to the R24:25 location C is expecting it
    ret

sdCardGetChar:
sd_card_get_char:
sdCardGetByte:
sd_card_get_byte:
    ldi     r24, 0xFF
    out     _SFR_IO_ADDR(SPDR),r24

    lds     r30, sd_512_byte_count+0
    lds     r31, sd_512_byte_count+1
    adiw    r30, 1
    sts     sd_512_byte_count+0, r30
    mov     r24, r31
    andi    r24, 0x01
    sts     sd_512_byte_count+1, r24

    sbrs    r31, 1
    rjmp    sd_card_send_byte_wait

sd_card_hit_512_boundary:
    rcall	sd_card_send_byte_wait

    push    r24
    rcall   sd_card_get_data_token
    pop     r24
    ret

sdCardSendByteFF:
sd_card_send_byte_ff:
    ldi     r24,0xff
sdCardSendByte:
sd_card_send_byte:
    out     _SFR_IO_ADDR(SPDR),r24
sd_card_send_byte_wait:
    in      r24,_SFR_IO_ADDR(SPSR)
    sbrs    r24,SPIF
    rjmp    sd_card_send_byte_wait
    in      r24,_SFR_IO_ADDR(SPDR)
    ret

sd_card_send_80_clocks:
    ldi     r25,10
sd_card_send_80_clocks_loop:
    rcall   sd_card_send_byte_ff
    dec     r25
    brne    sd_card_send_80_clocks_loop
    ret

sdCardAssertCS:
sd_card_assert_cs:
	cbi     _SFR_IO_ADDR(SD_CS_PORT), SD_CS
    ret

sdCardDeassertCS:
sd_card_deassert_cs:
	sbi     _SFR_IO_ADDR(SD_CS_PORT), SD_CS
    ret

sd_card_clock_and_release:
	push    r24
    rcall   sd_card_send_80_clocks
    pop     r24
    rjmp    sd_card_deassert_cs
    ; phantom RET

; void sd_send_command(uint8_t command, uint16_t px, uint16_t py)
sd_card_send_command_no_address:
	ldi		r20, 0
	ldi		r21, 0
	movw	r22, r20
sdCardSendCommand:
sd_card_send_command:
    rcall   sd_card_assert_cs

    mov     r25, r24                    ; save command
    rcall   sd_card_send_byte_ff        ; send dummy byte
    mov     r24, r25                    ; restore command

    ori     r24, 0x40
    rcall   sd_card_send_byte           ; send command
    mov     r24,r23
    rcall   sd_card_send_byte           ; send high x
    mov     r24,r22
    rcall   sd_card_send_byte           ; send low x
    mov     r24,r21
    rcall   sd_card_send_byte           ; send high y
    mov     r24,r20
    rcall   sd_card_send_byte           ; send low y
    ldi     r24, 0x95                   ; correct CRC for first command in SPI
    rcall   sd_card_send_byte           ; after that CRC is ignored, so no problem with always sending 0x95

    rjmp    sd_card_send_byte_ff
    ; phantom RET

; sd_card_get_r1b_response:
; Inputs
;     Void
;
; Returns
;     r24 - R1 Response from SD card
;
; Modifies
;     Nil
;
; Trashed
;     R24, R25 (via sd_card_send_byte_ff)
;     R30, R31
sd_card_get_r1b_response:
    rcall   sd_card_get_r1_response         ; Get the R1 response into R24
    push    r24                             ; Save R1 to the stack
sd_card_get_r1b_response_loop:
    rcall   sd_card_send_byte_ff            ; Send out bytes on the SPI port until we
    cpi     r24, 0xFF                       ; recieve an 0xFF back which indicates no
    brne    sd_card_get_r1b_response_loop   ; longer busy
    pop     r24                             ; restores the R1 response to R24
    ret                                     ; and return the R1 response in R24

; sd_card_get_r1_response:
; Inputs
;     Void
;
; Returns
;     r24 - R1 Response from SD card
;
; Modifies
;     Nil
;
; Trashed
;     R24, R25 (via sd_card_send_byte_ff)
;     R30, R31
sd_card_get_r1_response:
    ser     r30                             ; use R30:31 as a timeout counter
    ser     r31
sd_card_get_r1_response_loop:
    sbiw    r30,1                           ; Decrement the timeout counter
    breq    sd_card_get_r1_response_end     ; if we have timed out then fail with whatever data was in r24
    rcall   sd_card_send_byte_ff            ; get the next byte from the SD card to see if it is a data token
    sbrc    r24, 7                          ; If the MSB is set then we have found the R1 response
    rjmp    sd_card_get_r1_response_loop    ; So can skip the loop back to the start
sd_card_get_r1_response_end:
    ret                                     ; and return the R1 response in R24

; sd_card_get_data_token:
; Inputs
;     Void
;
; Returns
;     r24 - 0xFE on success
;
; Modifies
;     R30:31 - set to 0x0000
;
; Trashed
;     R24, R25 (via sd_card_send_byte_ff)
;     R30, R31
;
; Continually RXs bytes from the SD card until it receives 0xFE the data
sd_card_get_data_token:
    ser     r30                             ; use R30:31 as a timeout counter
    ser     r31
sd_card_data_token_loop:
    sbiw    r30,1                           ; Decrement the timeout counter
    breq    sd_card_data_token_end          ; if we have timed out then fail with whatever data was in r24
    rcall   sd_card_send_byte_ff            ; get the next byte from the SD card to see if it is a data token
    cpi     r24, SD_DATA_TOKEN              ; if it is a data_token (0xFE) the quit loop with data_token in r24
    brne    sd_card_data_token_loop         ; if it was not the data_token then try again
sd_card_data_token_end:
    clr     r31                             ; leave r30:31 as 0x0000 for 512_byte_counter for other ASM functions
    clr     r30
    ret

; uint8_t  sdCardInitNoBuffer(void);
;
; Inputs
;     Void
;
; Returns
;     r24 - 0 on success
;
; Modifies
;     Nil
;
; Trashed
;     R20, R21, R22, R23, R24, R25 (via sd_card_send_command)
;     R30, R31 (vid sd_card_get_r1_response / sd_card_get_token)
;
; Register Usage
;     Nil
;
sdCardInitNoBuffer:
sd_card_init_no_buffer:
    sbi     _SFR_IO_ADDR(SPI_PORT), SD_SCK  ; Setup I/O ports
    sbi     _SFR_IO_ADDR(SPI_PORT), SD_MOSI
    cbi     _SFR_IO_ADDR(SPI_PORT), SD_MISO

    sbi     _SFR_IO_ADDR(SPI_DDR), SD_SCK   ; SD_SCK is an output
    sbi     _SFR_IO_ADDR(SPI_DDR), SD_MOSI  ; SD_MOSI is an output

    sbi     _SFR_IO_ADDR(SD_CS_PORT), SD_CS ; Initial SD_CD level is high
    sbi     _SFR_IO_ADDR(SD_CS_DDR),  SD_CS ; Direction is output

    ldi     r24, (1<<MSTR)|(1<<SPE)|(1<<SPR1)|(1<<SPR0)    ;enable SPI interface clock div by 128 = ~~200Khz
    out     _SFR_IO_ADDR(SPCR), r24

	rcall   sd_card_send_80_clocks          ; 80 clocks for power stabilization

    ldi     r24, (1<<MSTR)|(1<<SPE)         ; enable SPI interface clock div cleared for fasted speed
    out     _SFR_IO_ADDR(SPCR), r24
    ldi     r24, (1<<SPI2X)                 ; set SPI double speed
    out     _SFR_IO_ADDR(SPSR), r24

    ldi     r24, SD_CMD_GO_IDLE_STATE       ; issue card reset
    rcall   sd_card_send_command_no_address
    rcall   sd_card_get_r1_response         ; wait for the r1 response
    cpi     r24, 0x01                       ; should be 0x01 which is "busy" but no other errors
    breq    sd_card_init_card_detected

    ldi     r24, 0x01                       ; Any other R1 response is invalid / no card detected
	rjmp    sd_card_clock_and_release       ; so we give up and return an error (0x01)
    ; phantom ret

sd_card_init_card_detected:
    ; send CMD1 until we get a 0 back, indicating card is done initializing

sd_card_init_cmd1_loop:
    ldi     r24, SD_CMD_SEND_OP_COND        ; Send CMD1 "Send OP Cond" to initialise the card
    rcall   sd_card_send_command_no_address
    rcall   sd_card_get_r1_response         ; Get the R1 response
    cpi     r24, 0x00                       ; if Response is 0x00 then card is ready
    brne    sd_card_init_cmd1_loop          ; otherwise try sending a CMD1 again

sd_card_init_cmd1_done:
    rjmp   sd_card_clock_and_release        ; Deassert CS, send some clocks, and return 0x00 "success"
    ; phantom RET


; uint8_t  sdCardCueSectorAddress(uint32_t lba);
; uint8_t  sdCardCueByteAddress(uint32_t address);
;
; Inputs
;     R25:24:23:22 - Either Sector(LBA) address or byte address to cue
;
; Returns
;     r24 - 0 on success
;
; Modifies
;      sd_512_byte_count (uint16_t in RAM)
;
; Trashed
;     R20, R21, R22, R23, R24, R25 (via sd_card_send_command)
;     R30, R31 (via sd_card_get_token)
;
; Register Usage
;     Nil
;
; Sends SD CMD18 "Read Multiple Block" and then waits for a data token response.
; resets the sd_512_byte_count variable for further reads to keep track of packet
; location.
.section .text.sd_card_cue_section
sdCardCueSectorAddress:
sd_card_cue_sector_address:
    mov     r25, r24                        ; Regular SD needs byte adress so shift sector value by 9 bits (*512)
    mov     r24, r23                        ; by first shifting it one byte (8 bits)
    mov     r23, r22
    clr     r22
    lsl     r23                             ; and then follow up with 1 more shift for a total of 9 bits
    rol     r24
    rol     r25

sdCardCueByteAddress:
sd_card_cue_byte_address:
    movw    r20, r22                        ; shift the address from R22:23:24:25 where it came in
    movw    r22, r24                        ; into R20:21:22:23 where sd_card_send_command expects it

    ldi     r24, SD_CMD_READ_MULTIPLE_BLOCK
    rcall   sd_card_send_command

    rcall   sd_card_get_data_token          ; wait for data token
    cpi     r24, SD_DATA_TOKEN
    breq    sd_card_cue_end                 ; if data token received cue_sector succeded

                                            ; other wise there was an error and we need to
    ldi     r24,0xff                        ; return fail
    rjmp    sd_card_clock_and_release       ; release the SD card bus
    ; phantom ret

sd_card_cue_end:
    sts     sd_512_byte_count+0, r1         ; Reset the 512_byte counter
    sts     sd_512_byte_count+1, r1
    clr     r24                             ; return success
    ret

; uint8_t  sdCardStopTransmission(void);
;
; Inputs
;     Void
;
; Returns
;     Void
;
; Modifies
;     Nil
;
; Trashed
;     R20, R21, R22, R23, R24, R25 (via sd_card_send_command)
;
; Register Usage
;     Nil
;
; Sends SD CMD12 "Stop Transmission" and then waits for the R1b response to
; indicate SD card is ready and deasserts the SD chip select line.
sdCardStopTransmission:
sd_card_stop_transmission:
    ldi     r24, SD_CMD_STOPTRANSMISSION
    rcall   sd_card_send_command_no_address
    rcall   sd_card_get_r1b_response
    rjmp    sd_card_deassert_cs
    ; phantom ret



