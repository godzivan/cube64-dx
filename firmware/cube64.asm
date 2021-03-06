	;;
	;; Gamecube to N64 converter: use your gamecube controllers with an N64 console
	;; Copyright (C) 2004 Micah Dowty <micah@navi.cx>
	;;               2011 Jacques Gagnon <darthcloud@gmail.com>
	;;
	;;   This program is free software; you can redistribute it and/or modify
	;;   it under the terms of the GNU General Public License as published by
	;;   the Free Software Foundation; either version 2 of the License, or
	;;   (at your option) any later version.
	;;
	;; This firmware is designed to run on a PIC12F683 microcontroller
	;; clocked at 20 MHz.
	;;
	;; See n64gc_comm.inc for code and documentation related to the protocol
	;; used between here, the N64, and the Gamecube.
	;;
	;; This file doesn't implement all of the N64 controller protocol, but
	;; it should correctly emulate an official N64 controller with rumble pak.
	;; It might not respond to unusual circumstances the same as a real N64
	;; controller would, both due to potential gaps in the reverse engineering,
	;; and due to corners cut in the algorithm implementation to fit it on
	;; this microcontroller. In particular, only a partial implementation of
	;; the CRC algorithm is used and the address check bits are ignored.
	;;

	errorlevel -302

	;; Definitions for the PIC12F683 version
	ifdef  __12F683
	  	#include p12f683.inc

		__CONFIG  _FCMEN_OFF & _IESO_OFF & _BOD_OFF & _CPD_OFF & _CP_OFF & _MCLRE_OFF & _PWRTE_OFF & _WDT_ON & _HS_OSC

		#define N64_PIN		GPIO, 0
		#define N64_TRIS	TRISIO, 0
		#define	GAMECUBE_PIN	GPIO, 1
		#define	GAMECUBE_TRIS	TRISIO, 1
		#define SW_PIN		GPIO, 2
		#define SW_TRIS		TRISIO, 2
		#define RAM_START	0x20

io_init		macro
		bcf	STATUS, RP0		; Clear output latches.
		clrf	GPIO
		movlw	0x0F		; Disable the comparator.
		movwf	CMCON0
		bsf	STATUS, RP0
		movlw	0x03		; The two controller pins begin as inputs.
		movwf	TRISIO
		clrf	ANSEL
		bcf	STATUS, RP0
		endm

	else
		messg	"Unsupported processor"
	endif

	#include n64gc_comm.inc

	;; Magic word and the address it should be at in the EEPROM,
	;; as a big-endian 16-bit value.
	;;
	;; This is used to identify the contents of our EEPROM as ours,
	;; so that if this firmware is installed on a chip with a blank
	;; EEPROM or one with different data in it, we reinitialize it.
	;; Change this value if the EEPROM data format changes.
	;;


	#define	EEPROM_MAGIC_WORD	0xEC70
	#define EEPROM_MAGIC_ADDR	0x40
	#define EEPROM_LAST_KEY_MAP	0x50
	#define EEPROM_PASS_MODE	0x51
	;; Reset and interrupt vectors
	org 0
	goto	startup
	org 4
	retfie

	;; Variables.
	cblock	RAM_START
		temp
		temp2
		byte_count
		bit_count
		bus_byte_count
		flags
		config_flags
		virtual_button
		calibration_count
		rumble_feedback_count
		remap_source_button
		controller_id

		;; Stored calibration for each gamecube axis
		joystick_x_calibration
		joystick_y_calibration
		cstick_x_calibration
		cstick_y_calibration
		left_calibration
		right_calibration

		;; These four items must be contiguous.
		;; Note that n64_command and n64_bus_address point to the same memory.
		;; This is explained in the bus write receive code near n64_wait_for_command.
		n64_command:0
		n64_bus_address:2
		n64_bus_packet:.32
		n64_crc

		n64_id_buffer:3
		gamecube_buffer:8
		n64_status_buffer:4

		active_key_map
		pass_mode
	endc

	;; The rumble motor should be on
	#define	FLAG_RUMBLE_MOTOR_ON		flags, 0

	;; We're waiting for a button to be released, cleared when no buttons are pressed
	#define FLAG_WAITING_FOR_RELEASE	flags, 1

	;; Flag for detecting when all buttons are released
	#define	FLAG_NO_VIRTUAL_BTNS		flags, 2

	;; Is the GC controller a Wavebird?
	#define	WAVEBIRD					flags, 3

	;; Wavebird association state.
	#define WAVEBIRD_ASSOCIATED			flags, 4
	
	;; Passthrough mode flag.
	#define	PASS_MODE					pass_mode, 0
	
	;; Set when we are waiting for item selection in the top config menu.
	#define FLAG_TOP_CONFIG_MENU		config_flags, 0

	;; Set when we are waiting for user input in the adapter mode submenu.
	#define FLAG_MODE_SUBMENU			config_flags, 1

	;; Set when we are waiting for user input in the button layout submenu.
	#define FLAG_LAYOUT_SUBMENU			config_flags, 2

	;; Set when we're waiting for the source and destination keys, respectively, in a remap combo
	#define	FLAG_REMAP_SOURCE_WAIT		config_flags, 6
	#define	FLAG_REMAP_DEST_WAIT		config_flags, 7


	;; *******************************************************************************
	;; ******************************************************  Initialization  *******
	;; *******************************************************************************

