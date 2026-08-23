# Stage 4 SDK: stage 3 sysroot + the shared C++ runtimes (libc++.1.dylib, libc++abi.dylib).
# The first sysroot where a plain `c++ ... -lc++` links: stage 3 ships only the
# static libc++.a, which -- as upstream builds it, with no LIBCXX_ENABLE_STATIC_ABI_LIBRARY
# -- has none of the ABI runtime in it, so ___dynamic_cast and the __cxxabiv1
# type_info vtables are undefined. Here -lc++ finds libc++.dylib first and reaches
# them through its LC_REEXPORT_DYLIB on /usr/lib/libc++abi.dylib, as on a real system.
{ lib
, stdenvNoCC
, sdkStage3
, libcxxDylib
, libcxxabiDylib
}:

stdenvNoCC.mkDerivation {
  pname = "minidarwin-sdk-stage4";
  version = sdkStage3.version;

  dontUnpack = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    cp -R ${sdkStage3} $out
    chmod -R u+w $out

    for pkg in ${libcxxabiDylib} ${libcxxDylib}; do
      while IFS= read -r f; do
        rel="''${f#$pkg/}"
        if [ -e "$out/$rel" ]; then
          echo "sdk-stage4: $rel provided by more than one input" >&2
          exit 1
        fi
        install -Dm755 "$f" "$out/$rel"
      done < <(find $pkg -type f | sort)
      # libc++.dylib -> libc++.1.dylib, the name -lc++ actually resolves.
      while IFS= read -r l; do
        rel="''${l#$pkg/}"
        [ -e "$out/$rel" ] || cp -a "$l" "$out/$rel"
      done < <(find $pkg -type l | sort)
    done

    # -lc++ / -lc++abi must find the dylib, which ld64 prefers over the archive.
    test -L $out/usr/lib/libc++.dylib
    test -e $out/usr/lib/libc++.1.dylib
    test -e $out/usr/lib/libc++abi.dylib

    runHook postInstall
  '';

  meta.description = "minidarwin SDK with the shared C++ runtimes -- links with -lc++";
}
