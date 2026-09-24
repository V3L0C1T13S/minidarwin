# Stage 6: text_cmds targets (see ../cmds/mk-cmds.nix).
# Not reproduced: apple-generic versioning's generated <tool>_vers.c, as for
# shell_cmds; the targets' test files (/AppleInternal/Tests). The
# `executables` aggregate's variant links (grep, md5, bintrans) are made, as
# symlinks.
#
# Not built: wc, written against libxo (<libxo/xo.h>), which Apple has not
# released; jq and its onigurama archive (not a POSIX tool, and a project of
# its own); test_base64 (libdarwintest).
{ lib
, mkCmds
, sources
, toolchain
, libutil
, ncurses
, libmd
, commonCryptoHeaders
}:

let
  # xcconfigs/base.xcconfig, which grep's and sort's xcconfigs include: its
  # warnings, as Xcode passes them, and GCC_TREAT_WARNINGS_AS_ERRORS.
  baseWarnings = [
    "-Werror"
    "-Wassign-enum" # CLANG_WARN_ASSIGN_ENUM
    "-Wbool-conversion"
    "-Wconstant-conversion"
    "-Wdocumentation" # CLANG_WARN_DOCUMENTATION_COMMENTS
    "-Wempty-body"
    "-Wenum-conversion"
    "-Wint-conversion"
    "-Wnullable-to-nonnull-conversion"
    "-Wunreachable-code"
    "-Werror=implicit-function-declaration"
    "-Werror=incompatible-pointer-types"
    "-Wmissing-field-initializers"
    "-Wnewline-eof" # GCC_WARN_ABOUT_MISSING_NEWLINE
    "-Wmissing-prototypes"
    "-Werror=return-type" # GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR
    "-Wswitch" # GCC_WARN_CHECK_SWITCH_STATEMENTS
    "-Wfour-char-constants"
    "-Wmissing-braces" # GCC_WARN_INITIALIZER_NOT_FULLY_BRACKETED
    "-Wparentheses"
    "-Wformat" # GCC_WARN_TYPECHECK_CALLS_TO_PRINTF
    "-Wunknown-pragmas"
    "-Wunused-function"
    "-Wunused-label"
    "-Wunused-parameter"
    "-Wunused-value"
    "-Wunused-variable"
  ];

  grepVariants = [ "e" "f" "z" "ze" "zf" "bz" "bze" "bzf" ]; # grep_variant_links.sh
  md5Variants = [ "md5sum" "sha1" "sha1sum" "sha224" "sha224sum" "sha256" "sha256sum" "sha384" "sha384sum" "sha512" "sha512sum" ]; # md5_variant_links.sh

  # Per target, what differs from the project's Release settings; the
  # attributes are described in mk-cmds.nix.
  tools = {
    banner = {
      man = { "banner/banner.6" = "/usr/share/man/man6/banner.6"; };
    };
    bintrans = {
      man = lib.listToAttrs (map
        (m: lib.nameValuePair "bintrans/${m}.1" "/usr/share/man/man1/${m}.1")
        [ "b64decode" "b64encode" "base64" "bintrans" "uudecode" "uuencode" ]);
      # The executables aggregate's hardlink.sh.
      links = lib.genAttrs
        (map (n: "/usr/bin/${n}") [ "base64" "uudecode" "uuencode" "b64decode" "b64encode" ])
        (_: "/usr/bin/bintrans");
      allowUndefined."_getpwnam" = "system_info"; # uuencode's ~user in the header
    };
    cat = {
      installDir = "/bin";
      # A file operand that is a socket is connected to and read from.
      allowUndefined = {
        "_freeaddrinfo" = "system_info";
        "_gai_strerror" = "system_info";
        "_getaddrinfo" = "system_info";
      };
    };
    col = { };
    colrm = { };
    column = { };
    comm = { };
    csplit = { };
    cut = { };
    ed = {
      installDir = "/bin";
      man = {
        "ed/ed.1" = "/usr/share/man/man1/ed.1";
        "ed/red.1" = "/usr/share/man/man1/red.1";
      };
    };
    expand = {
      links."/usr/share/man/man1/unexpand.1" = "/usr/share/man/man1/expand.1"; # link-man-pages.sh
    };
    fmt = { };
    fold = { };
    grep = {
      # xcconfigs/grep.xcconfig. OTHER_LDFLAGS (-lbz2 -llzma -lz) is not
      # passed: see postPatch.
      cflags = baseWarnings ++ [
        "-Wconversion" # CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION
        # -Wconversion includes these two; Xcode passes -Wno- for a NO.
        "-Wno-sign-conversion" # CLANG_WARN_IMPLICIT_SIGN_CONVERSION = NO
        "-Wno-shorten-64-to-32" # GCC_WARN_64_TO_32_BIT_CONVERSION = NO
        "-Wconditional-uninitialized" # GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE
        "-Wpointer-sign" # GCC_WARN_ABOUT_POINTER_SIGNEDNESS
      ];
      links = lib.listToAttrs (lib.concatMap
        (v: [
          (lib.nameValuePair "/usr/bin/${v}grep" "/usr/bin/grep")
          (lib.nameValuePair "/usr/share/man/man1/${v}grep.1" "/usr/share/man/man1/grep.1")
        ])
        grepVariants);
    };
    head = { };
    join = { };
    lam = {
      # The target owns the tests folder (for lam_test.sh's copy phase), so
      # the generated list picks up the one C file in it: sort's darwintest,
      # which Apple's lam does not contain.
      notCompiled."tests/sort_vers.c" = "a sort test (libdarwintest)";
    };
    look = { };
    md5 = {
      installDir = "/sbin";
      # OTHER_LDFLAGS: -lmd; -lCrashReporterClient ([sdk=macosx*]) is a static
      # archive that was never released, and md5 calls nothing in it.
      libraries = [{ pkg = libmd; l = "md"; }];
      cflags = [ "-I${commonCryptoHeaders}/usr/include" ]; # libmd's headers include it
      # MD5Init, SHA256_Update, ... are libmd's #defines for CommonCrypto's
      # (see libmd.nix); the digest is finished by libmd's *End.
      allowUndefined = lib.genAttrs
        (lib.concatMap (d: [ "_CC_${d}_Init" "_CC_${d}_Update" ])
          [ "MD5" "SHA1" "SHA224" "SHA256" "SHA384" "SHA512" ])
        (_: "commonCrypto");
      links = lib.listToAttrs (lib.concatMap
        (v: [
          (lib.nameValuePair "/sbin/${v}" "/sbin/md5")
          (lib.nameValuePair "/usr/share/man/man1/${v}.1" "/usr/share/man/man1/md5.1")
        ])
        md5Variants);
    };
    nl = { };
    paste = { };
    pr = { };
    rev = { };
    rs = { };
    sed = { };
    sort = {
      # xcconfigs/sort.xcconfig: its definitions replace the project's.
      defines = [ ''SORT_VERSION="${lib.removePrefix "text_cmds-" sources.text_cmds.rev}"'' "WITHOUT_NLS" "SORT_THREADS" ];
      cflags = baseWarnings ++ [
        "-Wno-deprecated-declarations" # GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS = NO
        "-Wno-pointer-sign" # GCC_WARN_ABOUT_POINTER_SIGNEDNESS = NO
        "-Wuninitialized" # GCC_WARN_UNINITIALIZED_AUTOS = YES
        "-Wshadow" # GCC_WARN_SHADOW
        "-Wsign-compare" # GCC_WARN_SIGN_COMPARE
        "-I${commonCryptoHeaders}/usr/include"
      ];
      man = { }; # install-sort-man.sh, in extraInstall
      # -R orders by a salted SHA-256 of each key (commoncrypto.h).
      allowUndefined = {
        "_CC_SHA256_Final" = "commonCrypto";
        "_CC_SHA256_Init" = "commonCrypto";
        "_CC_SHA256_Update" = "commonCrypto";
      };
    };
    split = { libraries = [{ pkg = libutil; l = "util"; }]; }; # frameworks phase: libutil.tbd
    tail = { libraries = [{ pkg = libutil; l = "util"; }]; };
    tr = { };
    # Frameworks phase: libcurses.dylib (termcap), libncurses' symlink.
    ul = { libraries = [{ pkg = ncurses; l = "curses"; }]; };
    unexpand = { man = { }; }; # expand's page, linked
    uniq = { };
    # The frameworks phase names libxo.tbd, but unvis calls nothing in it.
    unvis = { };
    vis = { };
  };
