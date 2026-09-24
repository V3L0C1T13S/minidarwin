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
#               (C and C++ alike; the project's C standard is C-only, as
#               GCC_C_LANGUAGE_STANDARD is)
#   builtProducts  a derivation copied to BUILT_PRODUCTS_DIR first
#   notCompiled { <listed source> = <why>; } -- a file the generated list
#               names that Apple's build does not compile into the tool
#   man         { <file in the tarball> = <installed path>; }
#   links       { <installed path> = <installed path it names>; } -- what the
#               project hardlinks (id -> whoami, test -> [), as relative
#               symlinks: the rootfs format has no hardlinks, and a tool that
#               looks at getprogname() sees the link's name either way
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
, extraInstall ? "" # targets with nothing to compile (a script installed as-is)
, postPatch ? ""
, version ? lib.removePrefix "${pname}-" src.rev # when pname is not the project's
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
      listed = sourceLists.${name};
      notCompiled = t.notCompiled or { };
      srcs =
        assert lib.assertMsg (lib.all (f: lib.elem f listed) (lib.attrNames notCompiled))
          "${pname}: ${name}: notCompiled names a file its source list does not";
        lib.filter (f: !(lib.hasAttr f notCompiled)) listed;
      yaccs = lib.filter (lib.hasSuffix ".y") srcs;
      libs = t.libraries or [ ];
      needsBuilt = lib.any (lib.hasPrefix builtPrefix) srcs;
      # A target with C++ sources links with the C++ driver, so it also loads
      # libc++ -- the package's toolchain must be stage 4 for that.
      isCxx = f: lib.any (e: lib.hasSuffix e f) [ ".cc" ".cpp" ".cxx" ];
      cxxSrcs = lib.filter isCxx srcs;
      cSrcs = lib.filter (f: !isCxx f) srcs;
      # -no_implicit_dylibs: our libc++.1.dylib reaches libc++abi through
      # LC_REEXPORT_DYLIB, and lld would add a load command for any re-exported
      # dylib directly in /usr/lib that a symbol came from. Apple's C++ tools
      # load libc++.1.dylib alone; this binds the ABI symbols through it too.
      linker = if cxxSrcs == [ ] then "$CC" else "$CXX -Wl,-no_implicit_dylibs";
      expectedDeps = lib.sort (a: b: a < b)
        ([ "/usr/lib/libSystem.B.dylib" ]
          ++ lib.optional (cxxSrcs != [ ]) "/usr/lib/libc++.1.dylib"
          ++ map (l: l.pkg.installName) libs);
      compileFlags = lang: ''
        ${lib.escapeShellArgs (if lang == "c" then cflags else lib.filter (f: !lib.hasPrefix "-std=" f) cflags)} \
        ${lib.escapeShellArgs (map (d: "-D${d}") (t.defines or defines))} \
        ${lib.concatMapStringsSep " " (i: "-iquote $PWD/${i}") (t.includes or [ ])} \
        ${lib.concatMapStringsSep " " (l: "-I${l.pkg.headers}/usr/include") (lib.filter (l: l.pkg ? headers) libs)} \
        ${lib.escapeShellArgs (t.cflags or [ ])}'';
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
      ${lib.optionalString (cSrcs != [ ]) ''
      md_compile $PWD/o/${name} "$CC" ${compileFlags "c"} \
        -- ${lib.concatMapStringsSep " " (f: "$PWD/${compiledPath name f}") cSrcs}
      ''}
      ${lib.optionalString (cxxSrcs != [ ]) ''
      md_compile $PWD/o/${name} "$CXX" ${compileFlags "c++"} \
        -- ${lib.concatMapStringsSep " " (f: "$PWD/${compiledPath name f}") cxxSrcs}
      ''}
      objs=()
      while IFS= read -r o; do objs+=( "$o" ); done < <(find $PWD/o/${name} -name '*.o' | sort)
      # -undefined error, except for the symbols declared absent above.
      ${linker} ${lib.escapeShellArgs ldflags} \
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

  # Relative, so the link resolves inside the rootfs wherever it is unpacked.
  mkLink = link: target: ''
    [ -e $out${target} ] || { echo "${pname}: ${link} -> ${target}, which is not installed" >&2; exit 1; }
    mkdir -p $out${dirOf link}
    ln -s "$(realpath -m --relative-to=$out${dirOf link} $out${target})" $out${link}
  '';
in

mkDarwinPackage {
  inherit pname version src toolchain nativeBuildInputs postPatch;

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
    ${extraInstall}
    ${lib.concatStringsSep "\n" (lib.concatLists (lib.mapAttrsToList
      (_: t: lib.mapAttrsToList mkLink (t.links or { })) checkedTools))}

    runHook postInstall
  '';

  meta.description = "${pname} tools (${lib.concatStringsSep ", " (lib.attrNames tools)}), linked against minidarwin's libSystem";
}
