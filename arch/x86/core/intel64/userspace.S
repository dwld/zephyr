/*
 * Copyright (c) 2017 Intel Corporation
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <arch/cpu.h>
#include <offsets_short.h>
#include <syscall.h>


/* Landing site for 'syscall' instruction
 *
 * Call id is in RAX
 * Arguments are in RDI, RSI, RDX, R10, R8, R9
 * Return address stored by CPU in RCX
 * User RFLAGS store by CPU in R11
 * Current RFLAGS has been masked with ~X86_FMASK_MSR
 */
.global z_x86_syscall_entry_stub
z_x86_syscall_entry_stub:
	swapgs

	/* Switch to the privilege mode stack pointer stored in
	 * x86_tss64.psp and store the user mode stack pointer in
	 * x86_tss64.usp, immediately pushing it once the stack switch
	 * is done since this is a per-cpu and not per-thread area.
	 *
	 * This dance is necessary as upon entry we have no free registers
	 * nor a stack we can push to.
	 */
	movq	%rsp, %gs:__x86_tss64_t_usp_OFFSET
	movq	%gs:__x86_tss64_t_psp_OFFSET, %rsp
	pushq	%gs:__x86_tss64_t_usp_OFFSET

	sti			/* re-enable interrupts */

	/* call_id is in RAX. bounds-check it, must be less than
	 * K_SYSCALL_LIMIT.
	 */
	cmp	$K_SYSCALL_LIMIT, %rax
	jae	_bad_syscall

_id_ok:
#ifdef CONFIG_X86_BOUNDS_CHECK_BYPASS_MITIGATION
	/* Prevent speculation with bogus system call IDs */
	lfence
#endif

	/* Remaining registers not involved in the syscall operation are
	 * RBX, RBP, R12-R15, plus floating point / SIMD registers.
	 *
	 * We save caller-saved registers so we can restore to original values
	 * when we call 'sysretq' at the end.
	 */
	pushq	%rdi
	subq	$X86_FXSAVE_SIZE, %rsp
	fxsave	(%rsp)
	pushq	%rsi
	pushq	%rdx
	pushq	%r8
	pushq	%r9
	pushq	%r10
	pushq	%r11	/* RFLAGS */
	pushq	%rcx	/* Return address stored by 'syscall' */
	pushq	%rsp	/* SSF parameter */

	/* All other args are in the right registers, except arg4 which
	 * we had to put in r10 instead of RCX
	 */
	movq	%r10, %rcx

	/* from the call ID in RAX, load R10 with the actual function pointer
	 * to call by looking it up in the system call dispatch table
	 */
	xorq	%r11, %r11
	movq	_k_syscall_table(%r11, %rax, 8), %r10

	/* Run the marshal function, which is some entry in _k_syscall_table */
	call	*%r10

	/* RAX now contains the return value
	 *
	 * Callee-saved registers are un-touched from original values per C
	 * calling convention, but sensitive data may lurk in caller-saved regs
	 * RDI, RSI, RDX, R8, R9, R10, XMM* after we have serviced the system
	 * call.  We saved them earlier, restore their original values when
	 * the syscall was made. This also preserves these registers if they
	 * were not used as arguments.
	 *
	 * We also can't have RCX and R11 clobbered as we need the original
	 * values to successfully 'sysretq'.
	 */
	addq	$8, %rsp	/* Discard ssf */
	popq	%rcx	/* Restore return address for 'sysretq' */
	popq	%r11	/* Restore RFLAGS for 'sysretq' */
	popq	%r10
	popq	%r9
	popq	%r8
	popq	%rdx
	popq	%rsi
	fxrstor	(%rsp)
	addq	$X86_FXSAVE_SIZE, %rsp
	popq	%rdi

	/* Restore user stack pointer */
	popq	%rsp

	/* Return to user mode, locking interrupts as the normal interrupt
	 * handling path will get very confused if it occurs between
	 * 'swapgs' and 'sysretq'
	 */
	cli
	swapgs
	sysretq

