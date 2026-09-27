# LibreSSL Portable, built against MiniDarwin rather than the host SDK.
# Apple does not publish the LibreSSL sources used by macOS.
{ lib, mkDarwinPackage, sources, toolchain, gnumake, perl }:

let
  # libsystem_info is not in the released source set yet.
  allowUndefined = {
    "_freeaddrinfo" = "system_info";
    "_gai_strerror" = "system_info";
    "_getaddrinfo" = "system_info";
    "_gethostbyaddr" = "system_info";
    "_gethostbyname" = "system_info";
    "_getnameinfo" = "system_info";
    "_getservbyname" = "system_info";
  };
  linkFlags = lib.concatStringsSep " " (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined));
in

mkDarwinPackage {
  pname = "libressl";
  version = "4.3.2";
  src = sources.libressl;
  inherit toolchain;
  nativeBuildInputs = [ gnumake perl ];

  passthru.allowUndefined = allowUndefined;

  postPatch = ''
    # Only the openssl tool is shipped. nc and ocspcheck are separate apps.
    substituteInPlace apps/Makefile.am apps/Makefile.in \
      --replace-fail 'SUBDIRS = ocspcheck openssl nc' 'SUBDIRS = openssl'
  '';

  configurePhase = ''
    runHook preConfigure
    # ld64.lld identifies as LLD, which libtool mistakes for GNU ld and then
    # passes ELF-only --whole-archive/-soname flags to a Mach-O link.
    export lt_cv_prog_gnu_ld=no
    ./configure \
      --build=x86_64-unknown-linux-gnu \
      --host=${toolchain.targetArch}-apple-darwin \
      --prefix=/usr \
      --libdir=/usr/lib \
      --includedir=/usr/local/libressl/include \
      --with-openssldir=/private/etc/ssl \
      --enable-shared \
      --disable-static \
      --disable-tests \
      --disable-asm
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j''${NIX_BUILD_CORES:-1} LDFLAGS=${lib.escapeShellArg linkFlags}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make install DESTDIR="$out" LDFLAGS=${lib.escapeShellArg linkFlags}
    # Libtool archives embed /usr/lib paths and make cross-package libtool
    # links look for build-host .la files instead of the installed dylibs.
    rm "$out"/usr/lib/lib{crypto,ssl,tls}.la
    # certPem supplies the macOS root store at this path in the rootfs.
    rm "$out/private/etc/ssl/cert.pem"
    install -Dm644 COPYING "$out/usr/share/licenses/libressl/COPYING"

    for name in crypto ssl tls; do
      dylib=$(readlink -f "$out/usr/lib/lib$name.dylib")
      [ -f "$dylib" ] || { echo "libressl: missing lib$name.dylib" >&2; exit 1; }
      md_verify_pure "$dylib"
      md_verify_signed "$dylib"
      install_name=$($OTOOL -D "$dylib" | tail -n 1)
      case "$install_name" in
        /usr/lib/lib$name.*.dylib) ;;
        *) echo "libressl: unexpected install name $install_name" >&2; exit 1 ;;
      esac
    done
    md_verify_pure "$out/usr/bin/openssl"
    md_verify_signed "$out/usr/bin/openssl"
    md_verify_symbols "$out/usr/lib/libcrypto.dylib" \
      _EVP_sha256 _X509_verify_cert _SSLeay_version
    md_verify_symbols "$out/usr/lib/libssl.dylib" \
      _SSL_new _SSL_connect _TLS_method

    runHook postInstall
  '';

  meta.description = "LibreSSL Portable libraries and openssl tool for MiniDarwin";
}
