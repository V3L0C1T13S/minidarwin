# Stage 6: one package per *_cmds project -- each tool target built as the
# project's .xcodeproj builds it (Release): one tool per target, linked against
# libSystem plus whatever the target's OTHER_LDFLAGS or frameworks phase name,
# man pages as the target installs them.
#
# The project's own file (shell-cmds.nix, file-cmds.nix) supplies the
# project-level Release settings and a `tools` table, per target, of what
# differs from them:
#   installDir  INSTALL_PATH (project default /usr/bin)
#   product     PRODUCT_NAME, when it is not the target name
#   defines     GCC_PREPROCESSOR_DEFINITIONS -- a target setting replaces
#               the project's, it does not add to it
#   includes    USER_HEADER_SEARCH_PATHS, relative to the build directory
#   libraries   built dylibs this target links, each with passthru.installName
#               and a -l name, and passthru.headers if it has any
#   cflags      other compiler settings that change the result or can fail it
#   builtProducts  a derivation copied to BUILT_PRODUCTS_DIR first
#   man         { <file in the tarball> = <installed path>; }
#   allowUndefined  imports nothing in the tree defines yet, with the reason
{ lib
, mkDarwinPackage
}:

{ pname
, src
, toolchain
, sourceLists # the generated <project>-sources.nix
, tools
, cflags
, defines
, ldflags
, nativeBuildInputs ? [ ]
}:

let
  # Every tool built must have a generated source list, and vice versa.
  checkedTools =
    assert lib.assertMsg (lib.attrNames tools == lib.attrNames sourceLists)
      "${pname}: tools (${toString (lib.attrNames tools)}) and its generated source list (${toString (lib.attrNames sourceLists)}) disagree";
    tools;

  product = name: t: t.product or name;
  installPath = name: t: "${t.installDir or "/usr/bin"}/${product name t}";

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
      "${pname}: ${name} compiles BUILT_PRODUCTS_DIR files but names no builtProducts";
    ''
      md_log "${pname}: ${name}"
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
        ${lib.concatMapStringsSep " " (l: "-I${l.pkg.headers}/usr/include") (lib.filter (l: l.pkg ? headers) libs)} \
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
        echo "${pname}: ${name} links other than ${lib.concatStringsSep ", " expectedDeps}:" >&2
        echo "$deps" >&2
        exit 1
      fi

      # A declared hole the tool no longer imports is stale.
      $NM -u $PWD/bin/${name} | awk '{ print $NF }' | sort -u > $PWD/o/${name}.imports
      for s in ${lib.escapeShellArgs holes}; do
        grep -qx -- "$s" $PWD/o/${name}.imports || {
          echo "${pname}: ${name} declares $s absent but does not import it" >&2
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
  inherit pname src toolchain nativeBuildInputs;
  version = lib.removePrefix "${pname}-" src.rev;

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

  meta.description = "${pname} tools (${lib.concatStringsSep ", " (lib.attrNames tools)}), linked against minidarwin's libSystem";
}
