# Merges umbrella members into one /usr/lib/system tree for -L; `stage1` in umbrella-link.nix. Collisions fail.
{ lib
, stdenvNoCC
, members
, name ? "minidarwin-libsystem-tree"
}:

stdenvNoCC.mkDerivation {
  pname = name;
  version = "1";

  dontUnpack = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/usr/lib/system

    for pkg in ${lib.escapeShellArgs members}; do
      while IFS= read -r f; do
        rel="''${f#$pkg/}"
        if [ -e "$out/$rel" ]; then
          echo "libsystem-tree: $rel provided by more than one member" >&2
          exit 1
        fi
        install -Dm755 "$f" "$out/$rel"
      done < <(find $pkg -type f | sort)
    done

    n=$(find $out/usr/lib/system -name '*.dylib' | wc -l | tr -d ' ')
    echo "[minidarwin] ${name}: $n dylibs" >&2
    [ "$n" -gt 0 ] || { echo "libsystem-tree: empty" >&2; exit 1; }

    runHook postInstall
  '';

  meta.description = "Merged /usr/lib/system for the libSystem umbrella members";
}
