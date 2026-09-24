# WIP: not wired into the package scope; the cross build still needs work.
# Apple's ksh-42 release contains the AST source and bootstrap as nested archives.
{ lib, mkDarwinPackage, sources, toolchain, stdenv, bison }:

mkDarwinPackage {
  pname = "ksh";
  version = lib.removePrefix "ksh-" sources.ksh.rev;
  src = sources.ksh;
  inherit toolchain;
  nativeBuildInputs = [ stdenv.cc bison ];

  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    cd ksh
    tar -xzf ../INIT.2012-08-01.tgz
    tar -xzf ../ast-ksh.2012-08-01.tgz
    # Clang 21 requires va_copy's source to be an lvalue. AST passes a
    # va_arg temporary in these two places.
    for file in src/lib/libast/hash/hashalloc.c src/lib/libast/string/tokscan.c; do
      substituteInPlace "$file" \
        --replace-fail 'va_copy(ap, va_listval(va_arg(ap, va_listarg)));' \
          'va_listarg next_ap = va_arg(ap, va_listarg); va_copy(ap, va_listval(next_ap));'
    done
    CC=${stdenv.cc}/bin/cc ./bin/package make INIT SHELL=/bin/sh \
      CCFLAGS='-std=gnu89 -Wno-int-conversion -Wno-incompatible-pointer-types -D_lib_memccpy'
    hostArch=$(find arch -maxdepth 1 -type d -name 'darwin.*' | head -1)
    test -x "$hostArch/bin/mamake"
    # A native-architecture target executable can run on the build host, so
    # AST's execution probe misclassifies it as a host compiler. Force its
    # supported cross path for the second invocation.
    substituteInPlace bin/package --replace-fail 'CROSS=0' 'CROSS=1'
    targetArch=arch/macos.${toolchain.targetArch}-64-minidarwin
    mkdir -p "$targetArch/bin"
    # package bootstraps these before it notices that CC is a cross compiler.
    for t in mamake proto ratz release; do
      ln -s "$PWD/$hostArch/bin/$t" "$targetArch/bin/$t"
    done
    PATH="$PWD/$hostArch/bin:$PATH" ./bin/package make SHELL=/bin/sh \
      HOSTTYPE=macos.${toolchain.targetArch}-64-minidarwin \
      CC=${toolchain}/bin/cc \
      CCFLAGS='-std=gnu89 -Wno-int-conversion -Wno-incompatible-pointer-types -DSHOPT_SPAWN=0 -D_ast_int8_t=int64_t -D_lib_memccpy'
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    shell=$(find arch/macos.* -path '*/bin/ksh' -type f | head -1)
    test -n "$shell"
    install -Dm755 "$shell" $out/bin/ksh
    man=$(find arch/macos.* -path '*/man/man1/sh.1' -type f | head -1)
    test -n "$man"
    install -Dm644 "$man" $out/usr/share/man/man1/ksh.1
    md_verify_pure $out/bin/ksh
    md_verify_signed $out/bin/ksh
    runHook postInstall
  '';

  meta.description = "Apple's Korn shell";
}