startup
	io_init

	n64gc_init
	clrf	flags
	clrf	config_flags
	clrf	calibration_count
	clrf	rumble_feedback_count
	clrf	active_key_map
	bsf		SW_PIN			; Disable accessory controller.
	
	;;Set controller id to occupied slot.
	movlw	0x01
	movwf	controller_id

	movlw	.34			; Reset bus_byte_count to 34. Keeping this set beforehand
	movwf	bus_byte_count		;   saves a few precious cycles in receiving bus writes.


	;; We use the watchdog to implicitly implement controller probing.
	;; If we have no gamecube controller attached, gamecube_poll_status
	;; will never return. We therefore never get around to answering the
	;; N64's requests. This breaks down if we start up with the gamecube
	;; controller plugged in but it's unplugged while the N64 is idle, but
	;; the N64 should be polling us pretty constantly.
	;;
	;; The watchdog timeout therefore sets how often we retry in our search
	;; for a responding gamecube controller. The default is a little over
	;; 2 seconds. This changes the prescaler to 1:16, giving us a nominal
	;; watchdog timeout of 288ms.
	clrwdt
	movlw	0xFC
	bsf	STATUS, RP0
	movwf	OPTION_REG
	bcf	STATUS, RP0

	;; Check our EEPROM for validity, and reset it if it's blank or corrupted
	call	validate_eeprom


	;; To detect if the GC controller is a Wavebird, we send a identify command (0x00)
	;; to the controller. We then follow with n64 task since the controller won't be reponding
	;; any command for a while.
gc_controller_id_check
	call	gamecube_get_id
	call	n64_wfc_empty_buffer

	;; If the controller is a Wavebird we need to do some special initialization process first.
	;; else we have a standard controller and we are ready to poll status.
	btfss	WAVEBIRD
	goto	gc_controller_ready

	;; If we have an Wavebird associated with the receiver we are ready to init it.
	;; else we go back reading the controller id.
	btfss	WAVEBIRD_ASSOCIATED
	goto	gc_controller_id_check

	call	gamecube_init_wavebird
	call	n64_wfc_empty_buffer


	;; Calibrate the controller now since before that the Wavebird would not have repond to poll status.
	;; Note that we have to continue on with n64_translate_status and n64_wait_for_command
	;; because the gamecube controller won't be ready for another poll immediately.
	;; We also check the adapter mode select keys to see if user want to change mode on boot.
gc_controller_ready
	call	gamecube_poll_status
	call	gamecube_reset_calibration
	call	accept_mode_select
	call	n64_translate_status
	call	n64_wait_for_command


main_loop
	call	update_rumble_feedback	; Give feedback for remapping operations using the rumble motor
	call	gamecube_poll_status	; The gamecube poll takes place during the dead period
	call	n64_translate_status	;   between incoming N64 commands, hopefully
	call	n64_wait_for_command
	goto	main_loop


	;; *******************************************************************************
	;; ******************************************************  Axis Calibration  *****
	;; *******************************************************************************

	;; Store calibration values for one gamecube axis. This takes its
	;; actual neutral position from the gamecube_buffer, and is given
	;; its ideal neutral position as a parameter. The resulting calibration
	;; is added to the axis later, with clamping to prevent rollover.
store_calibration macro axis_byte, calibration, ideal_neutral
	movf	gamecube_buffer + axis_byte, w
	sublw	ideal_neutral
	movwf	calibration
	endm


	;; Add the stored neutral values to an axis to calibrate it, clamping
	;; it in the event of an overflow.
apply_calibration macro axis_byte, calibration
	local	negative
	local	done

	movf	calibration, w		; Add the calibration
	addwf	gamecube_buffer + axis_byte, f
	btfsc	calibration, 7		; Test whether the value we just added was negative
	goto	negative

	movlw	0xFF			; It was positive, clamp to 0xFF if we carried
	btfsc	STATUS, C
	movwf	gamecube_buffer + axis_byte
	goto	done

negative
	btfss	STATUS, C		; It was negative, clamp to 0 if we borrowed (C=0)
	clrf	gamecube_buffer + axis_byte

done
	endm


	;; Store calibration values for each axis. The controller's joysticks should
	;; be centered and the L and R buttons should be released when this is called.
	;; We assume this is true at startup, and it should be true when the user invokes
	;; it by holding down X, Y, and Start.
gamecube_reset_calibration
	store_calibration	GC_JOYSTICK_X,	joystick_x_calibration,	0x80
	store_calibration	GC_JOYSTICK_Y,	joystick_y_calibration,	0x80
	store_calibration	GC_CSTICK_X,	cstick_x_calibration,	0x80
	store_calibration	GC_CSTICK_Y,	cstick_y_calibration,	0x80
	store_calibration	GC_L_ANALOG,	left_calibration,	0x00
	store_calibration	GC_R_ANALOG,	right_calibration,	0x00
	return


	;; This runs at the beginning of each key remap to check for the X+Y+Start
	;; calibration sequence. Since we don't have a good way to measure out exactly
	;; 3 seconds to emulate the gamecube's behavior, we just count the number of
	;; status polls the keys are held down for. We don't know the exact polling rate,
	;; but on most games 30 polls should be around a second, which is long enough
	;; to avoid accidentally recalibrating.
