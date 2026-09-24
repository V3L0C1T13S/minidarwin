# Stage 6: /usr/lib/libmd.dylib -- libmd.xcodeproj target `libmd` (Release),
# the MDXFile/SHA256_File/... helpers md5(1) and install(1) link. Every digest
# but SHA-0 (sha0c.c) is CommonCrypto's, through libmd's headers' #defines
# (MD5Init -> CC_MD5_Init); libcommonCrypto is absent, so those are declared
# below. The public headers go to passthru.headers, not the rootfs: the
# target installs them to the internal SDK's /usr/local/include.
# Its OpenSourceVersions/OpenSourceLicenses files are not installed.
{ lib
, mkDarwinPackage
, sources
, toolchain
, commonCryptoHeaders
, runCommand
}:

let
  builtPrefix = "$(BUILT_PRODUCTS_DIR)/";
  srcs = map
    (f: if lib.hasPrefix builtPrefix f then "BUILT_PRODUCTS_DIR/${lib.removePrefix builtPrefix f}" else f)
    (import ./libmd-sources.nix);

  cflags = [
    "-std=gnu11" # GCC_C_LANGUAGE_STANDARD
    "-Os"
    "-fno-common" # GCC_NO_COMMON_BLOCKS
  ];

  # The headers phase: every header is Public.
  headers = [ "libmd/md4.h" "libmd/md5.h" "libmd/sha.h" "include/sha224.h" "include/sha256.h" "include/sha384.h" "include/sha512.h" ];

  digests = [ "MD4" "MD5" "SHA1" "SHA224" "SHA256" "SHA384" "SHA512" ];

  # Imports nothing in the tree defines yet.
  allowUndefined =
    lib.genAttrs
      (lib.concatMap (d: map (f: "_CC_${d}_${f}") [ "Init" "Update" "Final" ]) digests)
      (_: "commonCrypto")
    // lib.genAttrs [
      # mdXhl.c's *FdChunk read through a dispatch_io channel.
      "__dispatch_data_empty"
      "_dispatch_data_apply"
      "_dispatch_io_create"
      "_dispatch_io_read"
      "_dispatch_queue_create"
      "_dispatch_release"
      "_dispatch_semaphore_create"
      "_dispatch_semaphore_signal"
      "_dispatch_semaphore_wait"
    ]
      (_: "dispatch");
in

mkDarwinPackage {
  pname = "libmd";
  version = lib.removePrefix "libmd-" sources.libmd.rev;

  src = sources.libmd;
  inherit toolchain;

  passthru.allowUndefined = allowUndefined; # for rootfs closure check
  passthru.installName = "/usr/lib/libmd.dylib";
  passthru.headers = runCommand "libmd-headers-${sources.libmd.rev}" { } ''
    for h in ${lib.escapeShellArgs headers}; do
      install -Dm644 ${sources.libmd}/$h $out/usr/include/$(basename $h)
    done
  '';

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    mkdir -p obj BUILT_PRODUCTS_DIR

    # The Generate Sources phase: one <digest>hl.c per digest from mdXhl.c.
    SRCROOT=$PWD BUILT_PRODUCTS_DIR=$PWD/BUILT_PRODUCTS_DIR \
      sh xcodescripts/generate_sources.sh

    md_compile $PWD/obj "$CC" ${lib.escapeShellArgs cflags} \
      -I$PWD/include -I$PWD/libmd \
      -I${commonCryptoHeaders}/usr/include \
      -- ${lib.concatMapStringsSep " " (f: "$PWD/${f}") srcs}

    MD_COMPAT_VERSION=1 MD_CURRENT_VERSION=1 \
      md_dylib libmd.dylib /usr/lib/libmd.dylib obj \
        ${lib.escapeShellArgs (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined))} \
        -lSystem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    f=$out/usr/lib/libmd.dylib
    install -Dm755 libmd.dylib $f

    md_verify_pure   $f
    md_verify_signed $f
    md_verify_symbols $f ${lib.escapeShellArgs (lib.concatMap (d: map (f: "_${d}${lib.optionalString (lib.hasPrefix "SHA" d) "_"}${f}") [ "Data" "End" "Fd" "FdChunk" "File" "FileChunk" ]) digests)} \
      _SHA_Init _SHA_Update _SHA_Final

    deps=$($OTOOL -L $f | tail -n +2 | awk '{ print $1 }' | grep -vx /usr/lib/libmd.dylib | sort -u)
    if [ "$deps" != /usr/lib/libSystem.B.dylib ]; then
      echo "libmd: links other than libSystem:" >&2
      echo "$deps" >&2
      exit 1
    fi

    # A declared hole the dylib no longer imports is stale.
    $NM -u $f | awk '{ print $NF }' | sort -u > imports
    for s in ${lib.escapeShellArgs (lib.attrNames allowUndefined)}; do
      grep -qx -- "$s" imports || {
        echo "libmd: declares $s absent but does not import it" >&2
        exit 1; }
    done

    runHook postInstall
  '';

  meta.description = "libmd.dylib (digest helpers over CommonCrypto), linked against minidarwin's libSystem";
}
