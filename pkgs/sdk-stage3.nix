# Stage 3 SDK: stage 2 sysroot + libSystem (first sysroot linkable with -lSystem, no -nostdlib).
{ lib
, stdenvNoCC
, sdkStage2
, libSystem
, libsystemTree2
}:

stdenvNoCC.mkDerivation {
  pname = "minidarwin-sdk-stage3";
  version = sdkStage2.version;

  dontUnpack = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    cp -R ${sdkStage2} $out
    chmod -R u+w $out

    for pkg in ${libsystemTree2} ${libSystem}; do
      while IFS= read -r f; do
        rel="''${f#$pkg/}"
        if [ -e "$out/$rel" ]; then
          echo "sdk-stage3: $rel provided by more than one input" >&2
          exit 1
        fi
        install -Dm755 "$f" "$out/$rel"
      done < <(find $pkg -type f | sort)
      # Compatibility symlinks (lib{c,m,pthread,...}.dylib).
      while IFS= read -r l; do
        rel="''${l#$pkg/}"
        [ -e "$out/$rel" ] || cp -a "$l" "$out/$rel"
      done < <(find $pkg -type l | sort)
    done

    test -e $out/usr/lib/libSystem.B.dylib
    test -e $out/usr/lib/libSystem.dylib
    test -e $out/usr/lib/system/libsystem_c.dylib
    n=$(find $out/usr/lib/system -name '*.dylib' | wc -l | tr -d ' ')
    echo "[minidarwin] sdk-stage3: libSystem over $n members" >&2

    runHook postInstall
  '';

  meta.description = "minidarwin SDK with libSystem -- the first linkable sysroot";
}