check_calibration_combo
	btfss	gamecube_buffer + GC_X
	goto	no_calibration_combo
	btfss	gamecube_buffer + GC_Y
	goto	no_calibration_combo
	btfss	gamecube_buffer + GC_START
	goto	no_calibration_combo

	incf	calibration_count, f
	movf	calibration_count, w
	xorlw	.30
	btfsc	STATUS, Z
	goto	gamecube_reset_calibration
	return

no_calibration_combo
	clrf	calibration_count
	return


	;; *******************************************************************************
	;; **********************************************  Static Button/Axis Mappings  **
	;; *******************************************************************************

	;; This static mapping layer translates axes directly from N64 to gamecube, and
	;; it translates buttons via an intermetdiate virtual button ID that's used by
	;; the dynamic mapping layer. This layer defines our default mappings.

	;; Button IDs. These are a superset of the gamecube and N64, without any correspondance
	;; with the wire protocol used by either. They're used as intermediate values when
	;; translating from gamecube to N64. These IDs are used as indices into the remapping
	;; table stored in our on-chip EEPROM.

	#define	BTN_A		0x00
	#define	BTN_B		0x01
	#define	BTN_X		0x02
	#define	BTN_Y		0x03
	#define	BTN_Z		0x04
	#define	BTN_R		0x05
	#define	BTN_L		0x06
	#define	BTN_START	0x07
	#define	BTN_D_LEFT	0x08
	#define	BTN_D_RIGHT	0x09
	#define	BTN_D_DOWN	0x0A
	#define	BTN_D_UP	0x0B
	#define	BTN_C_LEFT	0x0C
	#define	BTN_C_RIGHT	0x0D
	#define	BTN_C_DOWN	0x0E
	#define	BTN_C_UP	0x0F

	#define	NUM_VIRTUAL_BUTTONS	0x10
	#define NUM_EEPROM_DATA		0x40

	#define AXIS_DEAD_ZONE		0x0A


	;; Map a gamecube button to a virtual button, and eventually to an N64 button
map_button_from macro src_byte, src_bit, virtual
	movlw	virtual
	btfsc	gamecube_buffer+src_byte, src_bit
	call	remap_virtual_button
	endm

	;; Map a virtual button to an N64 button. If the indicated button is the one
	;; currently in virtual_button, sets the corresponding N64 bit and returns.
map_button_to	macro virtual, dest_byte, dest_bit
	local	next
	movf	virtual_button, w
	xorlw	virtual
	btfss	STATUS, Z
	goto	next
	bsf	n64_status_buffer+dest_byte, dest_bit
	return
next
	endm

	;; Map an 8-bit 0x80-centered axis to an 8-bit signed axis.
	;; Doesn't allow any remapping.
map_axis macro src_byte, dest_byte
	local	negative_axis_value
	local	load_gc_buffer_to_n64

	movlw	0x80							; Sign GC axis value.
	subwf	gamecube_buffer+src_byte, f

	movlw	AXIS_DEAD_ZONE

	btfsc	gamecube_buffer+src_byte, 7		; Check value sign.
	goto	negative_axis_value

	;; Current value is positive.
	subwf	gamecube_buffer+src_byte, f
	btfsc	gamecube_buffer+src_byte, 7
	clrf	gamecube_buffer+src_byte
	goto	load_gc_buffer_to_n64

	;; Current value is negative.
negative_axis_value
	addwf	gamecube_buffer+src_byte, f
	btfss	gamecube_buffer+src_byte, 7
	clrf	gamecube_buffer+src_byte

load_gc_buffer_to_n64
	movf	gamecube_buffer+src_byte, w
	movwf	n64_status_buffer+dest_byte
	endm

	;; Map an 8-bit 0x80-centered axis to two virtual buttons,
	;; given lower and upper thresholds.
map_button_axis macro axis_byte, lower_virtual, upper_virtual, lower_thresh, upper_thresh
	movlw	lower_thresh
	subwf	gamecube_buffer+axis_byte, w		; Axis - lower_thresh
	movlw	lower_virtual
	btfss	STATUS, C
	call	remap_virtual_button			; C=0, B=1, lower_thresh > axis
	movlw	upper_thresh+1
	subwf	gamecube_buffer+axis_byte, w		; Axis - (upper_thresh+1)
	movlw	upper_virtual
	btfsc	STATUS, C
	call	remap_virtual_button			; C=1, B=0, (upper_thresh+1) <= axis
	endm


	;; Copy status from the gamecube buffer to the N64 buffer. This first
	;; stage maps all axes, and maps gamecube buttons to virtual buttons.
