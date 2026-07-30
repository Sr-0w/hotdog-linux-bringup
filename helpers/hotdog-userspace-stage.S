/* SPDX-License-Identifier: GPL-2.0-only */

	.section .text
	.align 2
	.global _start
	.type _start, %function

/*
 * Emit one initramfs stage marker through an otherwise invalid prctl().
 * The diagnostic kernel consumes the magic and stage at EL0 syscall entry.
 */
_start:
	ldr	x2, [sp, #16]
	cbz	x2, .Lbad_argument
	mov	x1, #0

.Lparse:
	ldrb	w3, [x2], #1
	cbz	w3, .Lemit
	sub	w3, w3, #'0'
	cmp	w3, #9
	b.hi	.Lbad_argument
	mov	x4, #10
	madd	x1, x1, x4, x3
	cmp	x1, #10
	b.hi	.Lbad_argument
	b	.Lparse

.Lemit:
	movz	x0, #0x4731
	movk	x0, #0x4844, lsl #16
	mov	x8, #167
	svc	#0
	mov	x0, #0
	b	.Lexit

.Lbad_argument:
	mov	x0, #2

.Lexit:
	mov	x8, #93
	svc	#0
	b	.Lexit

	.size _start, . - _start

	.section .rodata
	.asciz "HOTDOG_USERSPACE_STAGE_V1"
