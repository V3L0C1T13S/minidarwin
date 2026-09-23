# Stage 6: the first userland -- shell_cmds targets.
# Built as shell_cmds.xcodeproj builds each target (Release): one tool per
# target, linked against libSystem plus whatever the target's OTHER_LDFLAGS
# name, man pages as the target installs them.
# Not reproduced: apple-generic versioning's generated <tool>_vers.c (the
# __<tool>VersionString symbol), which nothing references; and the "All"
# aggregate's install-files.sh, which hardlinks id to groups and whoami.
{ lib
, mkDarwinPackage
, sources
, toolchain
, shGenerated
, libedit
, bison
}:

let
  sourceLists = import ./shell-cmds-sources.nix;

  # Per target, what differs from the project's Release settings:
  #   installDir  INSTALL_PATH (project default /usr/bin)
  #   product     PRODUCT_NAME, when it is not the target name
  #   defines     GCC_PREPROCESSOR_DEFINITIONS -- a target setting replaces
  #               the project's __FBSDID=__RCSID, it does not add to it
  #   includes    USER_HEADER_SEARCH_PATHS, relative to the build directory
  #   libraries   built dylibs this target links (OTHER_LDFLAGS), each with
  #               passthru.headers, passthru.installName and a -l name
  #   cflags      other compiler settings that change the result or can fail it
  #   man         { <file in the tarball> = <installed path>; }
  #   allowUndefined  imports nothing in the tree defines yet, with the reason
  tools = {
    echo = { installDir = "/bin"; };
    false = { };
    find = {
      defines = [ "__FBSDID=__RCSID" "_DARWIN_USE_64_BIT_INODE" ];
      allowUndefined = {
        # -exec's execvp inherits it. Defined by libdyld (libdyldGlue.cpp),
        # which also carries the executable's NXArgv and __progname.
        "_environ" = "dyld";
        # -user, -group, -nouser, -nogroup, -ls.
        "_getgrnam" = "system_info";
        "_getpwnam" = "system_info";
        "_group_from_gid" = "system_info";
        "_user_from_uid" = "system_info";
      };
    };
    hostname = { installDir = "/bin"; };
    id = {
      defines = [ "__FBSDID=__RCSID" "USE_BSM_AUDIT" ];
      man = {
        "id/groups.1" = "/usr/share/man/man1/groups.1";
        "id/id.1" = "/usr/share/man/man1/id.1";
        "id/whoami.1" = "/usr/share/man/man1/whoami.1";
      };
      allowUndefined = {
        "_getgrgid" = "system_info";
        "_getgrouplist_2" = "system_info";
        "_getpwnam" = "system_info";
        "_getpwuid" = "system_info";
      };
    };
    pwd = { installDir = "/bin"; };
    realpath = { installDir = "/bin"; };
    # xcconfigs/sh.xcconfig: installed as ash (its TODO is to become /bin/sh).
    sh = {
      installDir = "/usr/local/bin";
      product = "ash";
      defines = [ "SHELL" ];
      includes = [ "BUILT_PRODUCTS_DIR" "sh" ];
      libraries = [{ pkg = libedit; l = "edit"; }]; # OTHER_LDFLAGS = -ledit
      cflags = [
        "-Werror=incompatible-pointer-types" # GCC_TREAT_INCOMPATIBLE_POINTER_TYPE_WARNINGS_AS_ERRORS
        "-Werror=return-type" # GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR
      ];
      builtProducts = shGenerated;
      man = { "sh/sh.1" = "/usr/local/share/man/man1/ash.1"; };
      allowUndefined = {
        "_environ" = "dyld"; # see find
        "_getpwnam" = "system_info"; # ~user expansion
      };
    };
    true = { };
    uname = { };
    who = {
      defines = [ "__FBSDID=__RCSID" "_UTMPX_COMPAT" "SUPPORT_UTMPX" ];
      # Libc's utmpx is not in libsystem_c: utmpx-darwin.c (which utmpx.c
      # cannot do without) is written against <asl.h>. See libsystem-c.nix.
      allowUndefined = {
        "_endutxent" = "system_asl";
        "_getutxent" = "system_asl";
        "_getutxline" = "system_asl";
        "_utmpxname" = "system_asl";
        "_wtmpxname" = "system_asl";
        # whoami(), when the tty is not in utmpx.
        "_getpwuid" = "system_info";
      };
    };
    yes = { };
  };

  # Every tool built must have a generated source list, and vice versa.
  checkedTools =
    assert lib.assertMsg (lib.attrNames tools == lib.attrNames sourceLists)
      "shell_cmds: tools (${toString (lib.attrNames tools)}) and shell-cmds-sources.nix (${toString (lib.attrNames sourceLists)}) disagree";
    tools;

  product = name: t: t.product or name;
  installPath = name: t: "${t.installDir or "/usr/bin"}/${product name t}";

  # Project-level Release settings (shell_cmds.xcodeproj).
  cflags = [
    "-std=gnu99" # GCC_C_LANGUAGE_STANDARD
    "-Os" # GCC_OPTIMIZATION_LEVEL (Release default)
    "-fno-common" # GCC_NO_COMMON_BLOCKS
    "-Wall"
    "-Werror=format-nonliteral" # WARNING_CFLAGS
    "-Werror=implicit-function-declaration" # GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS
  ];
  defines = [ "__FBSDID=__RCSID" ]; # GCC_PREPROCESSOR_DEFINITIONS
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING

  # Where each listed source is compiled from. A BUILT_PRODUCTS_DIR file is the
  # copy buildTool puts there; a .y is compiled from its yacc output, which
  # Xcode's build rule writes to the target's DERIVED_FILE_DIR.
  builtPrefix = "$(BUILT_PRODUCTS_DIR)/";
  compiledPath = name: f:
    if lib.hasPrefix builtPrefix f then "BUILT_PRODUCTS_DIR/${lib.removePrefix builtPrefix f}"
    else if lib.hasSuffix ".y" f then "derived/${name}/${lib.removeSuffix ".y" (baseNameOf f)}.c"
    else f;

  buildTool = name: t:
    let
      holes = lib.attrNames (t.allowUndefined or { });
      srcs = sourceLists.${name};
      yaccs = lib.filter (lib.hasSuffix ".y") srcs;
      libs = t.libraries or [ ];
      expectedDeps = lib.sort (a: b: a < b)
        ([ "/usr/lib/libSystem.B.dylib" ] ++ map (l: l.pkg.installName) libs);
      needsBuilt = lib.any (lib.hasPrefix builtPrefix) srcs;
    in
    assert lib.assertMsg (needsBuilt -> t ? builtProducts)
      "shell_cmds: ${name} compiles BUILT_PRODUCTS_DIR files but names no builtProducts";
    ''
      md_log "shell_cmds: ${name}"
      ${lib.optionalString (t ? builtProducts) ''
        mkdir -p BUILT_PRODUCTS_DIR
        cp --no-preserve=mode -r ${t.builtProducts}/. BUILT_PRODUCTS_DIR/
      ''}
      ${lib.concatMapStringsSep "\n" (y: ''
        mkdir -p derived/${name}
        bison -y -o ${compiledPath name y} ${y}
      '') yaccs}
      md_compile $PWD/o/${name} "$CC" ${lib.escapeShellArgs cflags} \
        ${lib.escapeShellArgs (map (d: "-D${d}") (t.defines or defines))} \
        ${lib.concatMapStringsSep " " (i: "-iquote $PWD/${i}") (t.includes or [ ])} \
        ${lib.concatMapStringsSep " " (l: "-I${l.pkg.headers}/usr/include") libs} \
        ${lib.escapeShellArgs (t.cflags or [ ])} \
        -- ${lib.concatMapStringsSep " " (f: "$PWD/${compiledPath name f}") srcs}
      objs=()
      while IFS= read -r o; do objs+=( "$o" ); done < <(find $PWD/o/${name} -name '*.o' | sort)
      # -undefined error, except for the symbols declared absent above.
      "$CC" ${lib.escapeShellArgs ldflags} \
        ${lib.concatMapStringsSep " " (l: "-L${l.pkg}/usr/lib -l${l.l}") libs} \
        ${lib.concatMapStringsSep " " (s: lib.escapeShellArg "-Wl,-U,${s}") holes} \
        -o $PWD/bin/${name} "''${objs[@]}"

      md_verify_pure   $PWD/bin/${name}
      md_verify_signed $PWD/bin/${name}

      deps=$($OTOOL -L $PWD/bin/${name} | tail -n +2 | awk '{ print $1 }' | sort -u)
      if [ "$deps" != ${lib.escapeShellArg (lib.concatStringsSep "\n" expectedDeps)} ]; then
        echo "shell_cmds: ${name} links other than ${lib.concatStringsSep ", " expectedDeps}:" >&2
        echo "$deps" >&2
        exit 1
      fi

      # A declared hole the tool no longer imports is stale.
      $NM -u $PWD/bin/${name} | awk '{ print $NF }' | sort -u > $PWD/o/${name}.imports
      for s in ${lib.escapeShellArgs holes}; do
        grep -qx -- "$s" $PWD/o/${name}.imports || {
          echo "shell_cmds: ${name} declares $s absent but does not import it" >&2
          exit 1; }
      done
    '';

  installTool = name: t: ''
    install -Dm755 bin/${name} $out${installPath name t}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList
      (src: dst: "install -Dm644 ${src} $out${dst}")
      (t.man or { "${name}/${name}.1" = "/usr/share/man/man1/${product name t}.1"; }))}
  '';
in

mkDarwinPackage {
  pname = "shell_cmds";
  version = lib.removePrefix "shell_cmds-" sources.shell_cmds.rev;

  src = sources.shell_cmds;
  inherit toolchain;

  nativeBuildInputs = [ bison ]; # find's getdate.y

  # Unioned by rootfs.nix into the tree's declared holes.
  passthru.allowUndefined =
    lib.foldl' (acc: t: acc // (t.allowUndefined or { })) { } (lib.attrValues tools);
  passthru.tools = lib.mapAttrs installPath tools;

  buildPhase = ''
    runHook preBuild

    export MD_SRCROOT=$PWD
    mkdir -p o bin

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList buildTool checkedTools)}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList installTool checkedTools)}

    runHook postInstall
  '';

  meta.description = "shell_cmds tools (${lib.concatStringsSep ", " (lib.attrNames tools)}), linked against minidarwin's libSystem";
}