_bad_syscall:
	/* RAX had a bogus syscall value in it, replace with the bad syscall
	 * handler's ID, and put the bad ID as its first argument.
	 *
	 * TODO: On this and all other arches, simply immediately return
	 * with -ENOSYS, once all syscalls have a return value
	 */
	movq	%rax, %rdi
	movq	$K_SYSCALL_BAD, %rax
	jmp	_id_ok

/*
 * size_t arch_user_string_nlen(const char *s, size_t maxsize, int *err_arg)
 *                              ^ RDI          ^ RSI           ^ RDX
 */
.global arch_user_string_nlen
arch_user_string_nlen:
	/* Initial error value, strlen_done adjusts this if we succeed */
	movl	$-1, %r8d

	/* use RAX as our length count (this function's return value) */
	xor	%rax, %rax

	/* This code might page fault */
strlen_loop:
.global z_x86_user_string_nlen_fault_start
z_x86_user_string_nlen_fault_start:
	cmpb	$0x0, (%rdi, %rax, 1)	/* *(RDI + RAX) == 0? Could fault. */

.global z_x86_user_string_nlen_fault_end
z_x86_user_string_nlen_fault_end:
	je	strlen_done
	cmp	%rsi, %rax		/* Max length reached? */
	je	strlen_done
	inc	%rax			/* EAX++ and loop again */
	jmp	strlen_loop

strlen_done:
	/* Set error value to 0 since we succeeded */
	xorl	%r8d, %r8d

.global z_x86_user_string_nlen_fixup
z_x86_user_string_nlen_fixup:
	/* Write error value to 32-bit integer err pointer parameter */
	movl	%r8d, (%rdx)
	retq

/*
 * Trampoline function to put the p3 parameter in the register expected
 * by the calling convention, we couldn't use RCX when we called 'sysret'
 */
z_x86_userspace_landing_site:
	/* Place argument 4 in the correct position */
	movq	%r10, %rcx
	call	z_thread_entry

/* FUNC_NORETURN void z_x86_userspace_enter(
 *		k_thread_entry_t user_entry,	<- RDI
 *		void *p1, void *p2, void *p3,	<- RSI, RDX, RCX
 *		uintptr_t stack_end,		<- R8
 *		uintptr_t stack_start)		<- R9
 *
 * A one-way trip to userspace.
 */
.global z_x86_userspace_enter
z_x86_userspace_enter:
	/* RCX is sysret return address, pass along p3 in r10,
	 * z_x86_userspace_landing_site will fix this up
	 */
	movq	%rcx, %r10

	/* switch to privilege mode stack so we can erase thread stack buffer,
	 * the buffer is the page immediately before the thread stack
	 */
	movq	%r9, %rsp

	/* Need RDI temporarily */
	pushq	%rdi

	/* Compute size of user stack in 8-byte chunks and put in RCX */
	movq	%r9, %rdi	/* Start address for rep stosq in RDI */
	movq	%r8, %rcx	/* Ending address */
	subq	%rdi, %rcx	/* Subtract starting address */
	shrq	$3, %rcx	/* Divide by 8 */

	movq	$0xAAAAAAAAAAAAAAAA, %rax	/* Fill value */
	/* Copy 8 bytes of memory at a time, starting at ES:RDI, with whatever
	 * is in RAX. Repeat this RCX times.  Stack sizes are always at least
	 * 8-byte aligned.
	 */
	cld
	rep stosq

	popq	%rdi

	/* Reset to the beginning of the user stack */
	movq	%r8, %rsp

	/* set sysret entry point */
	movq	$z_x86_userspace_landing_site, %rcx

	/* Copy RFLAGS into r11, required by sysret */
	pushfq
	movq	(%rsp), %r11
	movq	$0, (%rsp)	/* Now a debugger-friendly return address */

	/* cleanse other registers */
	xorq	%rax, %rax
	xorq	%rbx, %rbx
	xorq	%rbp, %rbp
	xorq	%r12, %r12
	xorq	%r13, %r13
	xorq	%r14, %r14
	xorq	%r15, %r15

	cli
	swapgs
	sysretq
