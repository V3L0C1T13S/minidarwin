# Apple's patched Perl 5.34.1. The release contains the upstream tarball and
# Apple's source edits; GNUmakefile's preparation target applies those edits.
{ lib, mkDarwinPackage, sources, toolchain, gnumake, perl, ed, python3 }:

let
  allowUndefined =
    lib.genAttrs
      (map (s: "_${s}") [
        "acos"
        "asin"
        "atan"
        "atan2"
        "cos"
        "cosh"
        "exp"
        "exp2"
        "fmod"
        "frexp"
        "ldexp"
        "log"
        "log10"
        "modf"
        "pow"
        "sin"
        "sinh"
        "tan"
        "tanh"
      ])
      (_: "system_m") //
    lib.genAttrs
      (map (s: "_${s}") [
        "getgrgid"
        "getgrnam"
        "getpwnam"
        "getpwuid"
      ])
      (_: "system_info");
in
mkDarwinPackage {
  pname = "perl";
  version = "5.34.1-apple-${lib.removePrefix "perl-" sources.perl.rev}";
  src = sources.perl;
  inherit toolchain;
  nativeBuildInputs = [ gnumake perl ed python3 ];
  passthru.allowUndefined = allowUndefined;

  configurePhase = ''
    runHook preConfigure
    mkdir -p prepared
    cp -R 5.34/. prepared/
    chmod -R u+w prepared
    substituteInPlace prepared/GNUmakefile \
      --replace-fail 'mv $(PROJVERS) $(PROJECT) && \' \
        'mv $(PROJVERS) $(PROJECT) && chmod -R u+w $(PROJECT) && \'
    make -C prepared -f GNUmakefile \
      SRCROOT="$PWD/prepared" OBJROOT="$PWD/prepared" RC_ARCHS=${toolchain.machoArch} \
      "$PWD/prepared/perl"
    # Apple's rootless integration needs private libsystem headers and the
    # closed sandbox library. Retain the other Apple and security fixes.
    patch -R -d prepared/perl -p1 < prepared/fix/perl-rootless-v2.patch
    patch -R -d prepared/perl -p1 < prepared/fix/perl-rootless-check-fd.patch
    cd prepared/perl
    sh Configure -des \
      -Dcc="$CC" -Dld="$CC" -Dar="$AR" -Dranlib="$RANLIB" -Dnm="$NM" \
      -Dprefix=/usr -Dinstallprefix=/usr \
      -Dbin=/usr/bin -Dscriptdir=/usr/bin \
      -Dprivlib=/usr/lib/perl5/5.34 -Darchlib=/usr/lib/perl5/5.34/darwin \
      -Dman1dir=/usr/share/man/man1 -Dman3dir=/usr/share/man/man3 \
      -Dccflags='-fno-common -DPERL_DARWIN -DOPEN_SOURCE -fno-strict-aliasing -Wno-compound-token-split-by-macro' \
      -Dldflags='${lib.concatStringsSep " " (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined))}' \
      -Dlibswanted=c_s \
      -Dlocincpth=' ' -Dloclibpth=' ' \
      -Dusrinc=${toolchain.sysroot}/usr/include \
      -Dnoextensions='Compress/Raw/Bzip2 Compress/Raw/Zlib DB_File NDBM_File Sys/Syslog' \
      -Uusedl -Uuseshrplib -Uuseithreads -Uusevendorprefix -Uusedtrace \
      -Dinstallusrbinperl=define
    # Configure's cross probes can leave these literal "undef" tokens in
    # config.h; absent byte layouts must be undefined preprocessor macros.
    sed -i \
      -e 's/^#define LONGDBLINFBYTES undef/#undef LONGDBLINFBYTES/' \
      -e 's/^#define LONGDBLNANBYTES undef/#undef LONGDBLNANBYTES/' \
      config.h
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j''${NIX_BUILD_CORES:-1} perl
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 perl $out/usr/bin/perl
    mkdir -p $out/usr/lib/perl5/5.34
    cp -R lib/. $out/usr/lib/perl5/5.34/
    # XS extensions are linked into the interpreter, not loaded from these
    # build-time archives. Keep their Perl wrappers and metadata.
    find $out/usr/lib/perl5/5.34 -name '*.a' -delete
    # Config is installed for scripts, so describe target paths rather than
    # embedding the build toolchain and SDK's Nix store paths in the rootfs.
    export MD_PERL_OUT="$out"
    python3 - <<'PY'
    from pathlib import Path
    import os, re

    root = Path(os.environ["MD_PERL_OUT"]) / "usr/lib/perl5/5.34"
    for name in ("Config.pm", "Config_heavy.pl", "Config.pod"):
        path = root / name
        contents = path.read_text()
        contents = contents.replace("${toolchain.sysroot}", "")
        contents = re.sub(r"/nix/store/[a-z0-9]{32}-[^/\s'\"]+", "/usr", contents)
        if "/nix/store/" in contents:
            raise RuntimeError(f"build path remains in {path}")
        path.write_text(contents)
    PY
    install -Dm644 ../../fix/perl.1 $out/usr/share/man/man1/perl.1
    md_verify_pure $out/usr/bin/perl
    md_verify_signed $out/usr/bin/perl
    runHook postInstall
  '';

  meta.description = "Apple's Perl 5.34 interpreter";
}
