# curl-160 from the macOS 26 source set. Like Apple's build, it uses LibreSSL
# for TLS; Secure Transport is not yet in MiniDarwin. No libpsl or GSSAPI.
{ lib, mkDarwinPackage, sources, toolchain, gnumake, perl, libressl, zlib }:

let
  sslInclude = "${libressl}/usr/local/libressl/include";
  sslLib = "${libressl}/usr/lib";

  allowUndefined = {
    "_gethostbyname" = "system_info";
    "_getaddrinfo" = "system_info";
    "_freeaddrinfo" = "system_info";
    "_gai_strerror" = "system_info";
    # openssl.c's have_openssl(), Apple's OpenSSL-or-Secure-Transport probe.
    "_dlsym" = "dyld";
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
    export CPPFLAGS="-I${sslInclude} -I${zlib}/usr/include"
    export LDFLAGS="-L${sslLib} -L${zlib}/usr/lib ${lib.concatStringsSep " " (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined))}"
    export PKG_CONFIG=false
    export ac_cv_func_gethostbyname=yes
    ./configure \
      --build=x86_64-unknown-linux-gnu \
      --host=${toolchain.targetArch}-apple-darwin \
      --prefix=/usr \
      --disable-shared \
      --with-openssl \
      --with-ca-bundle=/etc/ssl/cert.pem \
      --without-ca-path \
      --with-zlib \
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
    # Replace build-time LibreSSL search paths with their target paths.
    for f in $out/usr/bin/curl-config $out/usr/lib/pkgconfig/libcurl.pc $out/usr/lib/libcurl.la; do
      substituteInPlace $f \
        --replace-quiet "-I${sslInclude}" "-I/usr/local/libressl/include" \
        --replace-quiet "-L${sslLib}" "-L/usr/lib" \
        --replace-quiet "-I${zlib}/usr/include" "-I/usr/include" \
        --replace-quiet "-L${zlib}/usr/lib" "-L/usr/lib"
    done
    if grep -rlE '${libressl}|${zlib}' $out; then
      echo "curl: store path of a library leaked into the output" >&2
      exit 1
    fi
    if grep -rlE 'lib(crypto|ssl)\.0\.9\.8|openssl-0\.9\.8' $out; then
      echo "curl: legacy OpenSSL reference leaked into the output" >&2
      exit 1
    fi
    cryptoName=$($OTOOL -D ${libressl}/usr/lib/libcrypto.dylib | tail -n 1)
    sslName=$($OTOOL -D ${libressl}/usr/lib/libssl.dylib | tail -n 1)
    deps=$($OTOOL -L $out/usr/bin/curl | tail -n +2 | awk '{ print $1 }' | sort | tr '\n' ' ')
    expected=$(printf '%s\n' /usr/lib/libSystem.B.dylib /usr/lib/libz.1.dylib "$cryptoName" "$sslName" | sort | tr '\n' ' ')
    if [ "$deps" != "$expected" ]; then
      echo "curl: unexpected load commands: $deps" >&2
      exit 1
    fi
    md_verify_pure $out/usr/bin/curl
    md_verify_signed $out/usr/bin/curl
    runHook postInstall
  '';

  meta.description = "Apple's curl and static libcurl, with LibreSSL and zlib";
}
