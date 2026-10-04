# libsystem_m: Libm-2026's x86_64 math library, linked as the /usr/lib/system
# member it became. Apple built it in two halves, each `ld -r`'d with its own
# exports and alias lists: `Libm.a` and `libmathCommon.o`. The latter compiles
# with BUILDING_FOR_CARBONCORE_LEGACY=1, which selects the other half of the
# files the two share (fenv.c, log.s, ...); symbols both define, such as
# __remquol, stay private to their half. lld has no -r, so ld64 does that step.
{ lib, mkDarwinPackage, sources, toolchain, libsystemTree2, targetArch, ld64, minOS }:
assert lib.assertMsg (targetArch == "x86_64") "Libm-2026 has no arm64 sources";
let
  # INCLUDED_SOURCE_FILE_NAMES for x86_64: $(PER_ARCH_SRCROOT)/*.{c,s} with
  # PER_ARCH_SRCROOT = Source/Intel.
  intel = lib.filter (f: builtins.match "Source/Intel/[^/]+\\.[cs]" f != null);
  halves = {
    libm = {
      files = intel (import ./libm-sources.nix);
      exports = "Exports/libm_Intel.a.exp";
      aliases = "Exports/libm_Intel.a.alias";
      defines = "";
      # version_info.c is in this target's list (with its per-file flag) and
      # defines __Libm_version, which this half exports.
      extra = ''
        md_compile obj-libm "$CC" -O3 -std=gnu99 -fno-builtin \
          '-DLIBM_VERSION_STRING="Libm-${version}"' -- "$PWD/Source/version_info.c"
      '';
    };
    libmathCommon = {
      files = intel (import ./libmathcommon-sources.nix);
      exports = "Exports/libmathCommonIntel.exp";
      aliases = "Exports/libmathCommonIntel.alias";
      defines = "-DBUILDING_FOR_CARBONCORE_LEGACY=1";
      extra = "";
    };
  };
  version = lib.removePrefix "Libm-" sources.Libm.rev;
in
mkDarwinPackage {
  pname = "minidarwin-libsystem-m";
  inherit version;
  src = sources.Libm;
  inherit toolchain;
  # cctools as spelled sign-extend-word-to-long `movsxw`; LLVM's AT&T parser
  # knows only `movswl`. Same instruction and encoding.
  postPatch = ''
    substituteInPlace Source/Intel/frexp.s --replace-fail movsxw movswl
  '';
  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    # Xcode's header map resolves math_private.h (FreeBSD files) and
    # fenv_private.h (xmm_erfgamma.c) to the project's references under
    # Source/PowerPC; math_private.h's is the endian-generic copy. Expose
    # only those two.
    mkdir -p hmap o/additions
    cp Source/PowerPC/{math_private,fenv_private}.h hmap/
    ${lib.concatStrings (lib.mapAttrsToList (name: h: ''
      mkdir -p obj-${name}
      files=()
      for f in ${lib.escapeShellArgs h.files}; do files+=( "$PWD/$f" ); done
      # OTHER_CFLAGS, PER_ARCH_CFLAGS_x86_64 (less -Wshorten-64-to-32, a
      # warning), GCC_OPTIMIZATION_LEVEL, GCC_C_LANGUAGE_STANDARD;
      # HEADER_SEARCH_PATHS' per-arch half is Source/Intel.
      md_compile obj-${name} "$CC" -O3 -std=gnu99 -fno-builtin -ftrapping-math \
        -D_APPLE_C_SOURCE ${h.defines} -msse3 -mssse3 \
        -ISource/Intel -ISource -Ihmap -- "''${files[@]}"
      ${h.extra}      # Alias lists begin with a quoted comment line; keep the symbol pairs.
      grep '^_' ${h.aliases} > ${name}.alias
      grep '^_' ${h.exports} > ${name}.exp
      ${ld64}/bin/ld -r -arch x86_64 -platform_version macos ${minOS} ${minOS} \
        -alias_list ${name}.alias -exported_symbols_list ${name}.exp \
        -o o/${name}.o $(find obj-${name} -name '*.o' | sort)
    '') halves)}
    # Functions newer than this release that this tree's libraries import
    # (ICU, libxml2): written in terms of Libm's own exports.
    md_compile o/additions "$CC" -O2 -std=gnu99 -- ${./libm-additions.c}
    md_dylib libsystem_m.dylib /usr/lib/system/libsystem_m.dylib o \
      -Wl,-umbrella,System -L${libsystemTree2}/usr/lib/system \
      -lcompiler_rt -lsystem_kernel -lsystem_platform -lsystem_c
    runHook postBuild
  '';
  installPhase = ''
    install -Dm755 libsystem_m.dylib $out/usr/lib/system/libsystem_m.dylib
    md_verify_pure $out/usr/lib/system/libsystem_m.dylib
    md_verify_signed $out/usr/lib/system/libsystem_m.dylib
    md_verify_symbols $out/usr/lib/system/libsystem_m.dylib \
      _log10 _pow _fmod _fma ___fpclassify ___fpclassifyd _fegetenv _fesetenv \
      _fegetround _nextafterf _logbl _scalbnl _fmaxl _tanhf _expf \
      ___exp10 ___sincos_stret
  '';
}
