# libarchive 3.8.9's bsdtar, installed as /usr/bin/tar (and bsdtar). libarchive
# itself is linked in statically: nothing else in MiniDarwin consumes it, and
# the tree stays free of a dylib with no Apple-shaped install name. Only zlib
# and libbz2 are enabled; xz, zstd, lz4, OpenSSL, iconv and XML are absent.
{ lib, mkDarwinPackage, sources, toolchain, gnumake, zlib, bzip2, copyfile }:

let
  allowUndefined = {
    # Owner and group names, both ways (archive_read_disk_posix.c and
    # archive_write_disk_posix.c).
    "_getgrgid_r" = "system_info";
    "_getgrnam_r" = "system_info";
    "_getpwnam_r" = "system_info";
    "_getpwuid_r" = "system_info";
  };
in

mkDarwinPackage {
  pname = "libarchive";
  version = "3.8.9";
  src = sources.libarchive;
  inherit toolchain;
  nativeBuildInputs = [ gnumake ];
  passthru.allowUndefined = allowUndefined;

  postPatch = ''
    # The only Apple crypto libarchive reaches for is CommonCrypto's AES/PBKDF2/HMAC
    # (zip/7z encryption), and libcommonCrypto is not built here. Take the
    # "no crypto" branch rather than include a header the SDK lacks.
    substituteInPlace libarchive/archive_cryptor_private.h \
      --replace-fail '#  define ARCHIVE_CRYPTOR_USE_Apple_CommonCrypto 1' \
                     '/* minidarwin: no CommonCrypto */'
    substituteInPlace libarchive/archive_hmac_private.h \
      --replace-fail '#  define ARCHIVE_HMAC_USE_Apple_CommonCrypto' \
                     '/* minidarwin: no CommonCrypto */'
  '';

  configurePhase = ''
    runHook preConfigure
    export CPPFLAGS="-I${zlib}/usr/include -I${bzip2.headers}/usr/include"
    export LDFLAGS="-L${zlib}/usr/lib -L${bzip2}/usr/lib -L${copyfile}/usr/lib ${lib.concatStringsSep " " (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined))}"
    export LIBS="-lcopyfile"
    export PKG_CONFIG=false
    ./configure \
      --build=x86_64-unknown-linux-gnu \
      --host=${toolchain.targetArch}-apple-darwin \
      --prefix=/usr \
      --disable-shared \
      --disable-bsdcat \
      --disable-bsdcpio \
      --disable-bsdunzip \
      --disable-acl \
      --disable-xattr \
      --with-zlib \
      --with-bz2lib \
      --without-lzma \
      --without-lzo2 \
      --without-lz4 \
      --without-zstd \
      --without-libb2 \
      --without-iconv \
      --without-nettle \
      --without-openssl \
      --without-mbedtls \
      --without-xml2 \
      --without-expat \
      --without-cng

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j''${NIX_BUILD_CORES:-1} bsdtar
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 bsdtar "$out/usr/bin/bsdtar"
    ln -s bsdtar "$out/usr/bin/tar"
    install -Dm644 tar/bsdtar.1 "$out/usr/share/man/man1/bsdtar.1"
    ln -s bsdtar.1 "$out/usr/share/man/man1/tar.1"
    install -Dm644 COPYING "$out/usr/share/licenses/libarchive/COPYING"
    md_verify_pure "$out/usr/bin/bsdtar"
    md_verify_signed "$out/usr/bin/bsdtar"
    runHook postInstall
  '';

  meta.description = "libarchive's bsdtar, as tar";
}
