# Apple's bash.xcodeproj target and its four static library targets.
{ lib, mkDarwinPackage, sources, toolchain, bison, ncurses }:

let
  lists = import ./bash-sources.nix;
  # keymaps.c includes vi_keymap.c directly; compiling both duplicates its tables.
  cFiles = name: lib.filter (f: !(lib.hasSuffix ".y" f) && !(lib.hasSuffix "/vi_keymap.c" f)) lists.${name};
  allowUndefined =
    lib.genAttrs
      (map (s: "_${s}") [
        "endgrent"
        "endpwent"
        "getgrent"
        "getpwent"
        "getpwnam"
        "getpwuid"
        "setgrent"
        "setpwent"
      ])
      (_: "system_info") //
    lib.genAttrs
      (map (s: "_${s}") [
        "endservent"
        "getservent"
        "setservent"
        "freeaddrinfo"
        "gai_strerror"
        "getaddrinfo"
      ])
      (_: "system_info") // {
      "_environ" = "dyld";
      "_dlopen" = "dyld";
      "_dlclose" = "dyld";
      "_dlerror" = "dyld";
      "_dlsym" = "dyld";
    };
  defines = [
    "M_UNIX"
    "IN_LIBINTL"
    ''LIBDIR="/usr/libdata"''
    ''LOCALEDIR="/usr/share/locale"''
    ''LOCALE_ALIAS_PATH="/usr/share/locale"''
    ''PACKAGE="BASH"''
    "SSH_SOURCE_BASHRC"
    ''CONF_VENDOR="apple"''
    ''CONF_MACHTYPE="Mac"''
    ''CONF_HOSTTYPE="${if toolchain.targetArch == "aarch64" then "arm64" else "x86_64"}"''
    "MACOSX"
    "SHELL"
    "HAVE_CONFIG_H"
  ];
in
mkDarwinPackage {
  pname = "bash";
  version = lib.removePrefix "bash-" sources.bash.rev;
  src = sources.bash;
  inherit toolchain;
  nativeBuildInputs = [ bison ];
  passthru.allowUndefined = allowUndefined;
  postPatch = ''
    # The private System/ spelling is not in the public XNU SDK.
    substituteInPlace bash-3.2/shell.c \
      --replace-fail '<System/sys/codesign.h>' '<sys/codesign.h>'
  '';

  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    mkdir -p obj generated
    cat > generated/ostype.h <<'EOF'
    #ifndef __OSTYPE__
    #define __OSTYPE__
    #define OSTYPE "darwin25"
    #endif
    EOF
    bison -y -d -o generated/parse.c bash-3.2/parse.y
    cp generated/parse.h generated/y.tab.h
    ${lib.concatMapStringsSep "\n" (name: ''
      md_compile $PWD/obj/${name} "$CC" -std=gnu99 -Os -fcommon -Wno-deprecated-non-prototype \
        ${lib.escapeShellArgs (map (d: "-D${d}") defines)} \
        -I$PWD -I$PWD/generated -I$PWD/bash-3.2 \
        -I$PWD/bash-3.2/include -I$PWD/bash-3.2/builtins \
        -I$PWD/bash-3.2/lib -I$PWD/bash-3.2/lib/readline \
        -I$PWD/bash-3.2/lib/glob -I$PWD/bash-3.2/lib/intl \
        -I${ncurses.headers}/usr/include \
        -- ${lib.concatStringsSep " " (map (f: "$PWD/${f}") (cFiles name))}${lib.optionalString (name == "bash") " $PWD/generated/parse.c"}
    '') [ "bash" "libsh" "readline" "glob" "intl" ]}
    ${lib.concatMapStringsSep "\n" (name: "md_archive lib${name}.a obj/${name}") [ "libsh" "readline" "glob" "intl" ]}
    objs=()
    while IFS= read -r o; do objs+=( "$o" ); done < <(find obj/bash -name '*.o' | sort)
    "$CC" -Wl,-dead_strip -o bash "''${objs[@]}" \
      liblibsh.a libreadline.a libglob.a libintl.a \
      -L${ncurses}/usr/lib -lncurses \
      ${lib.escapeShellArgs (map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined))}
    md_verify_pure bash
    md_verify_signed bash
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 bash $out/bin/bash
    ln -s bash $out/bin/sh
    install -Dm644 bash-3.2/doc/bash.1 $out/usr/share/man/man1/bash.1
    ln -s bash.1 $out/usr/share/man/man1/sh.1
    install -Dm644 bashrc $out/private/etc/bashrc
    install -Dm644 profile $out/private/etc/profile
    runHook postInstall
  '';

  meta.description = "Apple's Bash shell";
}
