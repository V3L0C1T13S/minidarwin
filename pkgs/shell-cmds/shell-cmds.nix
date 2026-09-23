# Stage 6: the first userland -- echo, pwd, uname, who from shell_cmds.
# Built as shell_cmds.xcodeproj builds each target (Release): one tool per
# target, linked against libSystem and nothing else, man page to man1.
# Not reproduced: apple-generic versioning's generated <tool>_vers.c (the
# __<tool>VersionString symbol), which nothing references.
{ lib
, mkDarwinPackage
, sources
, toolchain
}:

let
  sourceLists = import ./shell-cmds-sources.nix;

  # Per target: INSTALL_PATH (project default /usr/bin) and
  # GCC_PREPROCESSOR_DEFINITIONS beyond the project's __FBSDID=__RCSID.
  tools = {
    echo = { installDir = "/bin"; };
    pwd = { installDir = "/bin"; };
    uname = { installDir = "/usr/bin"; };
    who = {
      installDir = "/usr/bin";
      defines = [ "_UTMPX_COMPAT" "SUPPORT_UTMPX" ];
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
  };

  # Every tool built must have a generated source list, and vice versa.
  checkedTools =
    assert lib.assertMsg (lib.attrNames tools == lib.attrNames sourceLists)
      "shell_cmds: tools (${toString (lib.attrNames tools)}) and shell-cmds-sources.nix (${toString (lib.attrNames sourceLists)}) disagree";
    tools;

  # Project-level Release settings (shell_cmds.xcodeproj).
  cflags = [
    "-std=gnu99" # GCC_C_LANGUAGE_STANDARD
    "-Os" # GCC_OPTIMIZATION_LEVEL (Release default)
    "-fno-common" # GCC_NO_COMMON_BLOCKS
    "-D__FBSDID=__RCSID"
    "-Wall"
    "-Werror=format-nonliteral" # WARNING_CFLAGS
    "-Werror=implicit-function-declaration" # GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS
  ];
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING

  buildTool = name: t:
    let
      holes = lib.attrNames (t.allowUndefined or { });
    in
    ''
      md_log "shell_cmds: ${name}"
      md_compile $PWD/o/${name} "$CC" ${lib.escapeShellArgs cflags} \
        ${lib.escapeShellArgs (map (d: "-D${d}") (t.defines or [ ]))} \
        -- ${lib.concatMapStringsSep " " (f: "$PWD/${f}") sourceLists.${name}}
      objs=()
      while IFS= read -r o; do objs+=( "$o" ); done < <(find $PWD/o/${name} -name '*.o' | sort)
      # -undefined error, except for the symbols declared absent above.
      "$CC" ${lib.escapeShellArgs ldflags} \
        ${lib.concatMapStringsSep " " (s: lib.escapeShellArg "-Wl,-U,${s}") holes} \
        -o $PWD/bin/${name} "''${objs[@]}"

      md_verify_pure   $PWD/bin/${name}
      md_verify_signed $PWD/bin/${name}

      deps=$($OTOOL -L $PWD/bin/${name} | tail -n +2 | awk '{ print $1 }' | sort -u)
      if [ "$deps" != "/usr/lib/libSystem.B.dylib" ]; then
        echo "shell_cmds: ${name} links something other than libSystem:" >&2
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
    install -Dm755 bin/${name} $out${t.installDir}/${name}
    install -Dm644 ${name}/${name}.1 $out/usr/share/man/man1/${name}.1
  '';
in

mkDarwinPackage {
  pname = "shell_cmds";
  version = lib.removePrefix "shell_cmds-" sources.shell_cmds.rev;

  src = sources.shell_cmds;
  inherit toolchain;

  # Unioned by rootfs.nix into the tree's declared holes.
  passthru.allowUndefined =
    lib.foldl' (acc: t: acc // (t.allowUndefined or { })) { } (lib.attrValues tools);
  passthru.tools = lib.mapAttrs (n: t: "${t.installDir}/${n}") tools;

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

  meta.description = "echo, pwd, uname and who from shell_cmds, linked against minidarwin's libSystem";
}
