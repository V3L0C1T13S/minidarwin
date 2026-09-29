# Apple's libxml2 fork, with its public library, headers and command-line tools.
{ lib, mkDarwinPackage, sources, toolchain, cmake, gnumake, zlib, icu }:

let
  # libsystem_info and libsystem_m are not available in this source set.
  allowUndefined = {
    "_gethostbyname" = "system_info";
    "_log10" = "system_m";
    "___exp10" = "system_m";
    "_fmod" = "system_m";
  };
  undefinedFlags = lib.concatStringsSep " " (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined));
in

mkDarwinPackage {
  pname = "libxml2";
  version = lib.removePrefix "libxml2-" sources.libxml2.rev;
  src = sources.libxml2;
  inherit toolchain;
  nativeBuildInputs = [ cmake gnumake ];
  passthru.allowUndefined = allowUndefined;

  postPatch = ''
    # These app-specific compatibility quirks and OS logging call services
    # that are absent from the released Darwin userland. Keep standard parser
    # behavior while preserving Apple's other changes.
    for file in libxml2/SAX2.c libxml2/HTMLparser.c libxml2/parser.c libxml2/tree.c; do
      substituteInPlace "$file" \
        --replace-fail '#ifdef __APPLE__' '#if defined(__APPLE__) && !defined(MINIDARWIN)'
    done
    substituteInPlace libxml2/HTMLparser.c \
      --replace-fail '#if __APPLE__' '#if defined(__APPLE__) && !defined(MINIDARWIN)'
    # This target is macOS 26, so both linked-on-or-after gates are true.
    substituteInPlace libxml2/xmlversion.c \
      --replace-fail 'dyld_program_minos_at_least(dyld_fall_2022_os_versions)' 'true' \
      --replace-fail 'dyld_program_sdk_at_least(dyld_2024_SU_E_os_versions)' 'true'
    # Preserve the libxml2.2.dylib ABI name used by macOS clients.
    substituteInPlace libxml2/CMakeLists.txt \
      --replace-fail 'POSITION_INDEPENDENT_CODE ON' 'POSITION_INDEPENDENT_CODE ON SOVERSION 2'
  '';

  configurePhase = ''
    runHook preConfigure
    cmake -S libxml2 -B build -G 'Unix Makefiles' \
      -DCMAKE_SYSTEM_NAME=Darwin \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_C_FLAGS=-DMINIDARWIN \
      -DCMAKE_AR="$AR" \
      -DCMAKE_RANLIB="$RANLIB" \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_INSTALL_NAME_DIR=/usr/lib \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_SYSROOT=${toolchain.sysroot} \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=${toolchain.minOS} \
      -DCMAKE_SHARED_LINKER_FLAGS=${lib.escapeShellArg undefinedFlags} \
      -DCMAKE_EXE_LINKER_FLAGS=${lib.escapeShellArg undefinedFlags} \
      -DLIBXML2_WITH_ICONV=OFF \
      -DLIBXML2_WITH_ICU=ON \
      -DLIBXML2_WITH_LZMA=OFF \
      -DLIBXML2_WITH_PYTHON=OFF \
      -DLIBXML2_WITH_TESTS=OFF \
      -DLIBXML2_WITH_MODULES=OFF \
      -DLIBXML2_WITH_ZLIB=ON \
      -DZLIB_INCLUDE_DIR=${zlib}/usr/include \
      -DZLIB_LIBRARY=${zlib}/usr/lib/libz.dylib \
      -DICU_ROOT=${icu}/usr
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    cmake --build build --parallel ''${NIX_BUILD_CORES:-1}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    DESTDIR="$out" cmake --install build
    install -Dm644 libxml2/Copyright "$out/usr/share/licenses/libxml2/Copyright"
    for f in "$out"/usr/lib/libxml2.*.dylib "$out"/usr/bin/xmllint "$out"/usr/bin/xmlcatalog; do
      [ -L "$f" ] && continue
      md_verify_pure "$f"
      md_verify_signed "$f"
    done
    md_verify_symbols "$out/usr/lib/libxml2.2.dylib" \
      _xmlReadMemory _xmlFreeDoc _xmlParseFile _xmlXPathEvalExpression
    runHook postInstall
  '';

  meta.description = "Apple's libxml2 XML library and tools";
}
