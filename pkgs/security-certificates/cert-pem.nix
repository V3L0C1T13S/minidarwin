# Stage 6: /private/etc/ssl/cert.pem -- the CA bundle curl is configured with
# (--with-ca-bundle=/etc/ssl/cert.pem).
#
# macOS's own file comes from its LibreSSL, which Apple has not released. This
# one is the macOS 26 root store itself: security_certificates'
# certificates/roots, the set the Security framework trusts, rendered as PEM
# by scripts/roots-to-pem.py. The Apple Platform roots are left out:
# constraints.json limits them to Apple policies, and a CA file has no way to
# say so. Data only, the same for either target arch.
{ lib, stdenvNoCC, sources, python3 }:

stdenvNoCC.mkDerivation {
  pname = "cert-pem";
  version = lib.removePrefix "security_certificates-" sources.security_certificates.rev;

  src = sources.security_certificates;
  nativeBuildInputs = [ python3 ];

  dontConfigure = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild
    python3 ${../../scripts/roots-to-pem.py} . ${sources.security_certificates.rev} > cert.pem
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 cert.pem $out/private/etc/ssl/cert.pem
    runHook postInstall
  '';

  meta.description = "The macOS root store as a PEM CA bundle, /etc/ssl/cert.pem";
}
