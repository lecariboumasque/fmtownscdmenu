;==============================================================================
; CDSWMENU.ASM — BlueSCSI CD Switch sub-menu for CaptainYs Rescue IPL v5
;
; Added by Tugs, 2026-04-09.
;
; v5 improvements over v4:
;   * Pagination (14 CDs per page, left/right arrows navigate pages)
;   * Game name cleanup:  "01_RAINBOW_ISLAND.BIN" -> "RAINBOW ISLAND"
;       - skip leading "NN_" digit+underscore prefix
;       - drop trailing "." extension
;       - keep only A-Z, 0-9, space; replace all other chars with space
;       - collapse duplicate spaces, trim leading/trailing
;       - convert to uppercase
;       - truncate at 30 chars (CDSWMENU_DISPLAY_WIDTH) for screen safety
;   * Game names drawn in bright blue for readability
;   * Title drawn in yellow
;   * Page indicator "PAGE X / Y" at bottom
;
; SCSI Toolbox opcodes used (BlueSCSI vendor-specific):
;   0xDA  COUNT_CDS    -> 1 byte file count
;   0xD7  LIST_CDS     -> N x 40 bytes (file entries)
;   0xD8  SET_NEXT_CD  -> CDB[1] = file index
;
; Uses existing CaptainYs IPL helpers:
;   DRAWARROW, READ_PADA, MOVE_ARROW_BY_PAD, MENU_WAIT_PAD_RELEASE,
;   PAD_TO_LEFT_RIGHT, PRINT_TALL, LOCATE, TEXTLOCATION, COLOR,
;   CLEAR_FIVE_BELOW
; And the low-level SCSI driver: SCSI_COMMAND (SCSILIB/SCSIIO.ASM).
;==============================================================================

CDSWMENU_ITEMS_PER_PAGE		EQU		14		; CDs per page (+ BACK = 15 menu entries)
CDSWMENU_MAX_CDS			EQU		100		; Toolbox LIST_CDS caps at 100

; Colors (see FM Towns 16-color palette)
CDSWMENU_COLOR_TITLE		EQU		14		; yellow
CDSWMENU_COLOR_NAME			EQU		9		; bright blue
CDSWMENU_COLOR_ACTIVE		EQU		10		; bright green (currently active CD)
CDSWMENU_COLOR_BACK			EQU		15		; white
CDSWMENU_COLOR_STATUS		EQU		11		; cyan

; Display buffer: 34 bytes per cleaned name (32 chars + CRLF or NUL)
; cap 15 visible items per page -> buffer size = 16 * 34 = 544 bytes per page
; We build 1 cleaned name at a time, so only need per-name scratch.
CDSWMENU_CLEAN_NAME_MAX		EQU		34
; Maximum display width for a game name (screen columns).
; Names start at column 5; "PAGE X / Y" is at column 55.
; Leave margin: 30 visible chars max to avoid overlap.
CDSWMENU_DISPLAY_WIDTH		EQU		30

;------------------------------------------------------------------------------
; SCSI command descriptor blocks (10-byte CDBs)
;------------------------------------------------------------------------------
CDSWMENU_CMD_COUNT		DB		0DAh, 0, 0, 0, 0, 0, 0, 0, 0, 0
CDSWMENU_CMD_LIST		DB		0D7h, 0, 0, 0, 0, 0, 0, 0, 0, 0
CDSWMENU_CMD_SETNEXT	DB		0D8h, 0, 0, 0, 0, 0, 0, 0, 0, 0

;------------------------------------------------------------------------------
; Static UI strings
;------------------------------------------------------------------------------
CDSWMENU_BACK_STR		DB		"BACK TO MAIN MENU", 0
CDSWMENU_TITLE_STR		DB		"FM TOWNS SCSI CD MENU - BY TUGS", 0
CDSWMENU_NO_CDS_STR		DB		"NO CDS FOUND IN /CD3 ON BLUESCSI", 0
CDSWMENU_SCSI_ERR_STR	DB		"SCSI ERROR - CANNOT READ CD LIST", 0
CDSWMENU_DONE_STR		DB		"CD SWITCHED - USE BOOT MENU TO LAUNCH IT", 0
CDSWMENU_BOOTING_STR	DB		"BOOTING SELECTED CD...", 0
CDSWMENU_NAV_STR		DB		"L/R=Page  U/D=Select  ENTER=Pick  SPACE=Pick+Boot", 0
CDSWMENU_PAGE_STR		DB		"PAGE ", 0
CDSWMENU_PAGE_OF_STR	DB		" / ", 0

