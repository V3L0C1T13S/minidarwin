# Stage 6: /usr/lib/libutil.dylib -- libutil.xcodeproj target `util`
# (Release, xcconfigs/lib.xcconfig), what ls links for humanize_number.
# Installed as the target's phases install it: the dylib, the libutil1.0.dylib
# symlink its script phase makes, and its man pages in /usr/local/share/man.
# Its OpenSourceVersions/OpenSourceLicenses files are not.
#
# Three of the target's sources cannot be compiled from released headers, so
# they are left out with the symbols only they define (`absent` below). The
# headers libutil installs are already in the SDK (sdk-headers.nix).
{ lib
, mkDarwinPackage
, sources
, toolchain
}:

let
  listed = import ./libutil-sources.nix;

  # Sources not compiled, with the reason, and the exports only they define.
  # libutil.exports is filtered by the second list; both must match the
  # project, or the build fails.
  absent = {
    # <xpc/xpc.h>: libxpc is closed source, and so is the header.
    "tzlink.c" = { reason = "xpc"; exports = [ "_tzlink" ]; };
    # <IOKit/storage/IOStorage.h>, which neither the SDK nor any pinned
    # project provides.
    "wipefs.cpp" = {
      reason = "IOKit";
      exports = [ "_wipefs_alloc" "_wipefs_except_blocks" "_wipefs_free" "_wipefs_include_blocks" "_wipefs_wipe" ];
    };
    "ExtentManager.cpp" = { reason = "IOKit (wipefs.cpp's helper)"; exports = [ ]; };
  };
  srcs = lib.filter (f: !(absent ? ${f})) listed;
  absentExports = lib.concatMap (a: a.exports) (lib.attrValues absent);

  cflags = [
    "-Os"
    "-fno-common" # GCC_NO_COMMON_BLOCKS
    "-Wall" # WARNING_CFLAGS
  ];

  # Imports nothing in the tree defines yet.
  allowUndefined = {
    # reexec_to_match_kernel.c
    "__NSGetExecutablePath" = "dyld";
    # realhostname.c
    "_freeaddrinfo" = "system_info";
    "_getaddrinfo" = "system_info";
    "_gethostbyaddr" = "system_info";
    "_gethostbyname" = "system_info";
    "_getnameinfo" = "system_info";
  };

  # BA79F9DB13BB7698006A292D, less wipefs.3.
  man = [
    "expand_number.3"
    "getmntopts.3"
    "humanize_number.3"
    "pidfile.3"
    "realhostname_sa.3"
    "realhostname.3"
    "reexec_to_match_kernel.3"
    "trimdomain.3"
  ];
in

assert lib.assertMsg (lib.all (f: lib.elem f listed) (lib.attrNames absent))
  "libutil: absent names a file the util target does not compile";

mkDarwinPackage {
  pname = "libutil";
  version = lib.removePrefix "libutil-" sources.libutil.rev;

  src = sources.libutil;
  inherit toolchain;

  passthru.allowUndefined = allowUndefined; # for rootfs closure check
  passthru.installName = "/usr/lib/libutil.dylib";

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    mkdir -p obj

    # EXPORTED_SYMBOLS_FILE, less what the absent sources define.
    printf '%s\n' ${lib.escapeShellArgs absentExports} | sort > absent.exports
    missing=$(comm -23 absent.exports <(sort libutil.exports))
    if [ -n "$missing" ]; then
      echo "libutil: libutil.exports no longer lists: $missing" >&2
      exit 1
    fi
    sort libutil.exports | comm -23 - absent.exports > exports

    md_compile $PWD/obj "$CC" ${lib.escapeShellArgs cflags} \
      -I$PWD \
      -- ${lib.concatMapStringsSep " " (f: "$PWD/${f}") srcs}

    # Apple's libutil.dylib imports nothing tzbootuuid.c calls (copyfile,
    # removefile): none of it is exported and tzlink.c does not use it, so the
    # link dead-strips it. (tzlinkd, the daemon, is its user.)
    MD_COMPAT_VERSION=1.0 MD_CURRENT_VERSION=1.0 \
      md_dylib libutil.dylib /usr/lib/libutil.dylib obj \
        -Wl,-dead_strip \
        -Wl,-exported_symbols_list,$PWD/exports \
        ${lib.escapeShellArgs (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined))} \
        -lSystem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    f=$out/usr/lib/libutil.dylib
    install -Dm755 libutil.dylib $f
    ln -s libutil.dylib $out/usr/lib/libutil1.0.dylib
    for m in ${lib.escapeShellArgs man}; do
      install -Dm644 $m $out/usr/local/share/man/man3/$m
    done

    md_verify_pure   $f
    md_verify_signed $f

    deps=$($OTOOL -L $f | tail -n +2 | awk '{ print $1 }' | grep -vx /usr/lib/libutil.dylib | sort -u)
    if [ "$deps" != /usr/lib/libSystem.B.dylib ]; then
      echo "libutil: links other than libSystem:" >&2
      echo "$deps" >&2
      exit 1
    fi

    # Exactly the filtered exports list.
    $NM -gU $f | awk '{ print $NF }' | sort -u > exported
    if ! cmp -s exported exports; then
      echo "libutil: exports differ from libutil.exports (less absent):" >&2
      diff exports exported >&2 || true
      exit 1
    fi

    # A declared hole the dylib no longer imports is stale.
    $NM -u $f | awk '{ print $NF }' | sort -u > imports
    for s in ${lib.escapeShellArgs (lib.attrNames allowUndefined)}; do
      grep -qx -- "$s" imports || {
        echo "libutil: declares $s absent but does not import it" >&2
        exit 1; }
    done

    runHook postInstall
  '';

  meta.description = "libutil.dylib (less tzlink and wipefs), linked against minidarwin's libSystem";
}
