# Stage 3: libclang_rt.osx.a -- compiler builtins.
# Sources from compiler-rt/lib/builtins/CMakeLists.txt (GENERIC_* via md_cmake_list, arch-specific per targetArch).
{ lib
, mkDarwinPackage
, llvmSource
, llvmVersion
, toolchain
, targetArch
  # false for libcompiler_rt.dylib (needs exports), true for static archive
  , hiddenVisibility ? true
}:

assert lib.assertMsg (targetArch == "aarch64" || targetArch == "x86_64")
  "compiler-rt builtins: no source list for ${targetArch} (see <arch>_SOURCES in compiler-rt/lib/builtins/CMakeLists.txt)";

let
  inherit (toolchain) machoArch;

  isAarch64 = targetArch == "aarch64";

  # CFLAGS from darwin_add_builtin_libraries().
  builtinCFlags = [
    "-fPIC"
    "-O3"
  ]
  ++ lib.optionals hiddenVisibility [
    "-fvisibility=hidden"
    "-DVISIBILITY_HIDDEN"
  ]
  ++ [
    "-Wall"
    "-fomit-frame-pointer"
  ]
  ++ lib.optional isAarch64 "-DHAS_ASM_LSE"
  ++ [
    "-Ithird-party/siphash/include" # for emupac.cpp (siphash)
  ];

  # GENERIC_SOURCES appended for macOS.
  appleGenericSources = [
    # if(NOT FUCHSIA AND NOT COMPILER_RT_BAREMETAL_BUILD AND NOT COMPILER_RT_GPU_BUILD)
    "emutls.c"
    "enable_execute_stack.c"
    "eprintf.c"
    # if(APPLE)
    "atomic_flag_clear.c"
    "atomic_flag_clear_explicit.c"
    "atomic_flag_test_and_set.c"
    "atomic_flag_test_and_set_explicit.c"
    "atomic_signal_fence.c"
    "atomic_thread_fence.c"
    # if(HAVE_UNWIND_H) -- clang ships unwind.h in its resource dir
    "gcc_personality_v0.c"
    # if(NOT FUCHSIA)
    "clear_cache.c"
  ];

  # Arch-specific sources (atomic.c excluded from static, included for dylib).
  archSources =
    if isAarch64 then [
      "cpu_model/aarch64.c"
      "aarch64/emupac.cpp"
      "aarch64/fp_mode.c"
      "aarch64/arm_apple_sme_abi.s" # if APPLE && HAS_AARCH64_SME
    ] else [
      "cpu_model/x86.c"
      "i386/fp_mode.c"
      "x86_64/floatdidf.c"
      "x86_64/floatdisf.c"
      "x86_64/floatundidf.S"
      "x86_64/floatundisf.S"
      "x86_64/floatdixf.c"
      "x86_64/floatundixf.S"
    ];

  # Generic sources superseded by arch-specific versions.
  archSourcesExcludeGeneric = [ "fp_mode.c" ]
    ++ lib.optionals (!isAarch64) [
    "floatdidf.c"
    "floatdisf.c"
    "floatundidf.c"
    "floatundisf.c"
    "floatdixf.c"
    "floatundixf.c"
  ];

  # Outline atomics patterns (aarch64 only).
  lsePatterns = [ "cas" "swp" "ldadd" "ldclr" "ldeor" "ldset" ];
  lseSizes = [ 1 2 4 8 16 ];
  lseModels = [ 1 2 3 4 5 ];
in

