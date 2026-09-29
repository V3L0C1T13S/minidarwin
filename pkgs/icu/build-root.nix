# Native ICU utilities used to generate target data during cross builds.
{ lib, stdenv, sources, gnumake, python3 }:

stdenv.mkDerivation {
  pname = "minidarwin-icu-build-root";
  version = "76.1";
  src = sources.ICU;
  nativeBuildInputs = [ gnumake python3 ];
  dontFixup = true;

  postUnpack = ''
    sourceRoot="$sourceRoot/icu/icu4c/source"
  '';

  postPatch = ''
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
  '';

  configurePhase = ''
    runHook preConfigure
    mkdir -p build
    cd build
    CPPFLAGS="-I$PWD/../minidarwin" \
    CFLAGS="-O2 -DU_SHOW_CPLUSPLUS_API=1 -DU_SHOW_INTERNAL_API=1" \
    CXXFLAGS="-O2 -std=c++17 -DU_SHOW_CPLUSPLUS_API=1 -DU_SHOW_INTERNAL_API=1" \
    ../configure \
      --build=${stdenv.buildPlatform.config} \
      --host=${stdenv.hostPlatform.config} \
      --prefix=/usr \
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
    cp -R . "$out"
    runHook postInstall
  '';

  meta.description = "Native ICU tools for MiniDarwin cross builds";
}
