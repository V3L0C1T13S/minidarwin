# Apple's OpenSSL098-85 (OpenSSL 0.9.8zh), the last release of the legacy
# libraries, built as openssl.xcodeproj's Release targets: crypto.0.9.8,
# ssl.0.9.8 and openssl, plus the install aggregates' files. The project is
# not part of the macOS 26 source set; curl links it for TLS, in place of
# Apple's unreleased LibreSSL.
#
# Layout is Apple's, not upstream's: the dylibs in /usr/lib, but the openssl
# tool and headers under /usr/local/openssl-0.9.8, and OPENSSLDIR (the
# checked-in opensslconf.h, not Configure's) is /System/Library/OpenSSL.
# Upstream's Configure/Makefile is not run.
#
# Differences from Apple's build, each forced by something unreleased:
# - x509_vfy_apple.c is not compiled. It replaces X509_verify_cert with one
#   that asks TrustEvaluationAgent.framework (private, never released), and
#   x509_vfy.c renames OpenSSL's own under __APPLE__ to make room; that
#   rename is undone, so X509_verify_cert is upstream's verifier.
# - ZLIB is not defined: libz is not in the tree, so no compression methods.
# - The arm64 build uses the x86_64 preprocessor definitions. The project
#   predates arm64 and has none for it; everything arch-specific in them
#   (L_ENDIAN, MD32_REG_T) holds there too, and opensslconf.h switches its
#   word sizes on __LP64__.
# Its OpenSourceVersions/OpenSourceLicenses files are not installed.
{ lib
, mkDarwinPackage
, sources
, toolchain
, perl
}:

let
  src = sources.OpenSSL098;

  # x509_vfy_apple.c includes <TrustEvaluationAgent/TrustEvaluationAgent.h>.
  notCompiled = [ "src/crypto/x509/x509_vfy_apple.c" ];
  cryptoSrcs = lib.subtractLists notCompiled (import ./libcrypto-sources.nix);
  sslSrcs = import ./libssl-sources.nix;
  opensslSrcs = import ./openssl-sources.nix;

  # The project's Release configuration: GCC_OPTIMIZATION_LEVEL = 3,
  # GCC_PREPROCESSOR_DEFINITIONS[arch=x86_64] less ZLIB, and
  # HEADER_SEARCH_PATHS = $(SRCROOT)/src/include. Xcode's header map makes
  # every project header visible by name ("cryptlib.h", "e_os.h",
  # "buildinf.h", ...); the -iquote list is the directories those live in.
  cflags = [
    "-O3"
    "-D_REENTRANT"
    "-DDSO_DLFCN"
    "-DHAVE_DLFCN_H"
    "-DL_ENDIAN"
    "-DMD32_REG_T=int"
    "-DOPENSSL_NO_IDEA"
    "-DOPENSSL_PIC"
    "-DOPENSSL_THREADS"
    "-Isrc/include"
    "-iquote"
    "src"
    "-iquote"
    "src/crypto"
    "-iquote"
    "src/MacOS"
  ];

  # Imports nothing in the tree defines yet, per product.
  cryptoUndefined = {
    # rand_unix.c/ui_openssl.c/bss_log.c
    "_syslog$DARWIN_EXTSN" = "system_asl";
    "_openlog" = "system_asl";
    "_closelog" = "system_asl";
    # DSO_DLFCN: dso_dlfcn.c
    "_dlopen" = "dyld";
    "_dlsym" = "dyld";
    "_dlclose" = "dyld";
    "_dlerror" = "dyld";
    # b_sock.c
    "_gethostbyname" = "system_info";
    "_getservbyname" = "system_info";
  };
  sslUndefined = { };
  opensslUndefined = {
    # s_socket.c
    "_gethostbyname" = "system_info";
    "_gethostbyaddr" = "system_info";
    "_getservbyname" = "system_info";
  };
  allowUndefined = cryptoUndefined // sslUndefined // opensslUndefined;

  uflags = attrs: lib.escapeShellArgs (map (s: "-Wl,-U,${s}") (lib.attrNames attrs));

  # The two Copy Headers phases (install only), to
  # /usr/local/openssl-0.9.8/include/openssl.
  headers = [
    "aes.h"
    "asn1.h"
    "asn1_mac.h"
    "asn1t.h"
    "bio.h"
    "blowfish.h"
    "bn.h"
    "buffer.h"
    "cast.h"
    "comp.h"
    "conf.h"
    "conf_api.h"
    "crypto.h"
    "des.h"
    "des_old.h"
    "dh.h"
    "dsa.h"
    "dso.h"
    "e_os2.h"
    "ebcdic.h"
    "ec.h"
    "ecdh.h"
    "ecdsa.h"
    "engine.h"
    "err.h"
    "evp.h"
    "hmac.h"
    "krb5_asn.h"
    "lhash.h"
    "md2.h"
    "md4.h"
    "md5.h"
    "mdc2.h"
    "obj_mac.h"
    "objects.h"
    "ocsp.h"
    "opensslconf.h"
    "opensslv.h"
    "ossl_typ.h"
    "pem.h"
    "pem2.h"
    "pkcs12.h"
    "pkcs7.h"
    "pq_compat.h"
    "pqueue.h"
    "rand.h"
    "rc2.h"
    "rc4.h"
    "ripemd.h"
    "rsa.h"
    "safestack.h"
    "seed.h"
    "sha.h"
    "stack.h"
    "store.h"
    "symhacks.h"
    "tmdiff.h"
    "txt_db.h"
    "ui.h"
    "ui_compat.h"
    "x509.h"
    "x509_vfy.h"
    "x509v3.h"
    # ssl.0.9.8's
    "dtls1.h"
    "kssl.h"
    "ssl.h"
    "ssl2.h"
    "ssl23.h"
    "ssl3.h"
    "tls1.h"
  ];

  # Each product's load commands must be exactly `expected`; `self` is a
  # dylib's own install name, which otool lists among them.
  checkLinks = f: self: expected: ''
    deps=$($OTOOL -L ${f} | tail -n +2 | awk '{ print $1 }' | grep -vxF -e "${self}" | sort | tr '\n' ' ')
    if [ "$deps" != "${lib.concatStringsSep " " (lib.sort (a: b: a < b) expected)} " ]; then
      echo "${f}: unexpected load commands: $deps" >&2
      exit 1
    fi
  '';
  checkStale = f: attrs: ''
    $NM -u ${f} | awk '{ print $NF }' | sort -u > imports
    for s in ${lib.escapeShellArgs (lib.attrNames attrs)}; do
      grep -qx -- "$s" imports || {
        echo "${f}: declares $s absent but does not import it" >&2
        exit 1; }
    done
  '';
