# Link-only API probe: target executables cannot run before dyld is packaged.
{ stdenvNoCC, writeText, toolchain, libxo, buildSupport }:

let
  probe = writeText "libxo-probe.c" ''
    #include <libxo/xo.h>

    int main(void) {
      xo_set_style(NULL, XO_STYLE_JSON);
      xo_open_container("probe");
      xo_emit("{:value/%d}", 42);
      xo_close_container("probe");
      return xo_finish();
    }
  '';
in
stdenvNoCC.mkDerivation {
  pname = "minidarwin-libxo-test";
  version = libxo.version;
  dontUnpack = true;
  dontFixup = true;
  nativeBuildInputs = [ toolchain ];

  buildPhase = ''
    runHook preBuild
    source ${buildSupport}
    $CC -I${libxo}/usr/include ${probe} -o probe \
      -L${libxo}/usr/lib -lxo -lSystem
    md_verify_pure probe
    md_verify_signed probe
    $OTOOL -L probe | grep -q '/usr/lib/libxo' || {
      echo 'probe does not link libxo' >&2; exit 1;
    }
    for symbol in _xo_set_style _xo_emit _xo_finish; do
      $NM -u probe | grep -qx "$symbol" || {
        echo "probe does not import $symbol" >&2; exit 1;
      }
    done
    runHook postBuild
  '';

  installPhase = ''
    mkdir -p "$out"
    cp probe "$out/probe"
  '';
}
