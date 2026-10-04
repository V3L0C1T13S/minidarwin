# Upstream LLVM frontend plus open-source XNU layout builtins; host tool only.
{ lib, stdenv, python3, llvmPackages, xnuClangObjects }:
stdenv.mkDerivation {
  pname = "minidarwin-xnu-clang";
  version = llvmPackages.clang-unwrapped.version;
  dontUnpack = true;
  dontConfigure = true;
  nativeBuildInputs = [ python3 ];
  buildInputs = [ llvmPackages.llvm ];
  dontFixup = true;
  buildPhase = ''
    $CXX -std=c++17 -O2 -fno-exceptions -I${./clang} \
      -I${llvmPackages.clang-unwrapped.dev}/include \
      -I${llvmPackages.llvm.dev}/include \
      -c ${./clang/XnuTypeLayout.cpp} -o layout.o
    python3 ${./clang/link-frontend.py} ${xnuClangObjects}/link.json
    ln -s clang clang++
  '';
  doCheck = true;
  checkPhase = ''
    ./clang -target x86_64-apple-darwin -ffreestanding \
      -nostdinc -O2 -c ${./clang/layout-test.c} -o layout-c.o
    ./clang++ -target x86_64-apple-darwin -ffreestanding \
      -nostdinc -std=c++20 -O2 -c ${./clang/layout-test.cpp} -o layout-cxx.o
  '';
  installPhase = ''
    install -Dm755 clang $out/bin/clang
    ln -s clang $out/bin/clang++
    mkdir -p $out/lib
    ln -s ${llvmPackages.clang-unwrapped.lib}/lib/clang $out/lib/clang
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/clang -target x86_64-apple-darwin -ffreestanding -nostdinc \
      -O2 -c ${./clang/layout-test.c} -o installed-c.o
    $out/bin/clang++ -target x86_64-apple-darwin -ffreestanding -nostdinc \
      -std=c++20 -O2 -c ${./clang/layout-test.cpp} -o installed-cxx.o
  '';
  meta.description = "LLVM Clang with MiniDarwin's x86_64 XNU layout builtins";
  meta.license = lib.licenses.asl20;
}