in

mkCmds {
  pname = "text_cmds";
  src = sources.text_cmds;
  inherit toolchain tools;
  sourceLists = import ./text-cmds-sources.nix;

  # Project-level Release settings (text_cmds.xcodeproj).
  cflags = [
    "-std=gnu99" # GCC_C_LANGUAGE_STANDARD
    "-Os" # GCC_OPTIMIZATION_LEVEL (Release default)
    "-fno-common" # GCC_NO_COMMON_BLOCKS
    "-Werror=format-nonliteral"
    "-Werror=format" # WARNING_CFLAGS
  ];
  defines = [ "__FBSDID=__RCSID" ]; # GCC_PREPROCESSOR_DEFINITIONS
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING

  # grep reads gzip, bzip2, xz and lzma input through zlib, libbz2 and
  # liblzma. liblzma was never released, and zlib and bzip2 are not built
  # here, so grep is compiled without that: each #ifdef __APPLE__ block in
  # file.c that touches them is turned off, and grep.h stops including their
  # headers. The -Z/-J/-M/--xz options and the z*/bz* variants are still
  # accepted, and read the file as it is.
  postPatch = ''
    substituteInPlace grep/grep.h \
      --replace-fail '#include <bzlib.h>' "" \
      --replace-fail '#include <zlib.h>' ""
    awk '
      /^#ifdef __APPLE__$/ {
        a = $0; getline b; getline c
        if ((b c) ~ /zlib|gzFile|BZ2_bzRead|FILE_GZIP/) { a = "#if 0 /* minidarwin: no zlib, libbz2 or liblzma */"; n++ }
        print a; print b; print c; next
      }
      { print }
      END { if (n != 5) { print "grep/file.c: expected 5 compression blocks, found " n > "/dev/stderr"; exit 1 } }
    ' grep/file.c > grep/file.c.new
    mv grep/file.c.new grep/file.c
  '';

  # install-sort-man.sh.
  extraInstall = ''
    sed -e 's|^%%THREADS%%||' -e 's|^%%NLS%%|\.\\"|' < sort/sort.1.in > sort.1
    install -Dm644 sort.1 $out/usr/share/man/man1/sort.1
  '';
}
