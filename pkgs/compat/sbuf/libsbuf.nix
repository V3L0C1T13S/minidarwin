# FreeBSD-derived userland sbuf implementation, including Apple's usbuf alias.
{ mkDarwinPackage, toolchain, runCommand }:

let
  headers = runCommand "libsbuf-headers" { } ''
    install -Dm644 ${./sbuf.h} $out/usr/include/sbuf.h
    ln -s sbuf.h $out/usr/include/usbuf.h
  '';
in
mkDarwinPackage {
  pname = "libsbuf";
  version = "1.0.0";
  src = ./.;
  inherit toolchain;

  passthru.installName = "/usr/lib/libsbuf.dylib";
  passthru.headers = headers;

  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    md_compile $PWD/obj "$CC" -std=gnu99 -Os -fno-common -- $PWD/sbuf.c
    md_dylib libsbuf.dylib /usr/lib/libsbuf.dylib obj -lSystem
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 libsbuf.dylib $out/usr/lib/libsbuf.dylib
    cp -R ${headers}/usr/include $out/usr/
    # Retain the source's third-party license in the shipped tree.
    mkdir -p $out/usr/share/licenses/libsbuf
    sed -n '1,/^ \*\//p' sbuf.c > $out/usr/share/licenses/libsbuf/LICENSE
    md_verify_pure $out/usr/lib/libsbuf.dylib
    md_verify_signed $out/usr/lib/libsbuf.dylib
    md_verify_symbols $out/usr/lib/libsbuf.dylib \
      _sbuf_new _sbuf_clear _sbuf_cat _sbuf_putc _sbuf_len \
      _sbuf_printf _sbuf_finish _sbuf_data _sbuf_delete
    deps=$($OTOOL -L $out/usr/lib/libsbuf.dylib | tail -n +2 | \
      awk '{ print $1 }' | grep -vx /usr/lib/libsbuf.dylib | sort -u)
    if [ "$deps" != /usr/lib/libSystem.B.dylib ]; then
      echo "libsbuf: links other than libSystem: $deps" >&2
      exit 1
    fi
    runHook postInstall
  '';

  meta.description = "Userland string buffers, linked against minidarwin's libSystem";
}