in

mkDarwinPackage {
  pname = "openssl098";
  version = lib.removePrefix "OpenSSL098-" src.rev;
  inherit src toolchain;
  nativeBuildInputs = [ perl ];

  passthru.allowUndefined = allowUndefined; # for rootfs closure check

  postPatch = ''
    substituteInPlace src/crypto/x509/x509_vfy.c \
      --replace-fail '#define X509_verify_cert X509_verify_cert_orig' \
        '/* x509_vfy_apple.c (TrustEvaluationAgent) is not built. */'
  '';

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    v=0.9.8 # DYLIB_CURRENT_VERSION = DYLIB_COMPATIBILITY_VERSION

    md_compile $PWD/obj/crypto "$CC" ${lib.escapeShellArgs cflags} \
      -- ${lib.concatMapStringsSep " " (f: "$PWD/${f}") cryptoSrcs}
    MD_COMPAT_VERSION=$v MD_CURRENT_VERSION=$v \
      md_dylib libcrypto.0.9.8.dylib /usr/lib/libcrypto.0.9.8.dylib obj/crypto \
        ${uflags cryptoUndefined} -lSystem

    md_compile $PWD/obj/ssl "$CC" ${lib.escapeShellArgs cflags} \
      -- ${lib.concatMapStringsSep " " (f: "$PWD/${f}") sslSrcs}
    MD_COMPAT_VERSION=$v MD_CURRENT_VERSION=$v \
      md_dylib libssl.0.9.8.dylib /usr/lib/libssl.0.9.8.dylib obj/ssl \
        ${uflags sslUndefined} ./libcrypto.0.9.8.dylib -lSystem

    # The openssl target adds MONOLITH to the project's definitions.
    md_compile $PWD/obj/openssl "$CC" ${lib.escapeShellArgs cflags} -DMONOLITH \
      -- ${lib.concatMapStringsSep " " (f: "$PWD/${f}") opensslSrcs}
    "$CC" -o openssl $(find obj/openssl -name '*.o' | sort) \
      ${uflags opensslUndefined} ./libcrypto.0.9.8.dylib ./libssl.0.9.8.dylib -lSystem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    lib=$out/usr/lib
    install -Dm755 libcrypto.0.9.8.dylib $lib/libcrypto.0.9.8.dylib
    install -Dm755 libssl.0.9.8.dylib $lib/libssl.0.9.8.dylib
    install -Dm755 openssl $out/usr/local/openssl-0.9.8/bin/openssl

    # Install symlinks and scripts
    install -Dm755 src/tools/c_rehash $out/usr/bin/c_rehash
    ln -s libcrypto.0.9.8.dylib $lib/libcrypto.dylib
    ln -s libssl.0.9.8.dylib $lib/libssl.dylib

    # Install Config. certs/ and private/ are 0644 in Apple's script; the
    # rootfs format has only 0755 directories.
    sys=$out/System/Library/OpenSSL
    install -d $sys/certs $sys/private
    install -Dm644 src/apps/openssl.cnf $sys/openssl.cnf
    install -Dm755 -t $sys/misc src/apps/CA.pl src/apps/CA.sh \
      src/tools/c_hash src/tools/c_info src/tools/c_issuer src/tools/c_name

    # Install pkgconfig
    ver=$(cat src/.version)
    for pc in pkgconfigs/*.pc; do
      sed "s/SSL_VERSION/$ver/" $pc > $TMPDIR/''${pc##*/}
      install -Dm644 $TMPDIR/''${pc##*/} $lib/pkgconfig/''${pc##*/}
    done

    # Copy Headers, then the Deprecate Prototypes aggregate over them.
    inc=$out/usr/local/openssl-0.9.8/include
    for h in ${lib.escapeShellArgs headers}; do
      install -Dm644 src/include/openssl/$h $inc/openssl/$h
    done
    # Its self-check compiles every header with `clang` from PATH: make
    # that the target compiler, against the sysroot.
    mkdir -p $TMPDIR/bin
    printf '#!/bin/sh\nexec %s "$@"\n' "$CC" > $TMPDIR/bin/clang
    chmod +x $TMPDIR/bin/clang
    PATH=$TMPDIR/bin:$PATH perl bin/deprecate-prototypes.pl $inc

    # Install manpages: pod2man over doc/{apps,crypto,ssl}, NAME aliases as
    # symlinks, then c_rehash's.
    install -d $out/usr/share/man/man{1,3,5,7}
    mkdir -p $TMPDIR/man
    SRCROOT=$PWD DSTROOT=$out DYLIB_CURRENT_VERSION=$v TEMP_FILES_DIR=$TMPDIR/man \
      INSTALL_OWNER=$(id -u) INSTALL_GROUP=$(id -g) perl bin/install_manpages
    ln -sf verify.1ssl $out/usr/share/man/man1/c_rehash.1ssl
    chmod -R u+w,go-w $out

    ${checkLinks "$lib/libcrypto.0.9.8.dylib" "/usr/lib/libcrypto.0.9.8.dylib" [ "/usr/lib/libSystem.B.dylib" ]}
    ${checkLinks "$lib/libssl.0.9.8.dylib" "/usr/lib/libssl.0.9.8.dylib" [ "/usr/lib/libSystem.B.dylib" "/usr/lib/libcrypto.0.9.8.dylib" ]}
    ${checkLinks "$out/usr/local/openssl-0.9.8/bin/openssl" "" [ "/usr/lib/libSystem.B.dylib" "/usr/lib/libcrypto.0.9.8.dylib" "/usr/lib/libssl.0.9.8.dylib" ]}
    ${checkStale "$lib/libcrypto.0.9.8.dylib" cryptoUndefined}
    ${checkStale "$lib/libssl.0.9.8.dylib" sslUndefined}
    ${checkStale "$out/usr/local/openssl-0.9.8/bin/openssl" opensslUndefined}

    for f in $lib/lib{crypto,ssl}.0.9.8.dylib $out/usr/local/openssl-0.9.8/bin/openssl; do
      md_verify_pure "$f"
      md_verify_signed "$f"
    done
    md_verify_symbols $lib/libcrypto.0.9.8.dylib \
      _EVP_sha256 _X509_verify_cert _ENGINE_load_builtin_engines _DSO_load _SSLeay_version
    md_verify_symbols $lib/libssl.0.9.8.dylib \
      _SSL_new _SSL_connect _SSL_library_init _TLSv1_method

    runHook postInstall
  '';

  meta.description = "Apple's OpenSSL 0.9.8 libcrypto/libssl dylibs and openssl tool";
}
