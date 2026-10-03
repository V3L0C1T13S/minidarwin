# Embeddable engine plus interpreter/compiler, built without a host SDK.
{ lib, mkDarwinPackage, sources, toolchain, quickjsBuildRoot }:

let
  librarySources = [
    "quickjs.c"
    "dtoa.c"
    "libregexp.c"
    "libunicode.c"
    "cutils.c"
    "quickjs-libc.c"
  ];
  # libsystem_m and dyld are not built yet (libsystem/absent-members.nix).
  allowUndefined = lib.genAttrs
    (map (s: "_${s}") [
      "acos"
      "acosh"
      "asin"
      "asinh"
      "atan"
      "atan2"
      "atanh"
      "cbrt"
      "ceil"
      "cos"
      "cosh"
      "exp"
      "expm1"
      "fabs"
      "floor"
      "fmod"
      "hypot"
      "log"
      "log1p"
      "log2"
      "log10"
      "modf"
      "pow"
      "sin"
      "sinh"
      "sqrt"
      "tan"
      "tanh"
      "trunc"
    ])
    (_: "system_m") // lib.genAttrs [ "_dlclose" "_dlopen" "_dlsym" ] (_: "dyld");
  missingFlags = lib.escapeShellArgs (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined));
in
mkDarwinPackage {
  pname = "quickjs";
  version = "2026-06-04";
  src = sources.quickjs;
  inherit toolchain;
  passthru = { inherit allowUndefined; };

  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    cp ${quickjsBuildRoot}/share/quickjs/repl.c repl.c
    cflags=(-O2 -fwrapv -funsigned-char -D_GNU_SOURCE '-DCONFIG_VERSION="${quickjsBuildRoot.version}"')
    md_compile "$PWD/obj/libquickjs" "$CC" "''${cflags[@]}" \
      -- ${lib.concatMapStringsSep " " (f: "$PWD/${f}") librarySources}
    md_archive libquickjs.a obj/libquickjs

    mkdir -p bin
    md_compile "$PWD/obj/qjs" "$CC" "''${cflags[@]}" -- "$PWD/qjs.c" "$PWD/repl.c"
    "$CC" -Wl,-export_dynamic ${missingFlags} -o bin/qjs obj/qjs/*.o libquickjs.a -lSystem
    md_compile "$PWD/obj/qjsc" "$CC" "''${cflags[@]}" \
      '-DCONFIG_CC="cc"' '-DCONFIG_PREFIX="/usr"' -- "$PWD/qjsc.c"
    "$CC" ${missingFlags} -o bin/qjsc obj/qjsc/*.o libquickjs.a -lSystem
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/qjs "$out/usr/bin/qjs"
    install -Dm755 bin/qjsc "$out/usr/bin/qjsc"
    install -Dm644 libquickjs.a "$out/usr/lib/quickjs/libquickjs.a"
    install -Dm644 quickjs.h "$out/usr/include/quickjs/quickjs.h"
    install -Dm644 quickjs-libc.h "$out/usr/include/quickjs/quickjs-libc.h"
    install -Dm644 doc/quickjs.texi "$out/usr/share/doc/quickjs/quickjs.texi"
    printf '@set VERSION %s\n' '${quickjsBuildRoot.version}' > "$out/usr/share/doc/quickjs/version.texi"
    install -Dm644 LICENSE "$out/usr/share/licenses/quickjs/LICENSE"
    md_verify_symbols "$out/usr/lib/quickjs/libquickjs.a" \
      _JS_NewRuntime _JS_NewContext _JS_Eval _JS_FreeContext _JS_FreeRuntime \
      _JS_SetMemoryLimit _JS_SetInterruptHandler _js_init_module_std _js_init_module_os
    for binary in qjs qjsc; do
      md_verify_pure "$out/usr/bin/$binary"
      md_verify_signed "$out/usr/bin/$binary"
    done
    runHook postInstall
  '';

  meta = {
    description = "QuickJS JavaScript engine, static embedding library and command-line tools";
    homepage = "https://bellard.org/quickjs/";
    license = lib.licenses.mit;
  };
}
