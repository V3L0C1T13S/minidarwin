/* TargetConditionals.h - shim. No open-source release defines TARGET_OS_OSX/
 * TARGET_CPU_ARM64 (CarbonHeaders-18.1 predates arm64). Derived from compiler
 * predefined macros, no Apple code. Delete if Apple republishes. */

#ifndef __TARGETCONDITIONALS__
#define __TARGETCONDITIONALS__

/* ---- platform ---------------------------------------------------------- */

#define TARGET_OS_MAC             1
#define TARGET_OS_WIN32           0
#define TARGET_OS_WINDOWS         0
#define TARGET_OS_UNIX            0
#define TARGET_OS_LINUX           0

#if defined(__has_builtin) && __has_builtin(__is_target_os)
  #if __is_target_os(ios)
    #define TARGET_OS_IPHONE      1
    #define TARGET_OS_OSX         0
  #else
    #define TARGET_OS_IPHONE      0
    #define TARGET_OS_OSX         1
  #endif
#else
  #define TARGET_OS_IPHONE        0
  #define TARGET_OS_OSX           1
#endif

#define TARGET_OS_IOS             TARGET_OS_IPHONE
#define TARGET_OS_MACCATALYST     0
#define TARGET_OS_UIKITFORMAC     0
#define TARGET_OS_TV              0
#define TARGET_OS_WATCH           0
#define TARGET_OS_VISION          0
#define TARGET_OS_XR              0
#define TARGET_OS_BRIDGE          0
#define TARGET_OS_DRIVERKIT       0
#define TARGET_OS_EXCLAVEKIT      0
#define TARGET_OS_EXCLAVECORE     0
#define TARGET_OS_SIMULATOR       0
#define TARGET_OS_EMBEDDED        0
#define TARGET_OS_NANO            0
#define TARGET_IPHONE_SIMULATOR   TARGET_OS_SIMULATOR

/* ---- cpu --------------------------------------------------------------- */

#if defined(__arm64__) || defined(__aarch64__)
  #define TARGET_CPU_PPC          0
  #define TARGET_CPU_PPC64        0
  #define TARGET_CPU_68K          0
  #define TARGET_CPU_X86          0
  #define TARGET_CPU_X86_64       0
  #define TARGET_CPU_ARM          0
  #define TARGET_CPU_ARM64        1
  #define TARGET_CPU_MIPS         0
  #define TARGET_CPU_SPARC        0
  #define TARGET_CPU_ALPHA        0
  #define TARGET_CPU_WASM32       0
#elif defined(__x86_64__)
  #define TARGET_CPU_PPC          0
  #define TARGET_CPU_PPC64        0
  #define TARGET_CPU_68K          0
  #define TARGET_CPU_X86          1
  #define TARGET_CPU_X86_64       1
  #define TARGET_CPU_ARM          0
  #define TARGET_CPU_ARM64        0
  #define TARGET_CPU_MIPS         0
  #define TARGET_CPU_SPARC        0
  #define TARGET_CPU_ALPHA        0
  #define TARGET_CPU_WASM32       0
#elif defined(__arm__)
  #define TARGET_CPU_PPC          0
  #define TARGET_CPU_PPC64        0
  #define TARGET_CPU_68K          0
  #define TARGET_CPU_X86          0
  #define TARGET_CPU_X86_64       0
  #define TARGET_CPU_ARM          1
  #define TARGET_CPU_ARM64        0
  #define TARGET_CPU_MIPS         0
  #define TARGET_CPU_SPARC        0
  #define TARGET_CPU_ALPHA        0
  #define TARGET_CPU_WASM32       0
#elif defined(__i386__)
  #define TARGET_CPU_PPC          0
  #define TARGET_CPU_PPC64        0
  #define TARGET_CPU_68K          0
  #define TARGET_CPU_X86          1
  #define TARGET_CPU_X86_64       0
  #define TARGET_CPU_ARM          0
  #define TARGET_CPU_ARM64        0
  #define TARGET_CPU_MIPS         0
  #define TARGET_CPU_SPARC        0
  #define TARGET_CPU_ALPHA        0
  #define TARGET_CPU_WASM32       0
#else
  #error minidarwin TargetConditionals.h: unsupported target CPU
#endif

/* ---- runtime ----------------------------------------------------------- */

#define TARGET_RT_MAC_CFM         0
#define TARGET_RT_MAC_MACHO       1
/* `defined()` inside a macro body is undefined behaviour, so branch here. */
#if defined(__BIG_ENDIAN__)
  #define TARGET_RT_LITTLE_ENDIAN 0
  #define TARGET_RT_BIG_ENDIAN    1
#else
  #define TARGET_RT_LITTLE_ENDIAN 1
  #define TARGET_RT_BIG_ENDIAN    0
#endif

#if defined(__LP64__) || defined(_LP64)
  #define TARGET_RT_64_BIT        1
#else
  #define TARGET_RT_64_BIT        0
#endif

#ifdef __ptrauth_calls
  #define TARGET_RT_PTRAUTH       1
#else
  #define TARGET_RT_PTRAUTH       0
#endif

/* ---- ABI --------------------------------------------------------------- */

#define TARGET_ABI_USES_IOS_VALUES (!TARGET_CPU_X86_64 || (TARGET_OS_IPHONE && !TARGET_OS_MACCATALYST))

#endif /* __TARGETCONDITIONALS__ */
