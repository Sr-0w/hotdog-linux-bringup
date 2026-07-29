/*
 * Minimal AArch64 initramfs wrapper used to prove the first EL0 instructions.
 * It has no libc or dynamic-linker dependency. Two framebuffer bands are
 * painted with raw syscalls before the original /init is executed.
 */

	.equ	__NR_openat, 56
	.equ	__NR_close, 57
	.equ	__NR_lseek, 62
	.equ	__NR_write, 64
	.equ	__NR_execve, 221
	.equ	AT_FDCWD, -100
	.equ	O_WRONLY, 1
	.equ	SEEK_SET, 0
	.equ	FB_STRIDE, 5760
	.equ	FB_BAND_ROWS, 120
	.equ	FB_STAGE0_OFFSET, 2880000
	.equ	FB_STAGE1_OFFSET, 4032000

	.section .text
	.global _start
	.type _start, %function
	.balign 16
_start:
	mov	x22, sp

	mov	x0, #AT_FDCWD
	adr	x1, fb_path
	mov	x2, #O_WRONLY
	mov	x3, #0
	mov	x8, #__NR_openat
	svc	#0
	tbnz	x0, #63, 1f

	mov	x19, x0
	ldr	x1, =FB_STAGE0_OFFSET
	bl	paint_band
	mov	x0, x19
	ldr	x1, =FB_STAGE1_OFFSET
	bl	paint_band
	mov	x0, x19
	mov	x8, #__NR_close
	svc	#0

1:
	ldr	x9, [x22]
	add	x1, x22, #8
	adr	x0, init_path
	str	x0, [x1]
	add	x2, x1, x9, lsl #3
	add	x2, x2, #8
	mov	x8, #__NR_execve
	svc	#0

2:
	wfe
	b	2b
	.size _start, . - _start

	.type paint_band, %function
paint_band:
	mov	x20, x1
	mov	x21, #FB_BAND_ROWS
	mov	x8, #__NR_lseek
	mov	x2, #SEEK_SET
	svc	#0
	tbnz	x0, #63, 4f

3:
	mov	x0, x19
	adr	x1, white_row
	mov	x23, #FB_STRIDE
	mov	x2, x23
	mov	x8, #__NR_write
	svc	#0
	cmp	x0, x23
	b.ne	4f
	subs	x21, x21, #1
	b.ne	3b
4:
	mov	x0, x19
	ret
	.size paint_band, . - paint_band

	.section .rodata
	.balign 16
fb_path:
	.asciz	"/dev/fb0"
init_path:
	.asciz	"/init"
wrapper_identity:
	.asciz	"HOTDOG_EL0_STATIC_WRAPPER wrapper-entry wrapper-exec-init"
	.balign 16
white_row:
	.fill	FB_STRIDE, 1, 0xff

	.section .note.GNU-stack,"",%progbits
