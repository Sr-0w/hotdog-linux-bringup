/*
 * Keep a large, camera-visible pattern present in the firmware framebuffer.
 *
 * This diagnostic has no libc or dynamic-linker dependency. It is started by
 * the initramfs after the first userspace checkpoint and repeatedly repaints a
 * 400-row band. If the display becomes black while this process is running,
 * the failure is below framebuffer contents (scanout, clocks, panel, or power).
 */

	.equ	__NR_openat, 56
	.equ	__NR_close, 57
	.equ	__NR_lseek, 62
	.equ	__NR_write, 64
	.equ	__NR_nanosleep, 101
	.equ	AT_FDCWD, -100
	.equ	O_WRONLY, 1
	.equ	SEEK_SET, 0
	.equ	FB_STRIDE, 5760
	.equ	FB_ROWS, 400
	.equ	FB_OFFSET, 6912000

	.section .text
	.global _start
	.type _start, %function
	.balign 16
_start:
1:
	mov	x0, #AT_FDCWD
	adr	x1, fb_path
	mov	x2, #O_WRONLY
	mov	x3, #0
	mov	x8, #__NR_openat
	svc	#0
	tbnz	x0, #63, 5f
	mov	x19, x0

2:
	mov	x0, x19
	ldr	x1, =FB_OFFSET
	mov	x2, #SEEK_SET
	mov	x8, #__NR_lseek
	svc	#0
	tbnz	x0, #63, 4f

	mov	x20, #FB_ROWS
3:
	mov	x0, x19
	adr	x1, pattern_row
	mov	x2, #FB_STRIDE
	mov	x8, #__NR_write
	svc	#0
	mov	x9, #FB_STRIDE
	cmp	x0, x9
	b.ne	4f
	subs	x20, x20, #1
	b.ne	3b

	adr	x0, refresh_delay
	mov	x1, #0
	mov	x8, #__NR_nanosleep
	svc	#0
	b	2b

4:
	mov	x0, x19
	mov	x8, #__NR_close
	svc	#0
5:
	adr	x0, retry_delay
	mov	x1, #0
	mov	x8, #__NR_nanosleep
	svc	#0
	b	1b
	.size _start, . - _start

	.section .rodata
	.balign 16
fb_path:
	.asciz	"/dev/fb0"
helper_identity:
	.asciz	"HOTDOG_FB_HEARTBEAT_V1"
	.balign 16
refresh_delay:
	.quad	0
	.quad	250000000
retry_delay:
	.quad	1
	.quad	0
	.balign 16
pattern_row:
	.rept	360
	.word	0xffff00ff
	.endr
	.rept	360
	.word	0xff00ff00
	.endr
	.rept	360
	.word	0xffffff00
	.endr
	.rept	360
	.word	0xffffffff
	.endr

	.section .note.GNU-stack,"",%progbits
