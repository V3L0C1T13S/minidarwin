# Juniper libxo: structured text, XML, JSON and HTML output.
{ mkDarwinPackage, sources, toolchain, autoreconfHook, gnumake, bison }:

mkDarwinPackage {
  pname = "libxo";
  version = "2.0.0";
  src = sources.libxo;
  inherit toolchain;
  nativeBuildInputs = [ autoreconfHook gnumake bison ];
  passthru.installName = "/usr/lib/libxo.0.dylib";

  postPatch = ''
    # Upstream errors when msgfmt is absent even with gettext disabled.
    substituteInPlace configure.ac \
      --replace-fail 'AC_MSG_FAILURE("could not find msgfmt tool")' \
                     'AC_MSG_NOTICE([msgfmt unavailable; gettext disabled])'
  '';

  configurePhase = ''
    runHook preConfigure
    export lt_cv_prog_gnu_ld=no
    export ac_cv_func_realloc_0_nonnull=yes
    ./configure \
      --build=x86_64-unknown-linux-gnu \
      --host=${toolchain.targetArch}-apple-darwin \
      --prefix=/usr \
      --libdir=/usr/lib \
      --disable-static \
      --disable-gettext \
      --disable-warnings \
      --with-llvm-config=none \
      --with-sdk-path=${toolchain.sysroot} \
      --with-encoder-dir=/usr/lib/libxo/encoder \
      --with-filter-dir=/usr/lib/libxo
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -C libxo -j''${NIX_BUILD_CORES:-1} LIBTOOL=../libtool
    make -C xo -j''${NIX_BUILD_CORES:-1} LIBTOOL=../libtool
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make -C libxo install DESTDIR="$out" LIBTOOL=../libtool
    make -C xo install DESTDIR="$out" LIBTOOL=../libtool
    find "$out" -name '*.la' -delete
    install -Dm644 packaging/libxo.pc "$out/usr/lib/pkgconfig/libxo.pc"
    install -Dm755 libxo-config "$out/usr/bin/libxo-config"
    install -Dm644 LICENSE "$out/usr/share/licenses/libxo/LICENSE"
    md_verify_pure "$out/usr/lib/libxo.0.dylib"
    md_verify_signed "$out/usr/lib/libxo.0.dylib"
    md_verify_pure "$out/usr/bin/xo"
    md_verify_signed "$out/usr/bin/xo"
    md_verify_symbols "$out/usr/lib/libxo.0.dylib" \
      _xo_emit _xo_create _xo_set_style _xo_finish
    runHook postInstall
  '';

  meta.description = "Juniper library for structured text, XML, JSON and HTML output";
}
