# Stage 5: libmach_o.a -- dyld's Mach-O reader (static archive, stage 2 toolchain).
{ lib
, mkDarwinPackage
, sources
, toolchain
}:

let
  sourceFiles = import ./libmach-o-sources.nix;

  # Flags from base.xcconfig + configs/libmach_o.xcconfig.
  cxxFlags = [
    "-std=c++20" # CLANG_CXX_LANGUAGE_STANDARD
    "-Os" # GCC_OPTIMIZATION_LEVEL[config=Release]
    "-fno-exceptions" # GCC_ENABLE_CPP_EXCEPTIONS = NO
    "-fno-rtti" # GCC_ENABLE_CPP_RTTI = NO
    "-fvisibility=hidden" # GCC_SYMBOLS_PRIVATE_EXTERN = YES
    "-fvisibility-inlines-hidden" # GCC_INLINES_ARE_PRIVATE_EXTERN = YES
    "-fno-common"
    "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_NONE" # avoid __libcpp_verbose_abort
    "-DINTERNAL_BUILD=0"
    "-DBUILDING_LIBMACHO=1"
  ];

  # System headers ./include excluded (use SDK's patched <mach-o/*.h>).
  includeDirs = [ "dyld" "common" "mach_o" "lsl" ];

  compatInclude = ./compat; # no-op CrashReporterClient.h (stage 5 only, not in SDK)
in

mkDarwinPackage {
  pname = "libmach_o";
  version = lib.removePrefix "dyld-" sources.dyld.rev;

  src = sources.dyld;
  inherit toolchain;

  # Fix dropped body in LinkerOptimizationHints::valid() (missing LOH checks -> return none).
  patchPhase = ''
    runHook prePatch

    substituteInPlace mach_o/LinkerOptimizationHints.cpp \
      --replace-fail "return std::move(lohErr);" "return Error::none();"

    runHook postPatch
  '';

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    obj=$PWD/o
    mkdir -p $obj

    sources=()
    for f in ${lib.concatStringsSep " " sourceFiles}; do
      [ -f "$PWD/$f" ] || { echo "missing source: $f" >&2; exit 1; }
      sources+=( "$PWD/$f" )
    done

    md_log "libmach_o: ''${#sources[@]} objects"
    md_compile $obj "$CXX" ${lib.escapeShellArgs cxxFlags} \
      ${lib.concatMapStringsSep " " (d: "-I$PWD/${d}") includeDirs} \
      -I${compatInclude} \
      -- "''${sources[@]}"

    md_archive $PWD/libmach_o.a $obj

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 libmach_o.a $out/usr/local/lib/dyld/libmach_o.a

    md_verify_symbols $out/usr/local/lib/dyld/libmach_o.a \
      __ZNK6mach_o12Architecture4nameEv \
      __ZN6mach_o8Platform6byNameENSt3__117basic_string_viewIcNS1_11char_traitsIcEEEE \
      __ZN6mach_o13ChainedFixupsC1EPK26dyld_chained_fixups_headerm \
      __ZN6mach_o5Image15makeExportsTrieEv

    runHook postInstall
  '';

  meta.description = "dyld's Mach-O reader, static";
}
