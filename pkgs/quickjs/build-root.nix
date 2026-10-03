# Host tools from the same pin as the target: only these execute during builds.
{ lib, stdenv, sources, gnumake }:

stdenv.mkDerivation {
  pname = "minidarwin-quickjs-build-root";
  version = "2026-06-04";
  src = sources.quickjs;
  nativeBuildInputs = [ gnumake ];
  dontConfigure = true;
  dontFixup = true;
  enableParallelBuilding = true;
  makeFlags = [ "CC=${stdenv.cc}/bin/cc" "AR=${stdenv.cc}/bin/ar" "CONFIG_LTO=" ];
  buildFlags = [ "qjs" "qjsc" "libquickjs.a" ];
  doCheck = true;
  checkTarget = "test";

  postCheck = ''
    $CC -I. ${./embedding-probe.c} libquickjs.a -lm -ldl -lpthread -o embedding-probe
    ./embedding-probe
    printf 'print("quickjs-bytecode-ok");\n' > smoke.js
    ./qjsc -e -o smoke.c smoke.js
    $CC -I. smoke.c libquickjs.a -lm -ldl -lpthread -o smoke
    test "$(./smoke)" = quickjs-bytecode-ok
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share/quickjs"
    install -m755 qjs qjsc "$out/bin"
    install -m644 repl.c smoke.c "$out/share/quickjs"
    runHook postInstall
  '';

  meta = {
    description = "Native QuickJS tools and generated REPL for MiniDarwin cross builds";
    license = lib.licenses.mit;
  };
}
