# curl-160 from the macOS 26 source set. The current SDK has no TLS backend,
# zlib, libpsl or GSSAPI, so build the HTTP/FTP capable configuration.
{ lib, mkDarwinPackage, sources, toolchain, gnumake, perl }:

let
  allowUndefined = {
    "_gethostbyname" = "system_info";
    "_getaddrinfo" = "system_info";
    "_freeaddrinfo" = "system_info";
    "_gai_strerror" = "system_info";
  };
in

mkDarwinPackage {
  pname = "curl";
  version = lib.removePrefix "curl-" sources.curl.rev;
  src = sources.curl;
  inherit toolchain;
  nativeBuildInputs = [ gnumake perl ];
  passthru.allowUndefined = allowUndefined;

  postPatch = ''
    # Configure assumes all three Apple frameworks exist on macOS. They are
    # not part of the current MiniDarwin SDK.
    substituteInPlace curl/configure \
      --replace-fail 'build_for_macos="yes"' 'build_for_macos="no"'
    substituteInPlace curl/lib/curl_setup.h \
      --replace-fail '#    define CURL_MACOS_CALL_COPYPROXIES 1' \
        '/* SystemConfiguration is not available in MiniDarwin. */'
    # Select curl's bundled SHA-256 implementation instead of CommonCrypto.
    substituteInPlace curl/lib/sha256.c \
      --replace-fail '#elif (defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && ' \
        '#elif 0 && (defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && '
  '';

  configurePhase = ''
    runHook preConfigure
    cd curl
    export LDFLAGS="${lib.concatStringsSep " " (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined))}"
    export ac_cv_func_gethostbyname=yes
    ./configure \
      --build=x86_64-unknown-linux-gnu \
      --host=${toolchain.targetArch}-apple-darwin \
      --prefix=/usr \
      --disable-shared \
      --without-ssl \
      --without-zlib \
      --without-brotli \
      --without-zstd \
      --without-libpsl \
      --without-libidn2 \
      --without-nghttp2 \
      --without-ngtcp2 \
      --without-nghttp3 \
      --without-librtmp \
      --without-gssapi \
      --disable-ldap \
      --disable-ldaps \
      --disable-manual
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j''${NIX_BUILD_CORES:-1}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make install DESTDIR=$out
    # curl-config exposes the configure-time compiler path in --cc and
    # --configure. It must describe the target tool, not the Nix store input.
    substituteInPlace $out/usr/bin/curl-config --replace-fail "$CC" cc
    md_verify_pure $out/usr/bin/curl
    md_verify_signed $out/usr/bin/curl
    runHook postInstall
  '';

  meta.description = "Apple's curl and static libcurl (without TLS)";
}
