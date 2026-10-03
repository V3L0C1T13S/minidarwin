# Host behavior is checked by quickjsBuildRoot; target probes are link-only.
{ lib, runCommand, quickjs, quickjsBuildRoot, buildSupport }:

runCommand "minidarwin-quickjs-test-${quickjs.version}"
{ nativeBuildInputs = [ quickjs.toolchain ]; }
  ''
    source ${buildSupport}
    $CC -I${quickjs}/usr/include/quickjs ${./embedding-probe.c} \
      ${quickjs}/usr/lib/quickjs/libquickjs.a -lSystem \
      ${lib.escapeShellArgs (map (s: "-Wl,-U,${s}") (lib.attrNames quickjs.allowUndefined))} \
      -o embedding-probe
    $CC -I${quickjs}/usr/include/quickjs ${quickjsBuildRoot}/share/quickjs/smoke.c \
      ${quickjs}/usr/lib/quickjs/libquickjs.a -lSystem \
      ${lib.escapeShellArgs (map (s: "-Wl,-U,${s}") (lib.attrNames quickjs.allowUndefined))} \
      -o bytecode-probe
    md_verify_symbols embedding-probe _JS_NewRuntime _JS_Eval _JS_GetException
    md_verify_symbols bytecode-probe _JS_ReadObject _JS_EvalFunction
    for binary in ${quickjs}/usr/bin/qjs ${quickjs}/usr/bin/qjsc \
      embedding-probe bytecode-probe; do
      $LIPO "$binary" -verify_arch ${quickjs.toolchain.machoArch}
      md_verify_pure "$binary"
      md_verify_signed "$binary"
      $OTOOL -L "$binary" | tail -n +2 | awk '{ print $1 }' | sort -u > deps
      echo /usr/lib/libSystem.B.dylib > expected
      diff -u expected deps
    done
    # llvm-lipo cannot verify an archive directly; inspect every member.
    mkdir archive
    (
      cd archive
      $AR x ${quickjs}/usr/lib/quickjs/libquickjs.a
      for object in *.o; do
        $LIPO "$object" -verify_arch ${quickjs.toolchain.machoArch}
      done
    )
    test -s ${quickjs}/usr/include/quickjs/quickjs-libc.h
    test -s ${quickjs}/usr/share/licenses/quickjs/LICENSE
    mkdir -p "$out"
    cp embedding-probe bytecode-probe "$out/"
  ''
