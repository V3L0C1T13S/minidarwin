# The same sources built in the host world, to install packages into a rootfs
# from the build machine (MiniDarwin has no dyld yet, so its own mdpkg cannot
# run). Adds the macOS sandbox-exec script runner.
{ lib, stdenv, pkg-config, libxml2, zlib, openssl, python3, bash, coreutils, gnused, gnugrep, findutils }:

stdenv.mkDerivation {
  pname = "mdpkg-bootstrap";
  version = "1.0.0";
  src = ./.;
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ libxml2 zlib openssl ];

  installPhase = ''
    runHook preInstall
    install -Dm755 mdpkg $out/bin/mdpkg
    install -Dm755 sandbox-runner.py $out/libexec/mdpkg-sandbox-runner
    substituteInPlace $out/libexec/mdpkg-sandbox-runner \
      --replace-fail '@python@' '${python3}/bin/python3' \
      --replace-fail '@shell@' '${bash}/bin/bash' \
      --replace-fail '@tools@' '${lib.makeBinPath [ coreutils gnused gnugrep findutils ]}'
    install -Dm644 README.md $out/share/doc/mdpkg/README.md
    runHook postInstall
  '';

  meta.description = "Host build of mdpkg, with a sandbox-exec script runner";
}