;------------------------------------------------------------------------------
; Dynamic state
;------------------------------------------------------------------------------
CDSWMENU_SELECTION		DB		0		; selection WITHIN current page (0 = BACK)
CDSWMENU_NUM_ITEMS		DB		0		; items visible on current page
CDSWMENU_CD_COUNT		DB		0		; total CDs returned by COUNT_CDS
CDSWMENU_PAGE			DB		0		; current page (0-based)
CDSWMENU_NUM_PAGES		DB		0
CDSWMENU_ACTIVE_CD		DB		0FFh	; sequential index in reply buffer of last selected CD (0xFF = none)
CDSWMENU_DP_CURROW		DB		0		; row counter for DRAW_PAGE (memory so PRINT_TALL can't trash it)
CDSWMENU_KEY_STORE		DB		0		; saved keyboard scan code from READ_PADA
CDSWMENU_ACTION_BOOT	DB		0		; 0 = select + back to main, 1 = direct boot

;------------------------------------------------------------------------------
; Buffers
;------------------------------------------------------------------------------
; Reply buffer from LIST_CDS (100 x 40 bytes)
CDSWMENU_REPLY_BUF		DB		4000 dup(0)

; Scratch buffer for one cleaned name
CDSWMENU_CLEAN_BUF		DB		CDSWMENU_CLEAN_NAME_MAX dup(0)

; Small scratch buffer for decimal numbers (max 3 digits + NUL)
CDSWMENU_NUM_BUF		DB		4 dup(0)

; Page display buffer — concatenated NUL-terminated cleaned names for one page.
; Max: CDSWMENU_ITEMS_PER_PAGE * CDSWMENU_CLEAN_NAME_MAX = 14 * 34 = 476 bytes.
CDSWMENU_DISP_BUF		DB		512 dup(0)

;==============================================================================
; CDSWMENU PROC
;==============================================================================
CDSWMENU				PROC

		PUSH	CS
		POP		DS
		PUSH	CS
		POP		ES

		; 1) COUNT_CDS
		CALL	CDSWMENU_SEND_COUNT
		JC		CDSWMENU_SCSI_ERR

		MOV		AL, CS:[CDSWMENU_REPLY_BUF]
		MOV		CS:[CDSWMENU_CD_COUNT], AL
		CMP		AL, 0
		JE		CDSWMENU_NO_CDS

		; 2) LIST_CDS
		CALL	CDSWMENU_SEND_LIST
		JC		CDSWMENU_SCSI_ERR

		; 3) Compute number of pages = ceil(cd_count / ITEMS_PER_PAGE)
		XOR		AH, AH
		MOV		AL, CS:[CDSWMENU_CD_COUNT]
		ADD		AL, CDSWMENU_ITEMS_PER_PAGE - 1
		MOV		BL, CDSWMENU_ITEMS_PER_PAGE
		DIV		BL					; AL = count / PAGE, AH = remainder
		MOV		CS:[CDSWMENU_NUM_PAGES], AL

		; 4) Start on page 0, selection 0 (= BACK TO MAIN MENU)
		MOV		BYTE PTR CS:[CDSWMENU_PAGE], 0
		MOV		BYTE PTR CS:[CDSWMENU_SELECTION], 0

CDSWMENU_OUTER_LOOP:
		CALL	MENU_WAIT_PAD_RELEASE
		CALL	CLEAR_FIVE_BELOW

		; Compute items on the current page
		CALL	CDSWMENU_UPDATE_PAGE_COUNT

		; Draw the title at (5, 6) in yellow
		; NOTE: do NOT call LOCATE after TEXTLOCATION — LOCATE would overwrite
		;       DI using whatever AX currently holds.
		MOV		AL, CDSWMENU_COLOR_TITLE
		CALL	COLOR
		TEXTLOCATION	5, 6
		MOV		SI, OFFSET CDSWMENU_TITLE_STR
		CALL	PRINT_TALL

		; Draw the page indicator on the same row as the title, right side
		CALL	CDSWMENU_DRAW_PAGE_INDICATOR

		; Draw the nav hints at (5, 7) in cyan — directly below the title
		MOV		AL, CDSWMENU_COLOR_STATUS
		CALL	COLOR
		TEXTLOCATION	5, 7
		MOV		SI, OFFSET CDSWMENU_NAV_STR
		CALL	PRINT_TALL

		; Draw the menu items for this page
		CALL	CDSWMENU_DRAW_PAGE

		; Back to white for the arrow
		MOV		AL, 15
		CALL	COLOR

		; Draw arrow at current selection
		MOVZX	CX, CS:[CDSWMENU_NUM_ITEMS]
		MOV		AL, CS:[CDSWMENU_SELECTION]
		CALL	DRAWARROW