n64_translate_status
	clrf	n64_status_buffer+0	; Start out with everything zeroed...
	clrf	n64_status_buffer+1
	clrf	n64_status_buffer+2
	clrf	n64_status_buffer+3
	bsf	FLAG_NO_VIRTUAL_BTNS

	call	check_calibration_combo

	apply_calibration	GC_JOYSTICK_X,	joystick_x_calibration
	apply_calibration	GC_JOYSTICK_Y,	joystick_y_calibration
	apply_calibration	GC_CSTICK_X,	cstick_x_calibration
	apply_calibration	GC_CSTICK_Y,	cstick_y_calibration
	apply_calibration	GC_L_ANALOG,	left_calibration
	apply_calibration	GC_R_ANALOG,	right_calibration

	call	check_remap_combo	; Must be after calibration, since it uses analog L and R values

	map_button_from	GC_A,		BTN_A
	map_button_from	GC_B,		BTN_B
	map_button_from	GC_Z,		BTN_Z
	map_button_from	GC_R,		BTN_R
	map_button_from	GC_L,		BTN_L
	map_button_from	GC_START,	BTN_START

	map_button_from	GC_X,		BTN_X
	map_button_from	GC_Y,		BTN_Y

	map_button_from	GC_D_LEFT,	BTN_D_LEFT
	map_button_from	GC_D_RIGHT,	BTN_D_RIGHT
	map_button_from	GC_D_UP,	BTN_D_UP
	map_button_from	GC_D_DOWN,	BTN_D_DOWN

	map_axis	GC_JOYSTICK_X,	N64_JOYSTICK_X
	map_axis	GC_JOYSTICK_Y,	N64_JOYSTICK_Y

	map_button_axis	GC_CSTICK_X,    BTN_C_LEFT,	BTN_C_RIGHT,	0x50, 0xB0
	map_button_axis	GC_CSTICK_Y,    BTN_C_DOWN,	BTN_C_UP,	0x50, 0xB0

	btfsc	FLAG_NO_VIRTUAL_BTNS
	bcf	FLAG_WAITING_FOR_RELEASE
	return


	;; This is called by remap_virtual_button to convert a virtual button code,
	;; in virtual_button, to a set bit in the N64 status packet.
set_virtual_button
	map_button_to	BTN_D_RIGHT,	N64_D_RIGHT
	map_button_to	BTN_D_LEFT,	N64_D_LEFT
	map_button_to	BTN_D_DOWN,	N64_D_DOWN
	map_button_to	BTN_D_UP,	N64_D_UP

	map_button_to	BTN_X,		N64_C_DOWN
	map_button_to	BTN_Y,		N64_B

	map_button_to	BTN_START,	N64_START
	map_button_to	BTN_Z,		N64_Z
	map_button_to	BTN_B,		N64_B
	map_button_to	BTN_A,		N64_A
	map_button_to	BTN_R,		N64_R
	map_button_to	BTN_L,		N64_L

	map_button_to	BTN_C_RIGHT,	N64_C_RIGHT
	map_button_to	BTN_C_LEFT,	N64_C_LEFT
	map_button_to	BTN_C_DOWN,	N64_C_DOWN
	map_button_to	BTN_C_UP,	N64_C_UP
	return


	;; *******************************************************************************
	;; *************************************************  Dynamic Button Remapping  **
	;; *******************************************************************************

	;; This is called each time we poll status, for each virtual button that's pressed.
	;; Here we get a virtual button code in 'w'. Normally we remap this via the EEPROM
	;; and pass the code on to set_virtual_button.
	;;
	;; If we're awaiting a keypress for remapping purposes, this doesn't give any virtual
	;; button presses to the N64.
	;;
	;; Our EEPROM starts with one byte per virtual button, containing the virtual button
	;; code its mapped to. By default, each byte just contains its address, mapping all
	;; virtual buttons to themselves.
remap_virtual_button
	;; Remember that a button is pressed, so we can detect when all have been released
	bcf	FLAG_NO_VIRTUAL_BTNS

	;; Leave now if we're waiting for buttons to be released
	btfsc	FLAG_WAITING_FOR_RELEASE
	return

	;; Accept buttons presses if we're waiting for one
	btfsc	FLAG_TOP_CONFIG_MENU
	goto	accept_config_menu_select
	btfsc	FLAG_REMAP_SOURCE_WAIT
	goto	accept_remap_source
	btfsc	FLAG_REMAP_DEST_WAIT
	goto	accept_remap_dest
	btfsc	FLAG_MODE_SUBMENU
	goto	accept_mode_select
	btfsc	FLAG_LAYOUT_SUBMENU
	goto	accept_layout_select

	;; Pass anything else on to the N64, mapped through the EEPROM first
	call	eeread
	movwf	virtual_button
	goto	set_virtual_button


	;; Looks for the key combinations we use to change button mapping
check_remap_combo
	;; Leave now if we're waiting for buttons to be released
	btfsc	FLAG_WAITING_FOR_RELEASE
	return

	;; Key combinations require that the L and R buttons be mostly pressed.
	;; but that the end stop buttons aren't pressed.
	;; Ensure the high bit of each axis is set and that the buttons are cleared.
	btfss	gamecube_buffer + GC_L_ANALOG, 7
	return
	btfss	gamecube_buffer + GC_R_ANALOG, 7
	return
	btfsc	gamecube_buffer + GC_L
	return
	btfsc	gamecube_buffer + GC_R
	return

	;; Enter config menu if third key is Start.
	btfsc	gamecube_buffer + GC_START
	goto	pressed_config_menu_combo
	return


	;; The config menu button combo was pressed. Give feedback via the rumble motor,
	;; and await button presses from the user indicating which menu option they want
	;; access to. Selection is handled into remap_virtual_button since we need virutal
	;; button codes.
