# Final XNU link, isolated from the expensive upstream source compilation.
{ lib, stdenv, sources, python3, llvmPackages, llvmSource, kernelObjects, targetArch }:
assert targetArch == "x86_64";
stdenv.mkDerivation {
  pname = "minidarwin-xnu";
  version = lib.removePrefix "xnu-" sources.xnu.rev;
  src = sources.libressl;
  dontConfigure = true;
  dontFixup = true;
  dontStrip = true;
  nativeBuildInputs = [ python3 ];
  buildPhase = ''
    cp ${./patch-static-trust.py} patch-static-trust.py
    cp ${./link-kernel.py} link-kernel.py
    python3 link-kernel.py ${kernelObjects}/root ${sources.libdispatch} ${./support} ${llvmSource} "$PWD"
  '';
  installPhase = ''
    install -Dm644 kernel $out/System/Library/Kernels/kernel
    install -Dm644 COPYING $out/share/licenses/libressl/COPYING
    install -Dm644 ${sources.xnu}/APPLE_LICENSE $out/share/licenses/xnu/APPLE_LICENSE
    ${llvmPackages.llvm}/bin/llvm-nm --defined-only kernel > symbols.txt
    for symbol in __start _kernel_bootstrap _bsd_init; do
      grep -q " $symbol$" symbols.txt || { echo "XNU missing $symbol" >&2; exit 1; }
    done
    test -z "$(${llvmPackages.llvm}/bin/llvm-nm --undefined-only kernel)"
  '';
  passthru = { inherit targetArch kernelObjects; };
  meta.description = "XNU release kernel built from pinned Apple sources";
}