CDSWMENU_WAIT_PAD:
		CALL	READ_PADA
		CMP		AL, 0FFh
		JE		CDSWMENU_WAIT_PAD

		; Save pad byte AND keyboard scan code — MOVE_ARROW_BY_PAD overwrites AH
		MOV		BYTE PTR CS:[CDSWMENU_PAD_STORE], AL
		MOV		BYTE PTR CS:[CDSWMENU_KEY_STORE], AH

		; 1) Up/Down — safe to always process, only looks at bits 0 and 1
		MOV		AH, CS:[CDSWMENU_SELECTION]
		MOV		CH, CS:[CDSWMENU_NUM_ITEMS]
		CALL	MOVE_ARROW_BY_PAD
		MOV		CS:[CDSWMENU_SELECTION], AH

		; 2) Check for button press FIRST (bits 4 and 5)
		; Rationale: CaptainYs' PAD_TO_LEFT_RIGHT also tests bits 4/5 and treats
		; them as left/right. If we'd called it before the button check, any
		; button press would be interpreted as "change page".
		MOV		AL, CS:[CDSWMENU_PAD_STORE]
		AND		AL, 30h
		CMP		AL, 30h
		JNE		CDSWMENU_BUTTON_PRESSED

		; 3) No button pressed — check pad left/right for page change
		; Use a local helper that ONLY looks at bits 2 and 3 (pure D-pad L/R),
		; not bits 4/5 (buttons).
		MOV		AL, CS:[CDSWMENU_PAD_STORE]
		CALL	CDSWMENU_PAD_LR_ONLY
		CMP		BX, 0
		JE		CDSWMENU_OUTER_LOOP			; neither L nor R nor button
		CMP		BX, 1
		JE		CDSWMENU_PAGE_RIGHT
		JMP		CDSWMENU_PAGE_LEFT

CDSWMENU_PAGE_RIGHT:
		MOV		AL, CS:[CDSWMENU_PAGE]
		INC		AL
		CMP		AL, CS:[CDSWMENU_NUM_PAGES]
		JB		CDSWMENU_PAGE_SET
		XOR		AL, AL					; wrap to 0
		JMP		CDSWMENU_PAGE_SET

CDSWMENU_PAGE_LEFT:
		MOV		AL, CS:[CDSWMENU_PAGE]
		CMP		AL, 0
		JNE		CDSWMENU_PAGE_LEFT_OK
		MOV		AL, CS:[CDSWMENU_NUM_PAGES]	; wrap to last
		DEC		AL
		JMP		CDSWMENU_PAGE_SET
CDSWMENU_PAGE_LEFT_OK:
		DEC		AL

CDSWMENU_PAGE_SET:
		MOV		CS:[CDSWMENU_PAGE], AL
		MOV		BYTE PTR CS:[CDSWMENU_SELECTION], 0
		JMP		CDSWMENU_OUTER_LOOP

CDSWMENU_BUTTON_PRESSED:
		; Decide action 1 (select + back) vs action 2 (select + boot):
		;   - Pad B  → bit 5 of PAD_STORE is clear (0)
		;   - Space  → KEY_STORE == 35h  (Enter/Execute map to bit 4 with
		;              different scan codes, so they fall through to action 1)
		MOV		BYTE PTR CS:[CDSWMENU_ACTION_BOOT], 0

		MOV		AL, CS:[CDSWMENU_PAD_STORE]
		TEST	AL, 20h						; bit 5 set? (high = not pressed)
		JNZ		CDSWMENU_BP_CHECK_SPACE
		MOV		BYTE PTR CS:[CDSWMENU_ACTION_BOOT], 1
		JMP		CDSWMENU_BP_DISPATCH

CDSWMENU_BP_CHECK_SPACE:
		MOV		AL, CS:[CDSWMENU_KEY_STORE]
		CMP		AL, 35h						; Space scan code?
		JNE		CDSWMENU_BP_DISPATCH
		MOV		BYTE PTR CS:[CDSWMENU_ACTION_BOOT], 1

CDSWMENU_BP_DISPATCH:
		; Handle BACK TO MAIN MENU (selection 0) or a game selection
		MOVZX	BX, CS:[CDSWMENU_SELECTION]
		CMP		BL, 0
		JE		CDSWMENU_BACK_TO_MAIN

		; Game selected — compute sequential index = page*ITEMS_PER_PAGE + (sel-1)
		DEC		BL
		MOV		AL, CS:[CDSWMENU_PAGE]
		MOV		BH, CDSWMENU_ITEMS_PER_PAGE
		MUL		BH					; AX = page * items_per_page
		ADD		AL, BL				; AL = sequential index in reply buffer
		ADC		AH, 0

		; Save the sequential index for ACTIVE_CD highlighting
		MOV		CS:[CDSWMENU_ACTIVE_CD], AL

		; Lookup the REAL BlueSCSI file index from reply_buf[seq*40 + 0]
		; (byte 0 of each LIST_CDS entry is the BlueSCSI internal file index)
		PUSH	SI
		XOR		AH, AH
		MOV		BL, 40
		MUL		BL					; AX = sequential_index * 40
		MOV		SI, OFFSET CDSWMENU_REPLY_BUF
		ADD		SI, AX
		MOV		BL, CS:[SI]			; BL = real BlueSCSI file index
		POP		SI

		; SET_NEXT_CD with BL = real file index
		CALL	CDSWMENU_SEND_SETNEXT
		JC		CDSWMENU_SCSI_ERR

		; Branch on action
		CMP		BYTE PTR CS:[CDSWMENU_ACTION_BOOT], 1
		JE		CDSWMENU_DO_BOOT

		; --- ACTION 1: select + back to main menu ---
		CALL	CLEAR_FIVE_BELOW
		MOV		AL, CDSWMENU_COLOR_STATUS
		CALL	COLOR
		TEXTLOCATION	5, 12
		MOV		SI, OFFSET CDSWMENU_DONE_STR
		CALL	PRINT_TALL
		MOV		AL, 15
		CALL	COLOR

		; Small delay ~2 seconds so the user sees the confirmation
		MOV		CX, 4
