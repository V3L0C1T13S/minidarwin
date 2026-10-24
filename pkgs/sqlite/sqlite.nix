# Upstream SQLite (Apple does not release its libsqlite3): libsqlite3.dylib,
# its headers, and the sqlite3 shell. Built from the amalgamation.
{ lib, mkDarwinPackage, sources, toolchain }:

let
  # Apple's libsqlite3 has these on; the rest is upstream's default.
  defines = [
    "SQLITE_THREADSAFE=2"
    "SQLITE_ENABLE_FTS3"
    "SQLITE_ENABLE_FTS3_PARENTHESIS"
    "SQLITE_ENABLE_FTS4"
    "SQLITE_ENABLE_FTS5"
    "SQLITE_ENABLE_RTREE"
    "SQLITE_ENABLE_COLUMN_METADATA"
    "SQLITE_ENABLE_DBSTAT_VTAB"
    "SQLITE_ENABLE_STAT4"
    "SQLITE_ENABLE_UNLOCK_NOTIFY"
    "SQLITE_ENABLE_MATH_FUNCTIONS"
    "SQLITE_ENABLE_SNAPSHOT"
    "SQLITE_ENABLE_BYTECODE_VTAB"
    "SQLITE_USE_URI=1"
    "SQLITE_DEFAULT_MEMSTATUS=0"
    "HAVE_USLEEP=1"
    "HAVE_LOCALTIME_R=1"
    "HAVE_GMTIME_R=1"
    "HAVE_STRCHRNUL=0"
    "HAVE_MALLOC_USABLE_SIZE=0"
  ];
  # libsystem_m and dyld are not built yet (libsystem/absent-members.nix).
  allowUndefined = lib.genAttrs
    (map (s: "_${s}") [
      "acos" "acosh" "asin" "asinh" "atan" "atan2" "atanh" "cos" "cosh" "exp"
      "fmod" "log" "log10" "log2" "pow" "sin" "sinh" "sqrt" "tan" "tanh" "trunc"
    ])
    (_: "system_m")
  // lib.genAttrs [ "_dlclose" "_dlerror" "_dlopen" "_dlsym" ] (_: "dyld")
  # The shell's find_home_dir, when HOME is unset.
  // { "_getpwuid" = "system_info"; };
  missingFlags = lib.escapeShellArgs (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined));
  defineFlags = map (d: "-D${d}") defines;
in
mkDarwinPackage {
  pname = "sqlite";
  version = "3.54.1";
  src = sources.sqlite;
  inherit toolchain;
  # The tarball ships an autosetup configure; preConfigure (build-support) is
  # all this phase is for.
  configurePhase = "runHook preConfigure; runHook postConfigure";
  passthru = {
    inherit allowUndefined;
    installName = "/usr/lib/libsqlite3.dylib";
  };

  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    cflags=(-std=gnu11 -O2 ${lib.escapeShellArgs defineFlags})
    md_compile "$PWD/obj/lib" "$CC" "''${cflags[@]}" -- "$PWD/sqlite3.c"
    MD_COMPAT_VERSION=9.0.0 MD_CURRENT_VERSION=9.6.0 \
      md_dylib libsqlite3.dylib /usr/lib/libsqlite3.dylib obj/lib \
        ${missingFlags} -lSystem

    mkdir -p bin
    md_compile "$PWD/obj/shell" "$CC" "''${cflags[@]}" -DSQLITE_OMIT_LOAD_EXTENSION=1 \
      -I"$PWD" -- "$PWD/shell.c"
    "$CC" ${missingFlags} -o bin/sqlite3 obj/shell/*.o libsqlite3.dylib -lSystem
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 libsqlite3.dylib "$out/usr/lib/libsqlite3.dylib"
    install -Dm755 bin/sqlite3 "$out/usr/bin/sqlite3"
    install -Dm644 sqlite3.h "$out/usr/include/sqlite3.h"
    install -Dm644 sqlite3ext.h "$out/usr/include/sqlite3ext.h"
    install -Dm644 sqlite3.1 "$out/usr/share/man/man1/sqlite3.1"
    for f in usr/lib/libsqlite3.dylib usr/bin/sqlite3; do
      md_verify_pure "$out/$f"
      md_verify_signed "$out/$f"
    done
    md_verify_symbols "$out/usr/lib/libsqlite3.dylib" \
      _sqlite3_open_v2 _sqlite3_prepare_v2 _sqlite3_step _sqlite3_finalize \
      _sqlite3_close _sqlite3_libversion
    runHook postInstall
  '';

  meta = {
    description = "SQLite library and shell (upstream release)";
    homepage = "https://sqlite.org/";
    license = lib.licenses.publicDomain;
  };
}
