# A development collection; root storage and filesystem drivers are separate.
{ lib, runCommand, python3, kcTools, llvmPackages, kernel, targetArch, kexts ? [ ] }:
assert targetArch == "x86_64";
runCommand ("minidarwin-kernel-collection" + lib.optionalString (kexts != [ ]) "-platform")
{
  nativeBuildInputs = [ kcTools python3 ];
  passthru = { inherit kernel targetArch kexts; };
} ''
  mkdir -p $out
  python3 ${./.}/assemble-collection.py \
    ${kernel}/System/Library/Kernels/kernel ${kernel.kernelObjects}/root $out/kernel \
    ${llvmPackages.llvm}/bin/llvm-nm ${lib.escapeShellArgs kexts}
''
