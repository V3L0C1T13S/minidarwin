# Apple's zsh-5.9 release, configured for a target that cannot run at build time.
{ lib, mkDarwinPackage, sources, toolchain, ncurses, gnumake, perl }:

let
  allowUndefined = {
    "_environ" = "dyld";
    "_pow" = "system_m";
    "_fmod" = "system_m";
    "_getgrgid" = "system_info";
  };
in
mkDarwinPackage {
  pname = "zsh";
  version = lib.removePrefix "zsh-" sources.zsh.rev;
  src = sources.zsh;
  inherit toolchain;
  nativeBuildInputs = [ gnumake perl ];
  passthru.allowUndefined = allowUndefined;
  postPatch = ''
    substituteInPlace zsh/Src/init.c \
      --replace-fail '<System/sys/codesign.h>' '<sys/codesign.h>'
    # ZLE's poll path uses cost too; on x86_64 configure may find poll but
    # not select, leaving cost undefined unless both conditions match.
    substituteInPlace zsh/Src/Zle/zle_refresh.c \
      --replace-fail '#ifdef HAVE_SELECT' '#if defined(HAVE_SELECT) || defined(HAVE_POLL)'
  '';

  configurePhase = ''
    runHook preConfigure
    cd zsh
    # The cross cache is supplied by Apple for builds which cannot run zsh.
    cp ../configure.cache-embedded config.cache
    export CPPFLAGS="-DUSE_GETCWD -I${ncurses.headers}/usr/include"
    export LDFLAGS="-L${ncurses}/usr/lib ${lib.concatStringsSep " " (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined))}"
    ./configure \
      --build=x86_64-unknown-linux-gnu \
      --host=${toolchain.targetArch}-apple-darwin \
      --prefix=/usr --bindir=/bin --mandir=/usr/share/man \
      --with-tcsetpgrp --enable-multibyte --enable-unicode9 \
      --enable-max-function-depth=700 --disable-dynamic \
      --with-term-lib=ncurses --cache-file=config.cache
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j''${NIX_BUILD_CORES:-1}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make install DESTDIR=$out
    # Apple's post-install keeps only /bin/zsh (the versioned hardlink is removed).
    rm -f $out/bin/zsh-5.9
    install -Dm644 ../zprofile $out/private/etc/zprofile
    install -Dm644 ../zshrc $out/private/etc/zshrc
    md_verify_pure $out/bin/zsh
    md_verify_signed $out/bin/zsh
    runHook postInstall
  '';

  meta.description = "Apple's Z shell";
}
