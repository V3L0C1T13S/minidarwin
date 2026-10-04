# Host-only test harness. Never installed into the MiniDarwin rootfs.
{ stdenv, libxml2 }:

stdenv.mkDerivation {
  pname = "minidarwin-launchd-bootstrap";
  version = "0.1.0";
  src = ./.;
  buildInputs = [ libxml2 ];
  buildPhase = ''
    runHook preBuild
    make CPPFLAGS="-I${libxml2.dev}/include/libxml2" LDLIBS="-lxml2" all unit-test
    runHook postBuild
  '';
  installPhase = ''
    mkdir -p $out/bin $out/libexec
    install -m755 launchd launchctl $out/bin/
    install -m755 unit-test $out/libexec/launchd-unit-test
    install -Dm644 ${../../LICENSE} $out/share/licenses/launchd/LICENSE
  '';
  meta.description = "Isolated host test build of MiniDarwin launchd";
}
