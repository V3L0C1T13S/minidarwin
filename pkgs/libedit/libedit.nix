# Stage 6: /usr/lib/libedit.3.dylib -- libedit.xcodeproj target `libedit`
# (Release, xcodescripts/libedit.xcconfig), linked against libncurses as the
# target's frameworks phase says. The `all` aggregate's install_misc.sh adds
# the compatibility symlinks and man pages, which are installed here too; its
# OpenSourceLicenses/Versions files are not. The `make lists` aggregate is not
# run: its outputs (local/) are checked in and listed as sources.
#
# /usr/include's share (install_misc.sh) is passthru.headers, for sh.
{ lib
, runCommand
, mkDarwinPackage
, sources
, toolchain
, ncurses
, publicSdkView
}:

let
  srcs = import ./libedit-sources.nix;

  cflags = [
    "-std=gnu99" # GCC_C_LANGUAGE_STANDARD
    "-Os"
    # The public SDK's view of xnu (see public-sdk-view.nix). Without it x86_64
    # breaks: <sys/ioctl.h> reaches <netinet/in.h> through sys/sockio_private.h
    # and its ntohl collides with <i386/endian.h>'s.
    "-include"
    "${publicSdkView}/include/minidarwin/public-sdk-view.h"
  ];

  # USER_HEADER_SEARCH_PATHS = src, plus what Xcode's header map resolves by
  # name: every header in the target's headers phase (config.h at the top,
  # local/*.h, src/*.h).
  includes = [ "." "src" "local" ];

  # DYLIB_COMPATIBILITY_VERSION / DYLIB_CURRENT_VERSION; PRODUCT_NAME edit.3.
  compat = "2";
  current = "3.0";
  dylib = "libedit.3.dylib";

  # Imports nothing in the tree defines yet: ~ and ~user expansion
  # (filecomplete.c), readline's home directory and username completion
  # (readline.c).
  allowUndefined = {
    "_endpwent" = "system_info";
    "_getpwent" = "system_info";
    "_getpwnam_r" = "system_info";
    "_getpwuid" = "system_info";
    "_getpwuid_r" = "system_info";
    "_setpwent" = "system_info";
  };

  # install_misc.sh
  links = [ "libedit.2.dylib" "libedit.3.0.dylib" "libedit.dylib" "libreadline.dylib" ];
  manLinks = [
    "el_deletestr"
    "el_end"
    "el_get"
    "el_getc"
    "el_gets"
    "el_history"
    "el_history_end"
    "el_history_init"
    "el_init"
    "el_insertstr"
    "el_line"
    "el_parse"
    "el_push"
    "el_reset"
    "el_resize"
    "el_set"
    "el_source"
    "el_tok_end"
    "el_tok_init"
    "el_tok_line"
    "el_tok_reset"
    "el_tok_str"
  ];

  installedHeaders = runCommand "libedit-headers-${sources.libedit.rev}" { } ''
    h=$out/usr/include
    mkdir -p $h/readline $h/editline
    install -m644 ${sources.libedit}/src/histedit.h $h/
    install -m644 ${sources.libedit}/src/editline/readline.h $h/editline/
    install -m644 ${sources.libedit}/src/editline.modulemap $h/
    for r in readline.h history.h; do
      ln -s ../editline/readline.h $h/readline/$r
    done
  '';
in

mkDarwinPackage {
  pname = "libedit";
  version = lib.removePrefix "libedit-" sources.libedit.rev;

  src = sources.libedit;
  inherit toolchain;

  passthru.allowUndefined = allowUndefined; # for rootfs closure check
  passthru.headers = installedHeaders;
  passthru.installName = "/usr/lib/${dylib}";

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    mkdir -p obj

    md_compile $PWD/obj "$CC" ${lib.escapeShellArgs cflags} \
      ${lib.concatMapStringsSep " " (i: "-iquote $PWD/${i}") includes} \
      -I${ncurses.headers}/usr/include \
      -- ${lib.concatMapStringsSep " " (f: "$PWD/${f}") srcs}

    MD_COMPAT_VERSION=${compat} MD_CURRENT_VERSION=${current} \
      md_dylib ${dylib} /usr/lib/${dylib} obj \
        -Wl,-dead_strip \
        -Wl,-unexported_symbols_list,$PWD/unexports \
        -L${ncurses}/usr/lib -lncurses \
        ${lib.escapeShellArgs (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined))} \
        -lSystem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 ${dylib} $out/usr/lib/${dylib}
    for l in ${lib.escapeShellArgs links}; do
      ln -s ${dylib} $out/usr/lib/$l
    done

    install -Dm644 doc/editrc.5 $out/usr/share/man/man5/editrc.5
    install -Dm644 doc/editline.3 $out/usr/share/man/man3/editline.3
    for m in ${lib.escapeShellArgs manLinks}; do
      ln -s editline.3 $out/usr/share/man/man3/$m.3
    done

    f=$out/usr/lib/${dylib}
    md_verify_pure   $f
    md_verify_signed $f

    deps=$($OTOOL -L $f | tail -n +2 | awk '{ print $1 }' | grep -vx /usr/lib/${dylib} | sort -u | tr '\n' ' ')
    if [ "$deps" != "/usr/lib/libSystem.B.dylib /usr/lib/libncurses.5.4.dylib " ]; then
      echo "libedit: links $deps, expected libSystem and libncurses" >&2
      exit 1
    fi

    # What sh (histedit.c, input.c) imports.
    md_verify_symbols $f \
      _el_init _el_end _el_gets _el_set _el_parse _el_source _el_resize \
      __el_fn_sh_complete _history _history_init _history_end
    # lld must have honoured unexports: none of its names may be exported.
    leaked=$($NM -gU $f | awk '{ print $NF }' | sort -u | comm -12 - <(sort -u unexports))
    if [ -n "$leaked" ]; then
      echo "libedit: exports what unexports hides:" >&2
      echo "$leaked" >&2
      exit 1
    fi

    runHook postInstall
  '';

  meta.description = "libedit.3.dylib, linked against minidarwin's libSystem and libncurses";
}
