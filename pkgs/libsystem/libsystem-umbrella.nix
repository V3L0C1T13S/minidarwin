# Stage 4: /usr/lib/libSystem.B.dylib - umbrella re-exporting /usr/lib/system members.
# Reproduces linker_arguments.sh; init.c deferred to stage 5 (needs unreleased headers).
{ lib
, stdenvNoCC
, mkDarwinPackage
, sources
, toolchain
, targetArch
  # The pass-2 tree.
, members
}:

let
  requiredLibs = builtins.readFile "${sources.Libsystem}/requiredlibs"; # one entry/line; multi-name lines are preference lists
  absentRequired = lib.attrNames (import ./absent-members.nix { inherit targetArch; }); # requiredlibs missing due to absent/closed
  currentVersion = "159"; # CURRENT_VERSION_STRING_ from Libsystem.xcconfig
in

mkDarwinPackage {
  pname = "libSystem";
  version = lib.removePrefix "Libsystem-" sources.Libsystem.rev;

  inherit toolchain;
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    # List members present in /usr/lib/system (linker_arguments.sh `ls` step).
    ( cd ${members}/usr/lib/system && ls lib*.dylib ) |
      sed -e 's/^lib//' -e 's/\.dylib$//' | sort -u > present.txt
    md_log "libSystem: $(wc -l < present.txt | tr -d ' ') members in /usr/lib/system"

    # MISSINGLIBS check: required entries must be present or in absent-members.nix.
    printf '%s' ${lib.escapeShellArg requiredLibs} > required.txt
    missing=()
    while read -r line; do
      [ -n "$line" ] || continue
      found=0
      for l in $line; do
        grep -qx "$l" present.txt && { found=1; break; }
      done
      [ "$found" = 1 ] || missing+=( "''${line%% *}" )
    done < required.txt

    expected=( ${lib.escapeShellArgs absentRequired} )
    unexpected=()
    for m in ''${missing[@]+"''${missing[@]}"}; do
      case " ${lib.concatStringsSep " " absentRequired} " in
        *" $m "*) ;;
        *) unexpected+=( "$m" ) ;;
      esac
    done
    if [ "''${#unexpected[@]}" -gt 0 ]; then
      echo "libSystem: required members missing and unaccounted for: ''${unexpected[*]}" >&2
      echo "(if one of these is genuinely unbuildable, say so in umbrella-link.nix)" >&2
      exit 1
    fi
    for m in "''${expected[@]}"; do
      if grep -qx "$m" present.txt; then
        echo "libSystem: $m is listed as absent but is present -- drop it from the list" >&2
        exit 1
      fi
    done
    md_log "libSystem: ''${#expected[@]} required members absent (see umbrella-link.nix)"

    # Link with -reexport-l (no sources).
    mapfile -t reexports < <(sed 's/^/-Wl,-reexport-l/' present.txt)
    mkdir -p obj
    MD_CURRENT_VERSION=${currentVersion} \
    md_dylib libSystem.B.dylib /usr/lib/libSystem.B.dylib obj \
      -Wl,-search_paths_first \
      -L${members}/usr/lib/system \
      "''${reexports[@]}"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libSystem.B.dylib $out/usr/lib/libSystem.B.dylib

    # BSD compat symlinks (create_dylib_symlinks.sh): -lc, -lm, etc. all inside libSystem.
    ln -s libSystem.B.dylib $out/usr/lib/libSystem.dylib
    for l in c info m pthread dbm poll dl rpcsvc proc gcc_s.1; do
      ln -s libSystem.dylib $out/usr/lib/lib$l.dylib
    done

    md_verify_pure   $out/usr/lib/libSystem.B.dylib
    md_verify_signed $out/usr/lib/libSystem.B.dylib

    # Umbrella has no own symbols; verify each member is re-exported.
    while read -r m; do
      md_verify_reexports $out/usr/lib/libSystem.B.dylib "/usr/lib/system/lib$m.dylib"
    done < present.txt

    runHook postInstall
  '';

  meta.description = "libSystem.B.dylib -- the umbrella over /usr/lib/system";
}
