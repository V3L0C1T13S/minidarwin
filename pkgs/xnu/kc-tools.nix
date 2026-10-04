{ lib, stdenv, sources, cmake, ninja, python3 }:
stdenv.mkDerivation {
  pname = "minidarwin-kc-tools";
  version = builtins.substring 0 7 sources.kc_tools.rev;
  src = sources.kc_tools;
  nativeBuildInputs = [ cmake ninja python3 ];
  postPatch = ''
    python3 ${./patch-kc-relocations.py} lib/linker.c ${./kc/dysymtab-relocations.c.inc}
  '';
  postInstall = ''
    install -Dm644 $src/LICENSE $out/share/licenses/kc-tools/LICENSE
  '';
  meta = {
    description = "Open source Mach-O kernel collection assembler";
    license = lib.licenses.bsd3;
  };
}