CDSWMENU_DONE_DELAY_OUTER:
		PUSH	CX
		MOV		CX, 0FFFFh
CDSWMENU_DONE_DELAY_INNER:
		DEC		CX
		JNZ		CDSWMENU_DONE_DELAY_INNER
		POP		CX
		LOOP	CDSWMENU_DONE_DELAY_OUTER

		JMP		CDSWMENU_BACK_TO_MAIN

		; --- ACTION 2: select + direct boot ---
CDSWMENU_DO_BOOT:
		CALL	CLEAR_FIVE_BELOW
		MOV		AL, CDSWMENU_COLOR_STATUS
		CALL	COLOR
		TEXTLOCATION	5, 12
		MOV		SI, OFFSET CDSWMENU_BOOTING_STR
		CALL	PRINT_TALL
		MOV		AL, 15
		CALL	COLOR

		; BOOT_FROM_SCSI_CD handles WAIT_SCSI_CD_READY, finds FBIOS on the
		; newly-switched CD, loads IO.SYS and jumps to it (never returning on
		; success). On failure it returns here and we fall back to main menu.
		CALL	BOOT_FROM_SCSI_CD
		JMP		CDSWMENU_BACK_TO_MAIN

CDSWMENU_BACK_TO_MAIN:
		CALL	CLEAR_FIVE_BELOW
		RET

		;----------------------------------------------------------------------
CDSWMENU_SCSI_ERR:
		CALL	CLEAR_FIVE_BELOW
		MOV		AL, 12					; bright red
		CALL	COLOR
		TEXTLOCATION	5, 12
		MOV		SI, OFFSET CDSWMENU_SCSI_ERR_STR
		CALL	PRINT_TALL
		MOV		AL, 15
		CALL	COLOR
		CALL	MENU_WAIT_PAD_RELEASE
CDSWMENU_ERR_WAIT:
		CALL	READ_PADA
		AND		AL, 30h
		CMP		AL, 30h
		JE		CDSWMENU_ERR_WAIT
		RET

CDSWMENU_NO_CDS:
		CALL	CLEAR_FIVE_BELOW
		MOV		AL, 14					; yellow
		CALL	COLOR
		TEXTLOCATION	5, 12
		MOV		SI, OFFSET CDSWMENU_NO_CDS_STR
		CALL	PRINT_TALL
		MOV		AL, 15
		CALL	COLOR
		CALL	MENU_WAIT_PAD_RELEASE
CDSWMENU_NOCDS_WAIT:
		CALL	READ_PADA
		AND		AL, 30h
		CMP		AL, 30h
		JE		CDSWMENU_NOCDS_WAIT
		RET

CDSWMENU				ENDP

; Temp storage for the pad bits while we decode them
CDSWMENU_PAD_STORE		DB		0

;==============================================================================
; CDSWMENU_UPDATE_PAGE_COUNT — computes how many entries are visible on the
; current page and stores it in CDSWMENU_NUM_ITEMS.
;   items_this_page = 1 (BACK) + min(ITEMS_PER_PAGE, cd_count - page*PAGE)
;==============================================================================
CDSWMENU_UPDATE_PAGE_COUNT	PROC
		PUSH	AX
		PUSH	BX

		MOV		AL, CS:[CDSWMENU_PAGE]
		MOV		BL, CDSWMENU_ITEMS_PER_PAGE
		MUL		BL						; AX = page * PAGE
		MOV		BL, CS:[CDSWMENU_CD_COUNT]
		SUB		BL, AL					; BL = remaining CDs for this page

		CMP		BL, CDSWMENU_ITEMS_PER_PAGE
		JBE		CDSWMENU_UPC_OK
		MOV		BL, CDSWMENU_ITEMS_PER_PAGE

CDSWMENU_UPC_OK:
		INC		BL						; + 1 for BACK
		MOV		CS:[CDSWMENU_NUM_ITEMS], BL

		POP		BX
		POP		AX
		RET
CDSWMENU_UPDATE_PAGE_COUNT	ENDP

;==============================================================================
; CDSWMENU_PAD_LR_ONLY — left/right detection using ONLY pad bits 2 and 3.
; CaptainYs' PAD_TO_LEFT_RIGHT also tests bits 4 and 5 (buttons A and B),
; which is not what we want because we use those bits to detect "select".
;   Input:  AL = pad byte (active low)
;   Output: BX = -1 (left), 0 (none), 1 (right)
;==============================================================================
CDSWMENU_PAD_LR_ONLY	PROC
		XOR		BX, BX
		TEST	AL, 04h					; bit 2 = left, active low
		JNE		@f
		MOV		BX, -1
		RET
@@:
		TEST	AL, 08h					; bit 3 = right, active low
		JNE		@f
		MOV		BX, 1
@@:
		RET
