# Apple's ICU-76133, built for the target Darwin ABI.
{ lib
, mkDarwinPackage
, sources
, toolchain
, stdenv
, gnumake
, python3
, icuBuildRoot
}:

let
  version = "76.1";
  major = lib.versions.major version;
  buildRoot = icuBuildRoot;
  allowUndefined = {
    "_acos" = "system_m";
    "_asin" = "system_m";
    "_atan" = "system_m";
    "_atan2" = "system_m";
    "_cos" = "system_m";
    "_expf" = "system_m";
    "_fmod" = "system_m";
    "_log" = "system_m";
    "_modf" = "system_m";
    "_pow" = "system_m";
    "_sin" = "system_m";
    "_tan" = "system_m";
    "_tanhf" = "system_m";
    "___exp10" = "system_m";
    "___sincos_stret" = "system_m";
  };
  undefinedFlags = lib.concatStringsSep " "
    (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined));
in

mkDarwinPackage {
  pname = "icu";
  inherit version;
  src = sources.ICU;
  inherit toolchain;
  nativeBuildInputs = [ gnumake python3 ];
  passthru.allowUndefined = allowUndefined;

  postPatch = ''
    # These upstream diagnostics use Apple's private OS logging service, which
    # is outside MiniDarwin. The call sites only report diagnostics; they do
    # not affect ICU's Unicode, collation, or date-formatting behavior.
    mkdir -p minidarwin/os
    cat > minidarwin/os/log.h <<'EOF'
    #pragma once
    #define OS_LOG_DEFAULT ((void *)0)
    #define os_log(...) ((void)0)
    #define os_log_error(...) ((void)0)
    EOF
    cat > minidarwin/os/feature_private.h <<'EOF'
    #pragma once
    #define os_feature_enabled(domain, feature) 0
    EOF
    # The upstream install rule expects the ICU source archive's shallower
    # layout; expose Apple's license at that relative location.
    ln -sf ../LICENSE ../LICENSE
  '';
  CFLAGS = "-O2 -DU_SHOW_CPLUSPLUS_API=1 -DU_SHOW_INTERNAL_API=1";
  CXXFLAGS = "-O2 -std=c++17 -DU_SHOW_CPLUSPLUS_API=1 -DU_SHOW_INTERNAL_API=1";

  postUnpack = ''
    sourceRoot="$sourceRoot/icu/icu4c/source"
    echo "ICU source root: $sourceRoot"
  '';

  configurePhase = ''
    runHook preConfigure
    mkdir -p build
    cd build
    CPPFLAGS="-I$PWD/../minidarwin" \
    LIBS=${lib.escapeShellArg "${undefinedFlags} -lSystem -lc++ -lc++abi"} \
    ../configure \
      --build=${stdenv.buildPlatform.config} \
      --host=${toolchain.targetArch}-apple-darwin \
      --with-cross-build=${buildRoot} \
      --prefix=/usr \
      --enable-rpath \
      --disable-debug \
      --disable-renaming \
      --disable-extras \
      --disable-layout \
      --disable-samples \
      --disable-tests \
      --with-data-packaging=archive
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j''${NIX_BUILD_CORES:-1}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make install DESTDIR="$out"
    # ICU's upstream install includes target-side generators; they are build
    # tools, not part of MiniDarwin's runtime library set.
    rm -rf "$out/usr/bin" "$out/usr/sbin"
    install -Dm644 ../../LICENSE "$out/usr/share/licenses/icu/LICENSE"
    for f in "$out"/usr/lib/libicu*.dylib; do
      [ -e "$f" ] || continue
      md_verify_pure "$f"
      md_verify_signed "$f"
    done
    md_verify_symbols "$out/usr/lib/libicuuc.${major}.dylib" \
      _u_strlen _u_strToUpper _u_charType
    runHook postInstall
  '';

  meta.description = "Apple's ICU Unicode and globalization libraries, headers and data";
}
