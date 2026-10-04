# Upstream XNU build, with explicit host tools and a source-built target SDK.
# x86_64 is the first platform; ARM kernels need a platform support library.
{ lib
, stdenv
, sources
, toolchain
, mig
, perl
, python3
, bison
, flex
, unifdef
, gnumake
, ld64
, llvmPackages
, targetArch
, minOS
, iig
}:

assert lib.assertMsg (targetArch == "x86_64")
  "MiniDarwin XNU currently targets x86_64; ARM needs platform support";
assert lib.assertMsg (sources.xnu.rev == "xnu-12377.121.6")
  "Update the Darwin kernel version when changing the XNU source pin";

stdenv.mkDerivation {
  pname = "minidarwin-xnu-objects";
  version = lib.removePrefix "xnu-" sources.xnu.rev;
  src = sources.xnu;
  nativeBuildInputs = [ gnumake mig perl python3 bison flex unifdef iig ];
  strictDeps = true;
  dontConfigure = true;
  dontFixup = true;
  dontStrip = true;
  SOURCE_DATE_EPOCH = "1";
  ZERO_AR_DATE = "1";
  TZ = "UTC";

  buildPhase = ''
    runHook preBuild
    hostCC=$CC
    hostCXX=$CXX
    # Host-only generators use nixpkgs' wrapped compiler and its pinned SDK.
    # Passing '/' as a sysroot would override the wrapper's hermetic SDK.
    for f in SETUP/*/Makefile; do
      substituteInPlace "$f" --replace-quiet '-isysroot $(HOST_SDKROOT)' ""
    done
    substituteInPlace libkern/libkern/Makefile \
      --replace-fail 'install $(DATA_INSTALL_FLAGS)' '$(INSTALL) $(DATA_INSTALL_FLAGS)'
    python3 ${./capture-kernel-link.py} makedefs/MakeInc.kernel
    python3 ${./patch-tcg-clock.py} osfmk/i386/tsc.c
    python3 ${./patch-kalloc-zones.py} osfmk/kern/kalloc.c
    mkdir -p sdk/usr/local/libexec sdk/usr/local/lib/kernel sdk/usr/local/include/kernel/os
    cp -R ${toolchain.sysroot}/. sdk/
    chmod -R u+w sdk
    cp -R ${./support/TrustCache} sdk/usr/include/TrustCache
    cp -R ${./support/TrustCache} sdk/usr/local/include/kernel/TrustCache
    cp -R ${./support/CodeSignature} sdk/usr/local/include/kernel/CodeSignature
    cp -R ${./support/CoreEntitlements} sdk/usr/local/include/kernel/CoreEntitlements
    cp ${sources.libdispatch}/os/firehose*.h sdk/usr/local/include/kernel/os/
    python3 ${./patch-annotations.py} bsd
    # Public SDK headers had KERNEL sections stripped during SDK construction.
    # Kernel compilation needs the source versions and their layout annotations.
    cp bsd/sys/cdefs.h sdk/usr/include/sys/cdefs.h
    cp bsd/sys/_types/_uintptr_t.h sdk/usr/include/sys/_types/_uintptr_t.h
    substituteInPlace config/newvers.pl \
      --replace-fail 'my $BUILDER=`whoami`;' 'my $BUILDER="minidarwin";'
    python3 ${sources.AvailabilityVersions}/availability \
      --av_version ${lib.removePrefix "AvailabilityVersions-" sources.AvailabilityVersions.rev} \
      --preprocess ${sources.AvailabilityVersions}/availability \
      sdk/usr/local/libexec/availability.pl
    chmod +x sdk/usr/local/libexec/availability.pl
    patchShebangs sdk/usr/local/libexec/availability.pl
    # Darwin's ABI release differs from the XNU project source version.
    export RC_DARWIN_KERNEL_VERSION=25.5.0
    export RC_ProjectSourceVersion=$version
    export KERNEL_BUILD_DATE='Thu Jan  1 00:00:01 UTC 1970'
    export KERNEL_BUILD_OBJROOT=minidarwin/RELEASE_X86_64
    export SRCROOT=$PWD OBJROOT=$PWD/BUILD/obj SYMROOT=$PWD/BUILD/sym DSTROOT=$PWD/BUILD/dst
    export SDKROOT_RESOLVED=$PWD/sdk HOST_SDKROOT_RESOLVED=/
    export HOST_OS_VERSION=14.4
    export SDKVERSION=${minOS} PLATFORM=MacOSX PLATFORMPATH=/minidarwin/MacOSX.platform
    export CC=${toolchain}/bin/cc CXX=${toolchain}/bin/c++
    export HOST_CC="$hostCC" HOST_CXX="$hostCXX"
    export MIG=${mig}/bin/mig MIGCOM=${mig}/libexec/migcom MIGCC=$CC
    export HOST_FLEX=${flex}/bin/flex HOST_BISON=${bison}/bin/bison HOST_GM4=m4
    export UNIFDEF=${unifdef}/bin/unifdef
    export NM=${llvmPackages.llvm}/bin/llvm-nm
    export LIPO=${llvmPackages.llvm}/bin/llvm-lipo
    export LIBTOOL=${llvmPackages.llvm}/bin/llvm-libtool-darwin
    export OTOOL=${llvmPackages.llvm}/bin/llvm-objdump
    export STRIP=${llvmPackages.llvm}/bin/llvm-strip
    export DSYMUTIL=${llvmPackages.llvm}/bin/dsymutil
    export PYTHON=${python3}/bin/python3
    # Never discover target tools or an SDK through the host's Xcode selection.
    makeFlags=(
      ARCH_CONFIGS=X86_64 KERNEL_CONFIGS=RELEASE MACHINE_CONFIGS=NONE
      BUILD_LTO=0 BUILD_STABS=0 BUILD_DWARF=0 BUILD_DSYM=0 DO_CTFMERGE=0
      MAKEJOBS=
      XCRUN=false IIG=${iig}/bin/iig NMEDIT=false CTFINSERT=false CTFCONVERT=false
      CTFMERGE=false CTFDUMP=false DOCC=false GIT=false SCAN_BUILD=false
      EMBEDDED_DEVICE_MAP=false
      # Keep kernel destructors in __mod_term_func, rather than registering
      # them with libc's __cxa_atexit. LLVM otherwise lowers global_dtors late.
      WERROR= "CFLAGS_EXTRA=-Wno-everything -DOS_FIREHOSE_SPI=1 -ffile-prefix-map=$PWD=/minidarwin-xnu-source -fno-register-global-dtors-with-atexit -mllvm -disable-atexit-based-global-dtor-lowering"
      "LD=$CXX -nostdlib -fuse-ld=${ld64}/bin/ld"
    )
    # `all` also installs a linked kernel. Cache only the upstream build phase.
    make -j$NIX_BUILD_CORES "''${makeFlags[@]}" build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/root
    cp -RL ${sources.xnu}/. $out/root/
    chmod -R u+w $out/root
    cp -RL BUILD sdk $out/root/
    python3 ${./relocate-kernel-objects.py} "$PWD" "$out/root"
    runHook postInstall
  '';

  passthru = { inherit targetArch; };
  meta.description = "Compiled XNU release objects and hermetic final-link inputs";
}