mkDarwinPackage {
  pname = "compiler-rt-builtins${lib.optionalString (!hiddenVisibility) "-visible"}";
  version = llvmVersion;

  inherit toolchain;
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    # Copy only needed subtrees.
    mkdir -p src/third-party
    cp -R ${llvmSource}/compiler-rt/lib/builtins src/builtins
    cp -R ${llvmSource}/third-party/siphash src/third-party/siphash
    chmod -R u+w src

    cd src
    export MD_SRCROOT=$PWD
    cml=builtins/CMakeLists.txt

    ############################################################ source list
    {
      md_cmake_list $cml GENERIC_SOURCES
      md_cmake_list $cml GENERIC_TF_SOURCES
      md_cmake_list $cml BF16_SOURCES # if __bf16 available
      ${lib.optionalString (!isAarch64) ''
        md_cmake_list $cml x86_80_BIT_SOURCES # if NOT ANDROID
      ''}
      printf '%s\n' ${lib.escapeShellArgs appleGenericSources}
      ${lib.optionalString (!hiddenVisibility) "echo atomic.c"}
      printf '%s\n' ${lib.escapeShellArgs archSources}
    } | sort -u > all.list

    # Darwin-excludes/osx.txt (fail if per-arch exclusions appear).
    if [ -e builtins/Darwin-excludes/osx-${machoArch}.txt ]; then
      echo "unexpected per-arch Darwin exclusion list -- read it too" >&2
      exit 1
    fi
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' builtins/Darwin-excludes/osx.txt \
      | sort -u > excluded.list

    while IFS= read -r f; do
      base=$(basename "$f"); base="''${base%.*}"
      if grep -qx "$base" excluded.list; then continue; fi
      case " ${lib.concatStringsSep " " archSourcesExcludeGeneric} " in
        *" $f "*) continue ;;
      esac
      echo "builtins/$f"
    done < all.list > sources.list

    md_log "compiler-rt builtins: $(wc -l < sources.list) sources for ${machoArch}"
    for f in $(cat sources.list); do
      [ -e "$f" ] || { echo "missing builtins source: $f" >&2; exit 1; }
    done

    ############################################################ compile
    obj=$PWD/o
    mkdir -p $obj

    ${if isAarch64 then ''
      # arm_apple_sme_abi.s needs -march=armv8a+sme.
      grep -v 'arm_apple_sme_abi\.s$' sources.list > sources.plain
      md_compile $obj "$CC" ${lib.escapeShellArgs builtinCFlags} \
        -- $(cat sources.plain)
      md_compile $obj "$CC" ${lib.escapeShellArgs builtinCFlags} -march=armv8a+sme \
        -- builtins/aarch64/arm_apple_sme_abi.s
    '' else ''
      md_compile $obj "$CC" ${lib.escapeShellArgs builtinCFlags} \
        -- $(cat sources.list)
    ''}

    ############################################################ outline atomics (aarch64 only)
    ${lib.optionalString isAarch64 ''
      # One object per (pattern, size, model) from lse.S.
      mkdir -p builtins/lse
      n=0
      for pat in ${lib.concatStringsSep " " lsePatterns}; do
        for size in ${lib.concatStringsSep " " (map toString lseSizes)}; do
          [ "$pat" = cas ] || [ "$size" != 16 ] || continue
          for model in ${lib.concatStringsSep " " (map toString lseModels)}; do
            h=builtins/lse/outline_atomic_''${pat}''${size}_''${model}.S
            cp builtins/aarch64/lse.S $h
            md_compile $obj "$CC" ${lib.escapeShellArgs builtinCFlags} \
              -DL_$pat -DSIZE=$size -DMODEL=$model -Ibuiltins \
              -- $h
            n=$((n + 1))
          done
        done
      done
      md_log "compiler-rt builtins: $n outline atomics helpers"
      [ "$n" = 125 ] || { echo "expected 125 outline atomics helpers, got $n" >&2; exit 1; }
    ''}

    ############################################################ archive
    md_archive $PWD/libclang_rt.osx.a $obj

    runHook postBuild
  '';

  # Layout required by clang driver.
  installPhase = ''
    runHook preInstall

    install -Dm644 libclang_rt.osx.a $out/lib/darwin/libclang_rt.osx.a

    # Spot-check key routines.
    md_verify_symbols $out/lib/darwin/libclang_rt.osx.a \
      ___udivti3 ___divti3 ___floatuntidf ___truncdfhf2 \
      ___clear_cache \
      ${if isAarch64 then ''
        __aarch64_cas8_acq_rel __aarch64_ldadd4_relax \
        ___aarch64_have_lse_atomics \
        ___init_cpu_features_resolver
      '' else ''
        ___floatundixf ___divxc3 ___fixxfti \
        ___cpu_indicator_init
      ''}

    runHook postInstall
  '';

  meta.description = "compiler-rt builtins for ${targetArch}-apple-darwin";
}