pressed_config_menu_combo
	bsf 	FLAG_WAITING_FOR_RELEASE
	bsf		FLAG_TOP_CONFIG_MENU
	goto	start_rumble_feedback

	;; The remap button combo was pressed. Give feedback via the rumble motor,
	;; and await button presses from the user indicating what they want to remap.
	;; We actually read the source and destination keys in remap_virtual_button,
	;; since we need virtual button codes.
pressed_remap_combo
	bsf	FLAG_WAITING_FOR_RELEASE
	bsf	FLAG_REMAP_SOURCE_WAIT
	goto	start_rumble_feedback


	;; The reset combo was pressed. Reset the EEPROM contents of the current active button
	;; layout, and use the rumble motor for feedback if possible.
pressed_reset_combo
	bsf	FLAG_WAITING_FOR_RELEASE
	call	reset_active_eeprom_layout
	bcf	STATUS, RP0
	goto	start_rumble_feedback

	;; The adapter mode submenu was selected in the config menu.
pressed_mode_submenu
	bsf	FLAG_WAITING_FOR_RELEASE
	bsf	FLAG_MODE_SUBMENU
	goto	start_rumble_feedback

	;; The button layout submenu was selected in the config menu.
pressed_layout_submenu
	bsf	FLAG_WAITING_FOR_RELEASE
	bsf	FLAG_LAYOUT_SUBMENU
	goto	start_rumble_feedback

	;; Set the adapter mode to empty controller slot.
pressed_mode_empty
	bsf	FLAG_WAITING_FOR_RELEASE
	movlw	0x02
	movwf	controller_id
	goto	start_rumble_feedback

	;; Set the adapter mode to rumble pak.
pressed_mode_rumble
	bsf	FLAG_WAITING_FOR_RELEASE
	movlw	0x01
	movwf	controller_id
	goto	start_rumble_feedback

	;; Load custom up.
pressed_preset_up
	bsf	FLAG_WAITING_FOR_RELEASE
	movlw	0x00
	movwf	active_key_map
	goto save_active_key_layout

	;; Load custom layout left.
pressed_preset_left
	bsf	FLAG_WAITING_FOR_RELEASE
	movlw	0x10
	movwf	active_key_map
	goto save_active_key_layout

	;; Load custom layout right.
pressed_preset_right
	bsf	FLAG_WAITING_FOR_RELEASE
	movlw	0x20
	movwf	active_key_map
	goto save_active_key_layout

	;; Load custom layout down.
pressed_preset_down
	bsf	FLAG_WAITING_FOR_RELEASE
	movlw	0x30
	movwf	active_key_map

	;; Save last used preset in eeprom.
save_active_key_layout
	banksel	EEDATA
	movwf	EEDATA
	bcf		STATUS, RP0
	movlw	EEPROM_LAST_KEY_MAP
	banksel EEADR
	movwf	EEADR
	call	eewrite
	goto	start_rumble_feedback


	;; Accept the virtual button pressed for menu selection in 'w', and
	;; set the right flag for next user input.
accept_config_menu_select
	bcf		FLAG_TOP_CONFIG_MENU
	btfsc	gamecube_buffer + GC_START
	goto	pressed_remap_combo
	btfsc	gamecube_buffer + GC_Z
	goto	pressed_reset_combo
	btfsc	gamecube_buffer + GC_D_UP
	goto	pressed_mode_submenu
	btfsc	gamecube_buffer + GC_D_LEFT
	goto	pressed_layout_submenu
	return

	;; Accept the virtual button code for the remap source in 'w', and prepare
	;; to accept the remap destination.
accept_remap_source
	movwf	remap_source_button
	bsf	FLAG_WAITING_FOR_RELEASE
	bcf	FLAG_REMAP_SOURCE_WAIT
	bsf	FLAG_REMAP_DEST_WAIT
	return


	;; Accept the virtual button code for the remap destination in 'w', and write
	;; the button mapping to EEPROM.
accept_remap_dest
	banksel	EEDATA
	movwf	EEDATA		; Destination button is data, source is address.
	bcf	STATUS, RP0		; No mirror of GPR in Bank 1 for 12F683 need to switch to Bank 0 for variables access.
	movf	remap_source_button, w
	addwf	active_key_map, w	; Add offset to eeprom address to read the right custom buttons layout.
	banksel EEADR
	movwf	EEADR
	call	eewrite
	bsf	FLAG_WAITING_FOR_RELEASE
	bcf	FLAG_REMAP_DEST_WAIT
	goto	start_rumble_feedback


	;; Accept the adapter mode selection.
accept_mode_select
	bcf		FLAG_MODE_SUBMENU
	btfsc	gamecube_buffer + GC_D_UP
	goto	pressed_mode_empty
	btfsc	gamecube_buffer + GC_D_LEFT
	goto	pressed_mode_rumble
	return

	;; Accept the button layout selection.