CDSWMENU_PAD_LR_ONLY	ENDP

;==============================================================================
; CDSWMENU_DRAW_PAGE — draws the menu items for the current page.
;
; Notes:
;  - PRINT_TALL destroys BX (it doesn't save BX in its prologue). So we can't
;    keep a loop counter in BL across PRINT_TALL calls. We use a memory
;    variable CDSWMENU_DP_CURROW for the row index and CX (preserved by
;    PRINT_TALL via push/pop) for the LOOP counter.
;  - Each game is drawn individually so we can pick a per-item color: the
;    currently-active CD (CDSWMENU_ACTIVE_CD) is drawn in green, others blue.
;==============================================================================
CDSWMENU_DRAW_PAGE		PROC
		PUSH	AX
		PUSH	BX
		PUSH	CX
		PUSH	DX
		PUSH	SI
		PUSH	DI

		; Build cleaned game names into CDSWMENU_DISP_BUF
		CALL	CDSWMENU_BUILD_PAGE_BUF

		; Draw BACK TO MAIN MENU in white at (5, 9)
		MOV		AL, CDSWMENU_COLOR_BACK
		CALL	COLOR
		MOV		AX, FIRST_MENU_ITEM_LOCATION
		CALL	LOCATE
		MOV		SI, OFFSET CDSWMENU_BACK_STR
		CALL	PRINT_TALL

		; Compute games on this page = NUM_ITEMS - 1 (exclude BACK)
		MOV		AL, CS:[CDSWMENU_NUM_ITEMS]
		CMP		AL, 1
		JBE		CDSWMENU_DP_DONE		; nothing to draw
		DEC		AL
		XOR		AH, AH
		MOV		CX, AX					; CX = games on this page

		; Reset row counter and start at beginning of DISP_BUF
		MOV		BYTE PTR CS:[CDSWMENU_DP_CURROW], 0
		MOV		SI, OFFSET CDSWMENU_DISP_BUF

CDSWMENU_DP_LOOP:
		PUSH	CX						; preserve loop counter
		PUSH	SI						; preserve current string pointer

		; Compute absolute CD index = page * ITEMS_PER_PAGE + CURROW
		MOV		AL, CS:[CDSWMENU_PAGE]
		MOV		BH, CDSWMENU_ITEMS_PER_PAGE
		MUL		BH						; AX = page * 14
		ADD		AL, CS:[CDSWMENU_DP_CURROW]
		ADC		AH, 0

		; Pick color: green if this is the active CD, else blue
		CMP		AL, CS:[CDSWMENU_ACTIVE_CD]
		JNE		CDSWMENU_DP_BLUE
		MOV		AL, CDSWMENU_COLOR_ACTIVE
		JMP		CDSWMENU_DP_COLORED
CDSWMENU_DP_BLUE:
		MOV		AL, CDSWMENU_COLOR_NAME
CDSWMENU_DP_COLORED:
		CALL	COLOR

		; Position (X = 5, Y = 10 + CURROW)
		MOV		AH, 5
		MOV		AL, 10
		ADD		AL, CS:[CDSWMENU_DP_CURROW]
		CALL	LOCATE

		; Draw the current string (BX gets trashed by PRINT_TALL, don't care —
		; we preserved CX/SI on the stack and we read CURROW from memory)
		CALL	PRINT_TALL

		POP		SI
		CALL	CDSWMENU_SKIP_CSTR
		POP		CX

		INC		BYTE PTR CS:[CDSWMENU_DP_CURROW]
		LOOP	CDSWMENU_DP_LOOP

CDSWMENU_DP_DONE:
		; Restore white so anything drawn after keeps a sane default color
		MOV		AL, 15
		CALL	COLOR
		POP		DI
		POP		SI
		POP		DX
		POP		CX
		POP		BX
		POP		AX
		RET
CDSWMENU_DRAW_PAGE		ENDP

;==============================================================================
; CDSWMENU_SKIP_CSTR — advances DS:SI past the current NUL-terminated string.
; Same contract as CaptainYs SKIP_CSTR_DS_SI (which is a private helper of
; BOOTMENU.ASM), duplicated here to avoid external symbol conflicts.
;==============================================================================
CDSWMENU_SKIP_CSTR		PROC
		INC		SI
		CMP		BYTE PTR [SI-1], 0
		JNE		CDSWMENU_SKIP_CSTR
		RET
CDSWMENU_SKIP_CSTR		ENDP

;==============================================================================
; CDSWMENU_BUILD_PAGE_BUF — fills CDSWMENU_DISP_BUF with the cleaned names of
; the games on the current page, as a sequence of NUL-terminated strings.
;==============================================================================
CDSWMENU_BUILD_PAGE_BUF		PROC
		PUSH	AX
		PUSH	BX
		PUSH	CX
		PUSH	DX
		PUSH	SI
		PUSH	DI

		PUSH	CS
		POP		DS
		PUSH	CS
		POP		ES

		; DI -> start of DISP_BUF
		MOV		DI, OFFSET CDSWMENU_DISP_BUF

		; BL = row offset within the page (0..ITEMS_PER_PAGE-1)
		MOV		BL, 0
CDSWMENU_BPB_LOOP:
		CMP		BL, CDSWMENU_ITEMS_PER_PAGE
		JAE		CDSWMENU_BPB_DONE

		; Absolute CD index = page * ITEMS_PER_PAGE + BL
		MOV		AL, CS:[CDSWMENU_PAGE]
		MOV		BH, CDSWMENU_ITEMS_PER_PAGE
		MUL		BH
		ADD		AL, BL
		ADC		AH, 0

		; Stop if we've gone past cd_count
		CMP		AL, CS:[CDSWMENU_CD_COUNT]
		JAE		CDSWMENU_BPB_DONE

		; Clean into CDSWMENU_CLEAN_BUF (AL = abs idx), preserves BX
		CALL	CDSWMENU_CLEAN_NAME_FOR_INDEX

		; Copy CLEAN_BUF into DISP_BUF (up to and including the NUL)
		MOV		SI, OFFSET CDSWMENU_CLEAN_BUF
CDSWMENU_BPB_COPY:
		MOV		AL, [SI]
		MOV		[DI], AL
		INC		SI
		INC		DI
		CMP		AL, 0
		JNE		CDSWMENU_BPB_COPY

		INC		BL
		JMP		CDSWMENU_BPB_LOOP

CDSWMENU_BPB_DONE:
		POP		DI
		POP		SI
		POP		DX
		POP		CX
		POP		BX
		POP		AX
		RET
CDSWMENU_BUILD_PAGE_BUF		ENDP

;==============================================================================
; CDSWMENU_CLEAN_NAME_FOR_INDEX
;   Input:  AL = absolute CD index (0..cd_count-1)
;   Output: CDSWMENU_CLEAN_BUF contains the cleaned, NUL-terminated display name
;
; Rules:
;   - Source: reply_buf[AL*40 + 2] (null-terminated, max 32 chars)
;   - If the name starts with digits followed by '_', skip the prefix
;     (e.g. "01_RAINBOW" -> "RAINBOW")
;   - Copy chars until '.' (extension) or NUL or buffer/display limit
;   - Keep only A-Z, 0-9, space; replace everything else with space
;     (handles _, [, ], (, ), {, }, -, +, etc.)
;   - Collapse consecutive spaces, trim leading/trailing spaces
;   - Uppercase
;   - Truncate at CDSWMENU_DISPLAY_WIDTH (30 chars) for screen safety
;==============================================================================
CDSWMENU_CLEAN_NAME_FOR_INDEX	PROC
		PUSH	AX
		PUSH	BX
		PUSH	CX
		PUSH	DX
		PUSH	SI
		PUSH	DI

		; Compute source pointer: reply_buf + AL*40 + 2
		XOR		AH, AH
		MOV		BL, 40
		MUL		BL						; AX = AL * 40
		ADD		AX, OFFSET CDSWMENU_REPLY_BUF
		ADD		AX, 2
		MOV		SI, AX					; DS:SI -> raw filename

		; DI -> clean buffer
		MOV		DI, OFFSET CDSWMENU_CLEAN_BUF

		; Remember original SI for restart-if-no-underscore
		MOV		BX, SI

		; If first char is digit, try to skip "NN_"
		MOV		AL, [SI]
		CALL	CDSWMENU_IS_DIGIT
		CMP		AH, 1
		JNE		CDSWMENU_CN_COPY_PHASE

		; Scan for '_' among leading digits (max 8 chars lookahead)
		MOV		CX, 8
CDSWMENU_CN_SCAN_LOOP:
		MOV		AL, [SI]
		CMP		AL, 0
		JE		CDSWMENU_CN_NO_UNDERSCORE
		CMP		AL, '_'
		JE		CDSWMENU_CN_FOUND_UNDERSCORE
		CALL	CDSWMENU_IS_DIGIT
		CMP		AH, 1
		JNE		CDSWMENU_CN_NO_UNDERSCORE
		INC		SI
		LOOP	CDSWMENU_CN_SCAN_LOOP
CDSWMENU_CN_NO_UNDERSCORE:
		MOV		SI, BX
		JMP		CDSWMENU_CN_COPY_PHASE

CDSWMENU_CN_FOUND_UNDERSCORE:
		INC		SI						; skip past '_'

CDSWMENU_CN_COPY_PHASE:
		; CX = max chars to write (buffer safety)
		; DX tracks how many visible chars were written (for display width limit)
		MOV		CX, CDSWMENU_CLEAN_NAME_MAX - 1
		XOR		DX, DX				; DX = visible char count

CDSWMENU_CN_COPY_LOOP:
		MOV		AL, [SI]
		CMP		AL, 0
		JE		CDSWMENU_CN_COPY_DONE
		CMP		AL, '.'
		JE		CDSWMENU_CN_COPY_DONE

		; --- Character sanitization ---
		; Keep: A-Z, a-z, 0-9, space
		; Replace everything else with space (_, [, ], (, ), {, }, -, +, etc.)

		; Check if already a space
		CMP		AL, ' '
		JE		CDSWMENU_CN_IS_SAFE

		; Check if digit (0-9)
		CMP		AL, '0'
		JB		CDSWMENU_CN_REPLACE
		CMP		AL, '9'
		JBE		CDSWMENU_CN_IS_SAFE

		; Check if uppercase (A-Z)
		CMP		AL, 'A'
		JB		CDSWMENU_CN_REPLACE
		CMP		AL, 'Z'
		JBE		CDSWMENU_CN_IS_SAFE

		; Check if lowercase (a-z) -> uppercase it
		CMP		AL, 'a'
		JB		CDSWMENU_CN_REPLACE
		CMP		AL, 'z'
		JA		CDSWMENU_CN_REPLACE
		SUB		AL, 20h				; to uppercase
		JMP		CDSWMENU_CN_IS_SAFE

CDSWMENU_CN_REPLACE:
		MOV		AL, ' '

CDSWMENU_CN_IS_SAFE:
		; Collapse multiple spaces: if this is a space AND the previous char
		; was also a space (or we're at position 0), skip it
		CMP		AL, ' '
		JNE		CDSWMENU_CN_NOT_DUP_SP
		CMP		DX, 0
		JE		CDSWMENU_CN_SKIP_CHAR	; skip leading spaces
		CMP		BYTE PTR [DI-1], ' '
		JE		CDSWMENU_CN_SKIP_CHAR	; skip duplicate spaces
CDSWMENU_CN_NOT_DUP_SP:

		; Check display width limit
		CMP		DX, CDSWMENU_DISPLAY_WIDTH
		JAE		CDSWMENU_CN_COPY_DONE

		; Store the char
		MOV		[DI], AL
		INC		DI
		INC		DX
CDSWMENU_CN_SKIP_CHAR:
		INC		SI
		LOOP	CDSWMENU_CN_COPY_LOOP

CDSWMENU_CN_COPY_DONE:
		; Trim trailing space(s) before NUL
		CMP		DX, 0
		JE		CDSWMENU_CN_TERMINATE
CDSWMENU_CN_TRIM_LOOP:
		CMP		BYTE PTR [DI-1], ' '
		JNE		CDSWMENU_CN_TERMINATE
		DEC		DI
		DEC		DX
		CMP		DX, 0
		JNE		CDSWMENU_CN_TRIM_LOOP

CDSWMENU_CN_TERMINATE:
		; Append NUL terminator
		MOV		BYTE PTR [DI], 0

		POP		DI
		POP		SI
		POP		DX
		POP		CX
		POP		BX
		POP		AX
		RET
CDSWMENU_CLEAN_NAME_FOR_INDEX	ENDP

;==============================================================================
; CDSWMENU_IS_DIGIT — check if AL is '0'..'9', sets AH=1 if yes, 0 otherwise
;==============================================================================
CDSWMENU_IS_DIGIT		PROC
		CMP		AL, '0'
		JB		CDSWMENU_ID_NO
		CMP		AL, '9'
		JA		CDSWMENU_ID_NO
		MOV		AH, 1
		RET
CDSWMENU_ID_NO:
		MOV		AH, 0
		RET
CDSWMENU_IS_DIGIT		ENDP

;==============================================================================
; CDSWMENU_DRAW_PAGE_INDICATOR — draws "PAGE X / Y" at fixed location
;==============================================================================
CDSWMENU_DRAW_PAGE_INDICATOR	PROC
		PUSH	AX
		PUSH	BX
		PUSH	CX
		PUSH	DX
		PUSH	SI
		PUSH	DI

		; Only show the indicator if there are 2+ pages
		MOV		AL, CS:[CDSWMENU_NUM_PAGES]
		CMP		AL, 2
		JB		CDSWMENU_DPI_DONE

		MOV		AL, CDSWMENU_COLOR_STATUS
		CALL	COLOR

		; "PAGE " at (50, 6) — same row as the title, right side
		TEXTLOCATION	50, 6
		MOV		SI, OFFSET CDSWMENU_PAGE_STR
		CALL	PRINT_TALL

		; Current page number (1-based) at (55, 6)
		MOV		AL, CS:[CDSWMENU_PAGE]
		INC		AL
		XOR		AH, AH
		CALL	CDSWMENU_ITOA_SMALL
		MOV		AH, 55
		MOV		AL, 6
		CALL	LOCATE
		MOV		SI, OFFSET CDSWMENU_NUM_BUF
		CALL	PRINT_TALL

		; " / " at (58, 6)
		MOV		AH, 58
		MOV		AL, 6
		CALL	LOCATE
		MOV		SI, OFFSET CDSWMENU_PAGE_OF_STR
		CALL	PRINT_TALL

		; Total pages at (61, 6)
		MOV		AL, CS:[CDSWMENU_NUM_PAGES]
		XOR		AH, AH
		CALL	CDSWMENU_ITOA_SMALL
		MOV		AH, 61
		MOV		AL, 6
		CALL	LOCATE
		MOV		SI, OFFSET CDSWMENU_NUM_BUF
		CALL	PRINT_TALL

CDSWMENU_DPI_DONE:
		POP		DI
		POP		SI
		POP		DX
		POP		CX
		POP		BX
		POP		AX
		RET
CDSWMENU_DRAW_PAGE_INDICATOR	ENDP

;==============================================================================
; CDSWMENU_ITOA_SMALL — converts AX (0..999) to decimal string in CDSWMENU_NUM_BUF
; Writes NUL-terminated ASCII.
;==============================================================================
CDSWMENU_ITOA_SMALL		PROC
		PUSH	AX
		PUSH	BX
		PUSH	CX
		PUSH	DX
		PUSH	DI

		MOV		DI, OFFSET CDSWMENU_NUM_BUF

		; Handle 0 explicitly
		CMP		AX, 0
		JNE		CDSWMENU_IA_NONZERO
		MOV		BYTE PTR [DI], '0'
		MOV		BYTE PTR [DI+1], 0
		JMP		CDSWMENU_IA_DONE

CDSWMENU_IA_NONZERO:
		; Push digits onto stack
		XOR		CX, CX
		MOV		BX, 10
CDSWMENU_IA_DIV:
		XOR		DX, DX
		DIV		BX
		PUSH	DX
		INC		CX
		CMP		AX, 0
		JNE		CDSWMENU_IA_DIV

		; Pop and store
CDSWMENU_IA_POP:
		POP		DX
		ADD		DL, '0'
		MOV		[DI], DL
		INC		DI
		LOOP	CDSWMENU_IA_POP

		MOV		BYTE PTR [DI], 0

CDSWMENU_IA_DONE:
		POP		DI
		POP		DX
		POP		CX
		POP		BX
		POP		AX
		RET
CDSWMENU_ITOA_SMALL		ENDP

;==============================================================================
; CDSWMENU_SEND_COUNT — sends COUNT_CDS (0xDA), receives 1 byte into reply_buf
;==============================================================================
CDSWMENU_SEND_COUNT		PROC
		PUSH	BX
		PUSH	CX
		PUSH	DX
		PUSH	SI
		PUSH	DI
		PUSH	EDI

		MOV		CL, CS:[SCSI_ID_CDROM]
		AND		CL, 7

		PUSH	CS
		POP		DS
		MOV		SI, OFFSET CDSWMENU_CMD_COUNT

		MOV		AX, DS
		MOVZX	EDI, AX
		SHL		EDI, 4
		MOVZX	EAX, WORD PTR CDSWMENU_REPLY_BUF_OFS
		ADD		EDI, EAX

		CALL	SCSI_COMMAND

		POP		EDI
		POP		DI
		POP		SI
		POP		DX
		POP		CX
		POP		BX
		RET
CDSWMENU_SEND_COUNT		ENDP

;==============================================================================
; CDSWMENU_SEND_LIST — sends LIST_CDS (0xD7), receives N*40 bytes into reply_buf
;==============================================================================
CDSWMENU_SEND_LIST		PROC
		PUSH	BX
		PUSH	CX
		PUSH	DX
		PUSH	SI
		PUSH	DI
		PUSH	EDI

		MOV		CL, CS:[SCSI_ID_CDROM]
		AND		CL, 7

		PUSH	CS
		POP		DS
		MOV		SI, OFFSET CDSWMENU_CMD_LIST

		MOV		AX, DS
		MOVZX	EDI, AX
		SHL		EDI, 4
		MOVZX	EAX, WORD PTR CDSWMENU_REPLY_BUF_OFS
		ADD		EDI, EAX

		CALL	SCSI_COMMAND

		POP		EDI
		POP		DI
		POP		SI
		POP		DX
		POP		CX
		POP		BX
		RET
CDSWMENU_SEND_LIST		ENDP

;==============================================================================
; CDSWMENU_SEND_SETNEXT — sends SET_NEXT_CD (0xD8) with CDB[1] = file index in BL
;==============================================================================
CDSWMENU_SEND_SETNEXT	PROC
		PUSH	BX
		PUSH	CX
		PUSH	DX
		PUSH	SI
		PUSH	DI
		PUSH	EDI

		MOV		CS:[CDSWMENU_CMD_SETNEXT + 1], BL

		MOV		CL, CS:[SCSI_ID_CDROM]
		AND		CL, 7

		PUSH	CS
		POP		DS
		MOV		SI, OFFSET CDSWMENU_CMD_SETNEXT

		MOV		AX, DS
		MOVZX	EDI, AX
		SHL		EDI, 4
		MOVZX	EAX, WORD PTR CDSWMENU_REPLY_BUF_OFS
		ADD		EDI, EAX

		CALL	SCSI_COMMAND

		POP		EDI
		POP		DI
		POP		SI
		POP		DX
		POP		CX
		POP		BX
		RET
CDSWMENU_SEND_SETNEXT	ENDP

;------------------------------------------------------------------------------
CDSWMENU_REPLY_BUF_OFS	DW		OFFSET CDSWMENU_REPLY_BUF
