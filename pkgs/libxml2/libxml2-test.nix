# Link-only API probe: target binaries cannot run until dyld is packaged.
{ stdenvNoCC, writeText, toolchain, libxml2, buildSupport }:

let
  probe = writeText "libxml2-probe.c" ''
    #include <libxml/parser.h>
    #include <libxml/tree.h>
    #include <libxml/xpath.h>

    int main(void) {
      xmlDocPtr doc = xmlReadMemory("<root><item/></root>", 20,
                                    "probe.xml", NULL, XML_PARSE_NONET);
      if (doc == NULL) return 1;
      xmlXPathContextPtr context = xmlXPathNewContext(doc);
      xmlXPathObjectPtr result = xmlXPathEvalExpression(BAD_CAST "count(/root/item)", context);
      int ok = result != NULL && result->floatval == 1.0;
      xmlXPathFreeObject(result);
      xmlXPathFreeContext(context);
      xmlFreeDoc(doc);
      return !ok;
    }
  '';
in

stdenvNoCC.mkDerivation {
  pname = "minidarwin-libxml2-test";
  version = libxml2.version;
  dontUnpack = true;
  dontFixup = true;
  nativeBuildInputs = [ toolchain ];

  buildPhase = ''
    runHook preBuild
    source ${buildSupport}
    $CC -I${libxml2}/usr/include/libxml2 ${probe} -o probe \
      -L${libxml2}/usr/lib -lxml2 -lSystem
    md_verify_pure probe
    md_verify_signed probe
    $OTOOL -L probe | grep -q '/usr/lib/libxml2.2.dylib' || {
      echo 'probe does not link libxml2.2.dylib' >&2; exit 1;
    }
    for symbol in _xmlReadMemory _xmlXPathEvalExpression _xmlFreeDoc; do
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