accept_layout_select
	bcf		FLAG_LAYOUT_SUBMENU
	btfsc	gamecube_buffer + GC_D_UP
	goto	pressed_preset_up
	btfsc	gamecube_buffer + GC_D_LEFT
	goto	pressed_preset_left
	btfsc	gamecube_buffer + GC_D_RIGHT
	goto	pressed_preset_right
	btfsc	gamecube_buffer + GC_D_DOWN
	goto	pressed_preset_down
	return

	;; Check our EEPROM for the magic word identifying it as button mapping data for
	;; this version of our firmware. If we don't find the magic word, reset its contents.
validate_eeprom
	movlw	EEPROM_MAGIC_ADDR	; Check high byte
	call	eeread
	xorlw	EEPROM_MAGIC_WORD >> 8
	btfss	STATUS, Z
	goto	reset_eeprom
	movlw	EEPROM_MAGIC_ADDR+1	; Check low byte
	call	eeread
	xorlw	EEPROM_MAGIC_WORD & 0xFF
	btfss	STATUS, Z
	goto	reset_eeprom

	movlw	EEPROM_LAST_KEY_MAP	; Load last used custom layout.
	call	eeread
	movwf	active_key_map
	return


	;; Write an identity mapping and a valid magic word to the EEPROM.
reset_eeprom
	banksel	EEADR
	clrf	EEADR			; Loop over all virtual buttons, writing the identity mapping
next_eeprom_bank
	clrf	EEDATA
	call	reset_next_byte
	movf	EEADR, w
	xorlw	NUM_EEPROM_DATA
	btfss	STATUS, Z
	goto	next_eeprom_bank

	movlw	EEPROM_MAGIC_ADDR	; Write the magic word
	banksel	EEADR
	movwf	EEADR
	movlw	EEPROM_MAGIC_WORD >> 8
	movwf	EEDATA
	call	eewrite
	movlw	EEPROM_MAGIC_ADDR+1
	banksel	EEADR
	movwf	EEADR
	movlw	EEPROM_MAGIC_WORD & 0xFF
	movwf	EEDATA
	call	eewrite

	movlw	EEPROM_LAST_KEY_MAP		;; Init default layout in eeprom.
	banksel	EEADR
	movwf	EEADR
	movlw	0x00
	movwf	EEDATA
	goto	eewrite


	;; Reset only data relative to the current active button mapping layout.
reset_active_eeprom_layout
	movf	active_key_map, w
	banksel	EEADR
	movwf	EEADR
	clrf	EEDATA

	;; Reset to default all button beginning at the current address set.
reset_next_byte
	call	eewrite
	banksel	EEADR
	incf	EEADR, f
	incf	EEDATA, f
	movf	EEDATA, w
	xorlw	NUM_VIRTUAL_BUTTONS
	btfss	STATUS, Z
	goto	reset_next_byte
	return

	;; Read from address 'w' of the eeprom, return in 'w'.
	;; Note that we must use banksel here rather than setting the page
	;; bits manually, since the PIC16F84A and PIC12F629 keep the EEPROM
	;; registers in different memory banks.
eeread
	addwf	active_key_map, w	; Add offset to read in right buttons layout.
	banksel	EEADR
	movwf	EEADR
	banksel	EECON1
	bsf	EECON1, RD
	banksel	EEDATA
	movf	EEDATA, w
	bcf	STATUS, RP0
	return

	;; Write to the EEPROM using the current EEADR and EEDATA values,
	;; block until the write is complete.
eewrite
	banksel	EECON1
	bsf	EECON1, WREN	; Enable write
	movlw	0x55		; Write the magic sequence to EECON2
	movwf	EECON2
	movlw	0xAA
	movwf	EECON2
	bsf	EECON1, WR	; Begin write
	btfsc	EECON1, WR	; Wait for it to finish...
	goto	$-1
	bcf	EECON1, WREN	; Write protect
	bcf	STATUS, RP0
	return


	;; Briefly enable the rumble motor on our own, as feedback during remap combos.
	;; Since we don't have a long-period timebase of our own and it isn't practical
	;; to use TMR0, this uses the N64's polling rate as a timebase. The length
	;; of the rumble will depend on the game's frame rate, but this should be good enough.
start_rumble_feedback
	movlw	.16
	movwf	rumble_feedback_count
	return


	;; At each status poll, turn on the rumble motor if we're in the middle of
	;; giving feedback, and decrement our counter.
update_rumble_feedback
	movf	rumble_feedback_count, w
	btfsc	STATUS, Z
	return				; No feedback to give
	bsf	FLAG_RUMBLE_MOTOR_ON
	decfsz	rumble_feedback_count, f
	return
	bcf	FLAG_RUMBLE_MOTOR_ON	; We need to turn off the motor when we're done
	return


	;; *******************************************************************************
	;; ******************************************************  N64 Interface *********
	;; *******************************************************************************

	;; While waiting for a Wavebird to associate, we don't have any status poll
	;; so we need to empty the n64_status_buffer before n64_wait_for_command.
n64_wfc_empty_buffer
	clrf	n64_status_buffer+0
	clrf	n64_status_buffer+1
	clrf	n64_status_buffer+2
	clrf	n64_status_buffer+3

	;; Service commands coming in from the N64
