# file.xcodeproj's file target and its magic database source fragments.
{ lib
, mkDarwinPackage
, buildSupport
, sources
, toolchain
}:

let
  srcs = import ./file-sources.nix;
in
mkDarwinPackage {
  pname = "file";
  version = lib.removePrefix "file-" sources.file.rev;
  src = sources.file;
  inherit toolchain;
  dontConfigure = true;

  # The checked-in config.h assumes Apple's libz, libbz2 and liblzma.
  # None is in our rootfs yet; leave external decompression available.
  postPatch = ''
    sed -i.bak \
      -e '/^#define ZLIBSUPPORT /d' \
      -e '/^#define BZLIBSUPPORT /d' \
      -e '/^#define XZLIBSUPPORT /d' \
      config.h

    # file-106 calls a newer libmacho API not yet exported by our
    # libmacho. The older API gives the same architecture name here.
    substituteInPlace file/src/readmacho.c \
      --replace-fail \
      'const char *arch_name = macho_arch_name_for_cpu_type(cputype, cpusubtype);' \
      'const NXArchInfo *arch_info = NXGetArchInfoFromCpuType(cputype, cpusubtype);
    const char *arch_name = arch_info == NULL ? NULL : arch_info->name;'
  '';

  buildPhase = ''
    runHook preBuild
    source ${buildSupport}
    export MD_SRCROOT=$PWD
    mkdir -p obj
    md_compile $PWD/obj "$CC" -Os -fno-common \
      -DHAVE_CONFIG_H -DBUILTIN_MACHO '-DMAGIC="/usr/share/file/magic"' \
      -I$PWD -I$PWD/file/src \
      -- ${lib.concatMapStringsSep " " (f: "$PWD/${f}") srcs}
    "$CC" -Wl,-dead_strip -o file-bin obj/*.o
    md_verify_pure file-bin
    md_verify_signed file-bin
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 file-bin $out/usr/bin/file
    mkdir -p $out/usr/share/file/magic
    cp file/magic/Magdir/* $out/usr/share/file/magic/
    # xcodescripts/man-pages.sh substitutions.
    for name in file magic; do
      section=1
      [ "$name" = magic ] && section=5
      mkdir -p $out/usr/share/man/man$section
      sed -e 's@__CSECTION__@1@g' \
          -e 's@__FSECTION__@5@g' \
          -e 's@__VERSION__@5.41@g' \
          -e 's@__MAGIC__@/usr/share/file/magic@g' \
          file/doc/$name.man > $out/usr/share/man/man$section/$name.$section
    done
    runHook postInstall
  '';

  meta.description = "Apple's file(1) and magic rules";
}
