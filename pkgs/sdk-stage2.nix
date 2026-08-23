# Stage 2 SDK: stage 1 headers + LLVM runtimes (libc++.a, libc++abi.a, libunwind.a + libunwind headers + c++/v1).
# libclang_rt.osx.a is via -resource-dir, not the sysroot.
{ lib
, stdenvNoCC
, sdkHeaders
, libunwind
, libcxxHeaders
, libcxxabi
, libcxx
}:

stdenvNoCC.mkDerivation {
  pname = "minidarwin-sdk-stage2";
  version = sdkHeaders.version;

  dontUnpack = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    cp -R ${sdkHeaders} $out
    chmod -R u+w $out

    # Merge runtimes (collision is an error).
    for pkg in ${libunwind} ${libcxxHeaders} ${libcxxabi} ${libcxx}; do
      while IFS= read -r f; do
        rel="''${f#$pkg/}"
        if [ -e "$out/$rel" ]; then
          echo "sdk-stage2: $rel provided by more than one runtime" >&2
          exit 1
        fi
        install -Dm644 "$f" "$out/$rel"
      done < <(find $pkg -type f | sort)
    done

    test -e $out/usr/include/c++/v1/vector
    test -e $out/usr/include/c++/v1/cxxabi.h
    test -e $out/usr/include/unwind.h
    for a in libc++.a libc++abi.a libunwind.a; do
      test -e $out/usr/lib/$a
    done

    runHook postInstall
  '';

  meta.description = "minidarwin SDK with the stage 3 LLVM runtimes";
}
