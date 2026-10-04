# Build once; changing layout rules only recompiles the small final module.
{ lib, stdenv, cmake, ninja, python3, llvmPackages, llvmSource }:
stdenv.mkDerivation {
  pname = "minidarwin-xnu-clang-objects";
  version = llvmPackages.clang-unwrapped.version;
  dontUnpack = true;
  nativeBuildInputs = [ cmake ninja python3 ];
  buildInputs = [ llvmPackages.llvm ];
  dontFixup = true;
  configurePhase = ''
    cp -R ${llvmSource}/clang clang
    cp -R ${llvmSource}/cmake cmake
    chmod -R u+w clang
    cp ${./clang/layout-api.h} clang/lib/Sema/XnuTypeLayout.h
    (cd clang && python3 ${./clang/patch.py})
    cmake -S clang -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="-ffile-prefix-map=$NIX_BUILD_TOP=/minidarwin-clang-build" \
      -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$NIX_BUILD_TOP=/minidarwin-clang-build" \
      -DLLVM_DIR=${llvmPackages.llvm.dev}/lib/cmake/llvm \
      -DLLVM_TABLEGEN_EXE=${llvmPackages.tblgen}/bin/llvm-tblgen \
      -DCLANG_TABLEGEN=${llvmPackages.tblgen}/bin/clang-tblgen \
      -DLLVM_LINK_LLVM_DYLIB=ON -DLLVM_ENABLE_RTTI=ON \
      -DCLANG_LINK_CLANG_DYLIB=OFF \
      -DCLANG_ENABLE_STATIC_ANALYZER=OFF -DCLANG_ENABLE_LIBXML2=OFF \
      -DLLVM_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_DOCS=OFF
  '';
  buildPhase = ''
    python3 ${./clang/frontend-objects.py} "''${NIX_BUILD_CORES:-4}" "$out"
  '';
  dontInstall = true;
  meta.description = "LLVM frontend objects with XNU builtin syntax and semantic integration";
  meta.license = lib.licenses.asl20;
}