n64_wait_for_command
	call	n64_wait_for_idle	; Ensure the line is idle first, so we don't jump in to the middle of a command

	movlw	n64_command		; Receive 1 command byte
	movwf	FSR
	call	n64_rx_command

	;; We need to handle controller pak writes very fast because there's no pause
	;; between the initial command byte and the 34 bytes following. Every
	;; extra instuction here increases the probability of missing the first bit.
	;;
	;; FSR is already pointing at the right buffer- n64_rx will leave FSR pointing
	;; at the last byte it read, which is n64_command. We've overlaid n64_command
	;; onto the same memory as our address buffer, and the data buffer is immediately
	;; after our address buffer.
	;;
	;; Since n64_rx must be called as soon as possible, this skips n64_rx if we're not
	;; doing a write_bus command, and after the fact detects that and looks for other commands.
	;;
	movlw	N64_COMMAND_WRITE_BUS
	xorwf	n64_command, w
	btfsc	STATUS, Z
	call	n64_rx_bus		; Do another receive if this was a write_bus command.

	movlw	n64_command		; n64_command itself might be invalid now. If FSR changed,
	xorwf	FSR, w			;   n64_command is invalid and we're doing a bus write.
	btfss	STATUS, Z
	goto	n64_bus_write

	movf	n64_command, w		; Detect other applicable commands...
	xorlw	N64_COMMAND_READ_BUS
	btfsc	STATUS, Z
	goto	n64_bus_read

	movf	n64_command, w		; Check for both identity cmd (0x00 & 0xFF) at the same time.
	btfss	STATUS, Z
	comf	n64_command, w
	btfsc	STATUS, Z
	goto	n64_send_id

	movf	n64_command, w
	xorlw	N64_COMMAND_STATUS
	btfsc	STATUS, Z
	goto	n64_send_status

	goto	n64_wait_for_command	; Ignore unimplemented commands


	;; The N64 requested a 32-byte write to our controller pak bus.
	;; The start address is given in the high 11 bits of n64_bus_address.
	;; The low 5 bits are to verify the address- the algorithm for this is
	;; known, but to save time they are currently ignored.
	;; Addresses from 0x0000 to 0x7FFF are only used by the memory pak's RAM.
	;; To emulate a rumble pak, we should only need to respond to configuration
	;; writes at 0x8000 and rumble pak motor writes at 0xC000.
	;;
	;; Since all the packets we'll get while emulating a rumble pak are copies
	;; of the same byte, we assume this is always true and use a table storing
	;; the checksums of all such packets. We always negate the checksum to indicate
	;; that a controller pak has been detected and initialized properly.
n64_bus_write
	goto	$+1			; We have about 3us to kill here, we don't
	goto	$+1			;   want to begin transmitting before the stop bit is over.
	goto	$+1
	goto	$+1

	movlw	.34			; Reset bus_byte_count to 34. Keeping this set beforehand
	movwf	bus_byte_count		;   saves a few precious cycles in receiving bus writes.

	call	get_repeated_crc	; Get our limited CRC from the lookup table
	xorlw	0xFF			; Negate the CRC, we emulate a rumble pak
	movwf	n64_crc			; Send back the CRC in a 1-byte transmission
	movlw	n64_crc
	movwf	FSR
	movlw	1
	call	n64_tx		; We need a 2us stop bit after all CRCs

	movf	n64_bus_address, w	; Is this a write to the rumble pak?
	xorlw	0xC0			; (only check the top 8 bits. This excludes a few address bits and all check bits)
	btfss	STATUS, Z
	return				; Nope, return. We ignore the initialization writes to 0x8000

	btfss	controller_id, 0	; Do not rumble if we are supose to be an empty controller.
	return

	bcf	FLAG_RUMBLE_MOTOR_ON	; Set the rumble flag from the low bit of the first data byte
	btfsc	n64_bus_packet+0, 0
	bsf	FLAG_RUMBLE_MOTOR_ON
	return


	;; The N64 requested a 32-byte read from our controller pak bus.
	;; If all is well, this should only happen at address 0x8000, where it
	;; tries to identify what type of controller pak we have. Always
	;; indicate we have a rumble pak by sending all 0x80s.
	;;
	;; Since we're assuming the address is 0x8000, don't even bother scrambling
	;; to start receiving it in time. From the end of the command byte to when
	;; we start transmitting should be about 67us, or 335 cycles.
n64_bus_read
	movlw	.32			; Fill the buffer with 0x80
	movwf	byte_count
	movlw	n64_bus_packet
	movwf	FSR
pak_identify_fill_loop
	movlw	0x80
	movwf	INDF
	incf	FSR, f
	goto	$+1			; Padding to make this loop take most of the
	goto	$+1			;    335 cycles we need to waste.
	decfsz	byte_count, f
	goto	pak_identify_fill_loop

	movlw	0xB8			; 0xB8 is the inverted CRC of a packet with all 0x80s
	movwf	n64_crc

	movlw	n64_bus_packet		; Send back the data and CRC
	movwf	FSR
	movlw	.33
	goto	n64_tx;		; We need a 2us stop bit after all CRCs


	;; The N64 asked for our button and joystick status
n64_send_status
	movlw	n64_status_buffer	; Transmit the status buffer
	movwf	FSR
	movlw	4
	goto	n64_tx


	;; The N64 asked for our identity. Report that we're an
	;; N64 controller with the controller pak slot occupied or empty.
