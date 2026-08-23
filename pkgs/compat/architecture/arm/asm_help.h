/* architecture/arm/asm_help.h - shim for Apple's internal SDK header.
 * Only libplatform's src/setjmp/arm64/setjmp.s needs it (ENTRY_POINT,
 * CALL_EXTERNAL). Don't add FUNC_PROLOGUE - setjmp.s defines it as .macro. */

#ifndef _ARCH_ARM_ASM_HELP_H_
#define _ARCH_ARM_ASM_HELP_H_

#if defined(__ASSEMBLER__)

/* Separator is %%, not ; - ; is a comment on AArch64. */
#define ENTRY_POINT(name)  \
	.text                 %% \
	.p2align 2            %% \
	.globl name           %% \
	name:

/* Plain bl. */
#define CALL_EXTERNAL(name) bl name

#endif /* __ASSEMBLER__ */

#endif /* _ARCH_ARM_ASM_HELP_H_ */
