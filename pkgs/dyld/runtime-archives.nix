{ lib, mkDarwinPackage, sources, toolchain, systemFrameworkHeaders, perl, libsyscall, targetArch }:
let
  platform = mkDarwinPackage {
    pname = "dyld-platform";
    version = lib.removePrefix "libplatform-" sources.libplatform.rev;
    src = sources.libplatform;
    inherit toolchain;
    buildPhase = ''
      export MD_SRCROOT=$PWD
      mkdir -p o
      for file in src/init.c src/os/security_config.c; do
        substituteInPlace "$file" --replace-fail '#include <AppleFeatures/AppleFeatures.h>' ""
      done
      # Use the generic static string routines. No resolver or host libraries.
      mapfile -t files < <(md_glob $PWD/src/string/generic/*.c $PWD/src/simple/*.c \
        $PWD/src/atomics/*.c $PWD/src/atomics/common/*.c $PWD/src/os/*.c)
      md_compile o "$CC" -Os -ffreestanding -fno-builtin -fno-stack-protector \
        -DVARIANT_DYLD=1 -DVARIANT_STATIC=1 -DVARIANT_NO_RESOLVERS=1 \
        -DCONFIG_MTE=0 -D_FORTIFY_SOURCE=0 -DLONG_BIT=__LONG_WIDTH__ -DOSATOMIC_USE_INLINED=0 \
        -DOSATOMIC_DEPRECATED=0 -DOSSPINLOCK_USE_INLINED=0 -DOSSPINLOCK_DEPRECATED=0 \
        -DOS_UNFAIR_LOCK_INLINE=0 -Wno-deprecated-declarations -Wno-int-conversion \
        -Iprivate -Iinclude -Iinternal -Isrc/os/resolver \
        -iwithsysroot ${systemFrameworkHeaders} -- "''${files[@]}"
      md_compile o "$CC" -Os -fno-stack-protector -DVARIANT_DYLD=1 -DVARIANT_STATIC=1 \
        -Iprivate -Iinclude -Iinternal -iwithsysroot ${systemFrameworkHeaders} \
        -- "$PWD/src/atomics/${if targetArch == "aarch64" then "arm64/OSAtomic.c" else "x86_64/OSAtomic.s"}"
      ${lib.optionalString (targetArch == "x86_64") ''
        md_compile o "$CC" -DVARIANT_DYLD=1 -DVARIANT_STATIC=1 \
          -Iprivate -Iinclude -Iinternal -iwithsysroot ${systemFrameworkHeaders} \
          -- "$PWD/src/atomics/x86_64/pfz.s"
      ''}
      md_archive libplatform.a o
    '';
    installPhase = ''
      install -Dm644 libplatform.a $out/libplatform.a
    '';
  };
  libc = mkDarwinPackage {
    pname = "dyld-libc";
    version = lib.removePrefix "Libc-" sources.Libc.rev;
    src = sources.Libc;
    inherit toolchain;
    nativeBuildInputs = [ perl ];
    buildPhase = ''
      export MD_SRCROOT=$PWD
      mkdir -p o sdkview/include
      cp -R "$MINIDARWIN_SYSROOT/usr/include/." sdkview/include/
      chmod -R u+w sdkview
      cp -R "$MINIDARWIN_SYSROOT${systemFrameworkHeaders}/." sdkview/include/
      perl xcodescripts/patch_headers_variants.pl "$PWD/sdkview/include" "$PWD/derived/System.framework/Versions/B"
      test -f derived/System.framework/Versions/B/include/sys/fcntl.h
      # Use Libc's released fallback when the private logging runtime is absent.
      substituteInPlace gen/FreeBSD/arc4random.c \
        --replace-fail '#define OS_CRASH_ENABLE_EXPERIMENTAL_LIBTRACE 1' ""
      flags=( -std=gnu11 -Os -ffreestanding -fno-stack-protector -fno-stack-check
        -D__LIBC__ -D__DARWIN_UNIX03=1 -D__DARWIN_64_BIT_INO_T=1
        -D__DARWIN_VERS_1050=1 -D__DARWIN_NON_CANCELABLE=0 -D_FORTIFY_SOURCE=0
        -DVARIANT_STATIC=1 -DVARIANT_CANCELABLE=1 -DVARIANT_DARWINEXTSN=1
        -I. -Iinclude -Igen -Ilocale -Ilocale/FreeBSD -Istdtime/FreeBSD -Idarwin
        -Ifbsdcompat -Igdtoa -Igdtoa/FreeBSD
        -isystem derived/System.framework/Versions/B/include )
      ${lib.concatMapStringsSep "\n" (file:
        let flags = lib.replaceStrings [ "$(FreeBSD_CFLAGS)" "$(SRCROOT)" ]
          [ "-include fbsdcompat/_fbsd_compat_.h" "." ] (file.flags or "");
        in ''md_compile o "$CC" "''${flags[@]}" ${flags} -- "$PWD/${file.path}"''
      ) (import ./libc-sources.nix)}
      md_archive libc.a o
    '';
    installPhase = ''
      install -Dm644 libc.a $out/libc.a
    '';
  };
  syscall = libsyscall.overrideAttrs (old: {
    pname = "dyld-syscall";
    # Dynamic libkernel's upcalls dereference an uninitialized libSystem table
    # during loader startup. The standalone loader supplies these directly.
    buildPhase = lib.replaceStrings [ "wrappers/_libc_funcptr.c" ] [ "" ]
      (builtins.head (lib.splitString "# -umbrella System marks" old.buildPhase))
    + "\nrunHook postBuild\n";
    installPhase = ''
      md_archive libsyscall.a obj/o
      install -Dm644 libsyscall.a $out/libsyscall.a
    '';
  });
in
mkDarwinPackage {
  pname = "dyld-runtime-archives";
  version = lib.removePrefix "dyld-" sources.dyld.rev;
  inherit toolchain;
  dontUnpack = true;
  installPhase = ''
    mkdir -p $out/usr/local/lib/dyld
    cp ${platform}/libplatform.a ${libc}/libc.a ${syscall}/libsyscall.a $out/usr/local/lib/dyld/
  '';
  passthru = { inherit platform libc syscall; };
  meta.description = "Freestanding platform, Libc and syscall archives for dyld";
}