n64_send_id
	movlw	0x05
	movwf	n64_id_buffer+0
	movlw	0x00
	movwf	n64_id_buffer+1
	movf	controller_id, w
	movwf	n64_id_buffer+2

	movlw	n64_id_buffer		; Transmit the ID buffer
	movwf	FSR
	movlw	3
	goto	n64_tx


	;; Don't return until the N64 data line has been idle long enough to ensure
	;; we aren't in the middle of a packet already.
n64_wait_for_idle
	movlw	0x10
	movwf	temp
keep_waiting_for_idle
	btfss	N64_PIN
	goto	n64_wait_for_idle
	decfsz	temp, f
	goto	keep_waiting_for_idle
	return

	;; Before transmitting, we explicitly force the output latch low- it may have
	;; been left high by a read-modify-write operation elsewhere.
	;; For controller response we allways need an 2us stop bit.
n64_tx
	bsf	STATUS, RP0
	bsf	N64_TRIS
	bcf	STATUS, RP0
	bcf	N64_PIN
	n64gc_tx_buffer N64_TRIS, 1

n64_rx_bus
	n64gc_rx_buffer N64_PIN, bus_byte_count, 0

n64_rx_command
	movlw	.1
	movwf	byte_count
	n64gc_rx_buffer N64_PIN, byte_count, 1		; Clear the watchdog while waiting for commands


	;; *******************************************************************************
	;; ******************************************************  Gamecube Interface  ***
	;; *******************************************************************************

	;; To support the Wavebird we must poll the controller identity first.
gamecube_get_id
	movlw	0x00			; Put 0x00 in the gamecube_buffer
	movwf	gamecube_buffer+0

	movlw	gamecube_buffer		; Transmit the gamecube_buffer
	movwf	FSR
	movlw	1
	call	gamecube_tx

	movlw	gamecube_buffer		; Receive 3 status bytes
	movwf	FSR
	movlw	3
	call	gamecube_rx

	btfss	gamecube_buffer+0, 7	; Check only the MSB of the first byte since it's enough
	return							; to tell between normal controller and Wavebird.

	movlw	0x02					; Wavebird don't have rumble motor so we show to the n64
	movwf	controller_id			; that we are a controller with empty slot.

	bsf		WAVEBIRD				; We have a Wavebird receiver connected and we check if
	movf	gamecube_buffer, w		; a Wavebird is associated with it.
	xorlw	0xA8
	btfsc	STATUS, Z
	return

	bsf		WAVEBIRD_ASSOCIATED		; Wavebird is associated and we save his unique id
	return

	;; If we receive something other than 0xA8xxxx as ID we must repond with the Wavebird unique ID
	;; at the end of command 0x4Exxxx to enable the WaveBird. It will not answer the poll status otherwise.
gamecube_init_wavebird
	movlw	0x4E			; Put 0x4Exxxx in the gamecube_buffer to enable Wavebird.
	movwf	gamecube_buffer+0
									; Two other byte containing the WB unique ID allready in buffer.
	bcf		gamecube_buffer+1, 5	; Bit 5 and 4 are always 0 & 1 respectively in an 0x4E init command.
	bsf		gamecube_buffer+1, 4

	movlw	gamecube_buffer		; Transmit the gamecube_buffer
	movwf	FSR
	movlw	3
	call	gamecube_tx

	movlw	gamecube_buffer		; Receive 3 status bytes
	movwf	FSR
	movlw	3
	call	gamecube_rx

	return


	;; Poll the gamecube controller's state by transmitting a magical
	;; poll command (0x400300) then receiving 8 bytes of status.
gamecube_poll_status
	movlw	0x40			; Put 0x400300 in the gamecube_buffer
	movwf	gamecube_buffer+0
	movlw	0x03
	movwf	gamecube_buffer+1
	movlw	0x00
	movwf	gamecube_buffer+2

	btfsc	FLAG_RUMBLE_MOTOR_ON	; Set the low bit of our gamecube command to turn on rumble
	bsf		gamecube_buffer+2, 0

	movlw	gamecube_buffer		; Transmit the gamecube_buffer
	movwf	FSR
	movlw	3
	call	gamecube_tx

	movlw	gamecube_buffer		; Receive 8 status bytes
	movwf	FSR
	movlw	8
	call	gamecube_rx
	return


gamecube_tx
	bcf	GAMECUBE_PIN
	n64gc_tx_buffer GAMECUBE_TRIS, 0
gamecube_rx
	movwf	byte_count
	n64gc_rx_buffer GAMECUBE_PIN, byte_count, 0


	;; *******************************************************************************
	;; ******************************************************  Lookup Tables  ********
	;; *******************************************************************************

	;; This is a table of the resulting CRCs
	;; for every message consisting of 32 copies
	;; of a single byte. It's cheesy, but our
	;; microcontroller is a bit on the slow side
	;; to implement the full CRC in the allotted time,
	;; and this is all we need for initialization
	;; and rumble pak support.
	;;
	;; It was generated using the small-table
	;; implementation of the CRC, in notes/crc.py
get_repeated_crc
	movlw	high crc_table
	movwf	PCLATH
	movf	n64_bus_packet, w
	movwf	PCL


	org 0x700

crc_table
	#include repeated_crc_table.inc

	end
