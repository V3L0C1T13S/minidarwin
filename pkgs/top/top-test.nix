# Inspect target artifacts without executing them (dyld is not built yet).
{ lib, runCommand, top, ncursesPanel, targetArch }:

runCommand "minidarwin-top-test-${top.version}"
{ nativeBuildInputs = [ top.toolchain ]; }
  ''
    f=${top}/usr/bin/top
    test -x "$f"
    test -s ${top}/usr/share/man/man1/top.1
    test -e ${ncursesPanel}/usr/lib/libpanel.dylib
    $LIPO "$f" -verify_arch ${if targetArch == "aarch64" then "arm64" else "x86_64"}
    $NM -u "$f" | sort -u > imports
    # Both interactive display and Mach/process/disk sampling are preserved.
    for symbol in _new_panel _update_panels _host_statistics _proc_pidinfo \
      _IOServiceGetMatchingServices _CFDictionaryCreateMutable; do
      grep -qx -- "$symbol" imports
    done
    $OTOOL -L "$f" | tail -n +2 | awk '{ print $1 }' | sort -u > deps
    cat > expected <<'EOF'
    /usr/lib/libSystem.B.dylib
    /usr/lib/libncurses.5.4.dylib
    /usr/lib/libpanel.5.4.dylib
    /usr/lib/libutil.dylib
    EOF
    diff -u expected deps
    mkdir -p "$out"
    cp imports deps "$out/"
  ''
