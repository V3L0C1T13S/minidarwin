# Apple's libstdcxx-105.4 -- the GCC 4.2.1 libstdc++, target `libstdc++.dylib`
# of libstdcxx.xcodeproj (Release). macOS keeps it only for old binaries, and
# only as x86_64: arm64 never had it, so the aarch64 scope has no libstdcxx.
#
# It is not part of the macOS 26 source set and no new code links it, so it
# is retained in the OS X 10.8 compatibility tree (the last SDK Xcode 10
# links it from), install names rooted there as OpenSSL 0.9.8's are:
#   /compat/OS X/10.8/usr/lib/libstdc++.6.0.9.dylib
#   /compat/OS X/10.8/usr/lib/libstdc++.6.dylib -> libstdc++.6.0.9.dylib
#   /compat/OS X/10.8/usr/lib/libstdc++.dylib   -> libstdc++.6.dylib
# (the project's "add symlink" phase). The headers are not installed: the
# project does not install them either.
#
# This library holds only the C++ library proper. Exceptions, RTTI and
# operator new's ABI come from libc++abi, as the project's "Copy C++ ABI
# library headers" phase says it compiles against; unwinding from libSystem.
# libc++abi is reexported (the project's own LIB_iphonesimulator): the
# exports file names std::exception's members, which only it defines.
# /usr/lib/libgcc_s.1.dylib, which 10.8-era binaries also link, is already
# libSystem's compatibility symlink (Libsystem's create_dylib_symlinks.sh).
#
# Differences from Apple's build:
# - -force_symbols_weak_list/-force_symbols_not_weak_list are ld64's; lld has
#   neither. They change the weak-definition bit of exports (typeinfo and
#   vtables non-weak, the exception types weak), not the export set, which
#   libstdcxx-.exp fixes and the build checks.
# - Its OpenSourceVersions/OpenSourceLicenses files are not installed.
{ lib
, mkDarwinPackage
, sources
, toolchain
, libcxxabiDylib
, libcxxabi
}:

let
  src = sources.libstdcxx;
  compat = "/compat/OS X/10.8";
  installName = "${compat}/usr/lib/libstdc++.6.dylib";

  srcs = import ./libstdcxx-sources.nix;

  # The project's flags. Release has GCC_OPTIMIZATION_LEVEL at Xcode's
  # default, -Os, and no -fno-implicit-templates (that is Debug's). The
  # language is GCC 4.2's default; clang 21 would otherwise pick gnu++17.
  cflags = [
    "-std=gnu++98"
    "-Os"
    "-fno-common"
    "-nostdinc++"
    "-DBUILDING_LIBSTDCXX"
    "-I$PWD/include/c++/4.2.1"
    "-I$PWD/include/c++/4.2.1/backward"
    "-I$PWD/abi-headers"
    # HEADER_SEARCH_PATHS also finds the sources' own "*.h" by name.
    "-iquote"
    "$PWD/src"
  ];
in

mkDarwinPackage {
  pname = "libstdcxx";
  version = lib.removePrefix "libstdcxx-" src.rev;
  inherit src toolchain;

  passthru.allowUndefined = { }; # for rootfs closure check
  passthru.installName = installName;

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD

    # "Copy C++ ABI library headers": just cxxabi.h and its config, so
    # that libc++'s whole <v1> is not on the search path.
    mkdir -p abi-headers
    cp ${libcxxabi}/usr/include/c++/v1/cxxabi.h \
       ${libcxxabi}/usr/include/c++/v1/__cxxabi_config.h abi-headers/

    md_compile $PWD/obj "$CXX" ${lib.concatMapStringsSep " " (f: ''"${f}"'') cflags} \
      -- ${lib.concatMapStringsSep " " (f: "$PWD/${f}") (lib.filter (f: f != "src/concept-inst.cc") srcs)}
    # The one file with its own flags in the project.
    md_compile $PWD/obj "$CXX" ${lib.concatMapStringsSep " " (f: ''"${f}"'') cflags} \
      -D_GLIBCXX_CONCEPT_CHECKS -- $PWD/src/concept-inst.cc

    # DYLIB_COMPATIBILITY_VERSION = 7; DYLIB_CURRENT_VERSION is the
    # project's source version. OTHER_LDFLAGS: -nostdlib ... -lSystem.
    MD_COMPAT_VERSION=7 MD_CURRENT_VERSION=${lib.removePrefix "libstdcxx-" src.rev}.0 \
      md_dylib libstdc++.6.0.9.dylib '${installName}' obj \
        -nostdlib \
        -Wl,-exported_symbols_list,exports/libstdcxx-.exp \
        -L${libcxxabiDylib}/usr/lib -Wl,-reexport-lc++abi \
        -lSystem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    lib="$out${compat}/usr/lib"
    install -Dm755 libstdc++.6.0.9.dylib "$lib/libstdc++.6.0.9.dylib"
    ln -s libstdc++.6.0.9.dylib "$lib/libstdc++.6.dylib"
    ln -s libstdc++.6.dylib "$lib/libstdc++.dylib"

    f="$lib/libstdc++.6.0.9.dylib"
    md_verify_pure "$f"
    md_verify_signed "$f"

    # The exports file is a filter, not a contract this source set meets:
    # eh_exception.cc leaves std::exception's and bad_exception's members
    # to libc++abi (_LIBCPPABI_VERSION), so the file names symbols that
    # only the libc++abi reexport supplies. Nothing outside it may be
    # exported; everything it names that is not defined here must be.
    grep -v -e '^#' -e '^$' exports/libstdcxx-.exp | sort -u > want
    $NM --defined-only --extern-only "$f" | awk '{ print $NF }' | sort -u > have
    $NM --defined-only --extern-only ${libcxxabiDylib}/usr/lib/libc++abi.dylib \
      | awk '{ print $NF }' | sort -u > abi
    comm -13 want have > extra
    comm -23 want have | comm -23 - abi > lost
    if [ -s extra ] || [ -s lost ]; then
      echo "libstdc++: exports do not match exports/libstdcxx-.exp" >&2
      echo "exported but not listed:" >&2; head -40 extra >&2
      echo "listed, defined by neither libstdc++ nor libc++abi:" >&2; head -40 lost >&2
      exit 1
    fi
    md_log "libstdc++: $(wc -l < have) exports, $(comm -23 want have | wc -l) from libc++abi"

    # Load commands: libSystem, and libc++abi (reexported).
    deps=$($OTOOL -L "$f" | tail -n +2 | sed -E 's/^[[:space:]]*//; s/[[:space:]]+\(compatibility version.*$//' | grep -vxF -e '${installName}' | sort | tr '\n' ' ')
    if [ "$deps" != "/usr/lib/libSystem.B.dylib /usr/lib/libc++abi.dylib " ]; then
      echo "libstdc++: unexpected load commands: $deps" >&2
      exit 1
    fi

    md_verify_reexports "$f" /usr/lib/libc++abi.dylib
    md_verify_symbols "$f" \
      __ZNSt8ios_base4InitC1Ev __ZSt4cout __ZNSs4_Rep20_S_empty_rep_storageE \
      __ZNSt6locale5facet15_S_get_c_localeEv

    runHook postInstall
  '';

  meta.description = "Apple's GCC 4.2.1 libstdc++ (x86_64), in the OS X 10.8 compatibility tree";
}
