# Inspect target artifacts and compiler output without executing them.
{ runCommand, callPackage, systemCmds, sources, targetArch }:
let
  archHeaders = callPackage ./arch-headers.nix { };
in
runCommand "minidarwin-arch-test-${systemCmds.version}"
{ nativeBuildInputs = [ systemCmds.toolchain ]; }
  ''
    set -euo pipefail
    f=${systemCmds}/usr/bin/arch
    test -x "$f"
    test "$(readlink ${systemCmds}/usr/bin/machine)" = arch
    test -s ${systemCmds}/usr/share/man/man1/arch.1
    test -s ${systemCmds}/usr/share/man/man1/machine.1
    $LIPO "$f" -verify_arch ${if targetArch == "aarch64" then "arm64" else "x86_64"}
    mkdir -p "$out"
    $NM -u "$f" | awk '{ print $NF }' | sort -u > "$out/imports"
    # Keep CPU/subtype selection, exec semantics and the macOS affinity path.
    for symbol in _posix_spawnattr_setarchpref_np _posix_spawnattr_setflags \
      _posix_spawn _posix_spawnp _sysctlbyname _NXGetLocalArchInfo \
      _CFPropertyListCreateWithData _sysdir_start_search_path_enumeration; do
      grep -qx -- "$symbol" "$out/imports"
    done
    $OTOOL -L "$f" | tail -n +2 | awk '{ print $1 }' | sort -u > "$out/deps"
    echo /usr/lib/libSystem.B.dylib > expected
    diff -u expected "$out/deps"

    # Compile the actual upstream predicate on ARM: accepting Intel must not
    # depend on Rosetta being installed. No target program is executed.
    ${if targetArch == "aarch64" then ''
      cp ${sources.system_cmds}/arch/arch.c arch.c
      substituteInPlace arch.c --replace-fail '#include <NSSystemDirectories.h>' ""
      cat > probe.c <<'EOF'
      #define main arch_main
      #include "arch.c"
      int arch_accepts_intel(void) { return isSupportedCPU(CPU_TYPE_X86_64); }
      EOF
      $CC -std=gnu99 -I${archHeaders} -I${./include} \
        -iwithsysroot /System/Library/Frameworks/System.framework/PrivateHeaders \
        -O1 -S -emit-llvm probe.c -o probe.ll
      sed -n '/define .*@arch_accepts_intel(/,/^}/p' probe.ll > "$out/intel-support.ll"
      grep -q 'ret i32 1' "$out/intel-support.ll"
    '' else ""}
  ''
