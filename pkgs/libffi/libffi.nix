# Stage 6: /usr/lib/libffi.dylib and, on aarch64, /usr/lib/libffi-trampolines.dylib
# -- libffi.xcodeproj targets `libffi` and `libffi-trampolines` (Release), with
# the headers in /usr/include/ffi and the four man(3) pages.
#
# The source list names every architecture's files, as Xcode does; each is
# #if-guarded, so only the target's contribute code. Closures on arm64 use a
# trampoline table whose page template lives in the separate trampolines dylib
# (FFI_TRAMPOLINE_WHOLE_DYLIB, set by darwin/include/fficonfig_arm64.h), which
# closures.c dlopens, and dispatch_once guards. The x86_64 slice of Apple's
# libffi-trampolines.dylib is empty and closures there are static, so it is
# built for aarch64 only. `libffi-static` (libffi.a) is not installed by Apple.
# ffi.modulemap is not installed: the SDK assembles its own module maps.
{ lib
, mkDarwinPackage
, sources
, toolchain
, targetArch
}:

let
  version = lib.removePrefix "libffi-" sources.libffi.rev;
  isArm = targetArch == "aarch64";
  srcs = import ./libffi-sources.nix;

  cflags = [
    "-std=gnu99" # GCC_C_LANGUAGE_STANDARD
    "-Os"
    "-fno-common" # GCC_NO_COMMON_BLOCKS
    "-Idarwin/include"
    "-Iinclude"
    "-include"
    "${./compat/iosmac-availability.h}"
  ];

  # The library's own OTHER_LDFLAGS (the trampolines target has the same),
  # less -not_for_dyld_shared_cache and -no_compact_unwind, which lld ignores.
  ldflags = [ "-Wl,-allowable_client,!" ];

  # closures.c's trampoline-table setup, arm64 only. (dispatch_once is
  # libSystem's: libdispatch is a member of it.)
  allowUndefined = lib.optionalAttrs isArm {
    "_dlopen" = "dyld";
    "_dlsym" = "dyld";
  };
  holeFlags = map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined);

  publicHeaders = [
    "darwin/include/ffi.h"
    "darwin/include/ffitarget.h"
    "darwin/include/ffitarget_arm64.h"
    "darwin/include/ffitarget_armv7.h"
    "darwin/include/ffitarget_x86.h"
    "darwin/include/tramp.h"
  ];
in

mkDarwinPackage {
  pname = "libffi";
  inherit version;

  src = sources.libffi;
  inherit toolchain;

  passthru = {
    inherit allowUndefined; # for rootfs closure check
    installName = "/usr/lib/libffi.dylib";
  };

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    md_compile $PWD/obj/ffi "$CC" ${lib.escapeShellArgs cflags} \
      -- ${lib.concatMapStringsSep " " (f: "$PWD/${f}") srcs}

    MD_COMPAT_VERSION=1.0.0 MD_CURRENT_VERSION=${version}.0.0 \
      md_dylib libffi.dylib /usr/lib/libffi.dylib obj/ffi \
        ${lib.escapeShellArgs (ldflags ++ holeFlags)} -lSystem
  '' + lib.optionalString isArm ''

    md_compile $PWD/obj/tramp "$CC" ${lib.escapeShellArgs cflags} \
      -- $PWD/src/aarch64/trampoline.S
    MD_COMPAT_VERSION=1.0.0 MD_CURRENT_VERSION=${version}.0.0 \
      md_dylib libffi-trampolines.dylib /usr/lib/libffi-trampolines.dylib obj/tramp \
        ${lib.escapeShellArgs ldflags} -lSystem
  '' + ''

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libffi.dylib $out/usr/lib/libffi.dylib
    ${lib.optionalString isArm "install -Dm755 libffi-trampolines.dylib $out/usr/lib/libffi-trampolines.dylib"}

    for h in ${lib.escapeShellArgs publicHeaders}; do
      install -Dm644 $h $out/usr/include/ffi/$(basename $h)
    done
    for m in ffi ffi_call ffi_prep_cif ffi_prep_cif_var; do
      install -Dm644 man/$m.3 $out/usr/share/man/man3/$m.3
    done

    for f in $out/usr/lib/*.dylib; do
      md_verify_pure   $f
      md_verify_signed $f
      deps=$($OTOOL -L $f | tail -n +2 | awk '{ print $1 }' | grep -vx "/usr/lib/$(basename $f)" | sort -u || true)
      if [ "$deps" != /usr/lib/libSystem.B.dylib ]; then
        echo "libffi: $f links other than libSystem:" >&2
        echo "$deps" >&2
        exit 1
      fi
    done
    md_verify_symbols $out/usr/lib/libffi.dylib \
      _ffi_call _ffi_prep_cif _ffi_prep_cif_var _ffi_type_sint32 _ffi_type_pointer \
      _ffi_closure_alloc _ffi_closure_free _ffi_prep_closure_loc
    ${lib.optionalString isArm ''
      md_verify_symbols $out/usr/lib/libffi-trampolines.dylib _ffi_closure_trampoline_table_page
    ''}

    # A declared hole the dylib no longer imports is stale.
    $NM -u $out/usr/lib/libffi.dylib | awk '{ print $NF }' | sort -u > imports
    for s in ${lib.escapeShellArgs (lib.attrNames allowUndefined)}; do
      grep -qx -- "$s" imports || {
        echo "libffi: declares $s absent but does not import it" >&2
        exit 1; }
    done

    runHook postInstall
  '';

  meta.description = "libffi.dylib (and its trampolines dylib), linked against minidarwin's libSystem";
}
