# mkDarwinPackage - base for target artifacts (stdenvNoCC, dontFixup, pure).
{ lib, stdenvNoCC, buildSupport }:

{ pname
, version
, src ? null
, srcs ? [ ]
, toolchain
  # Host-side tools this build needs (perl, bison, ...).
, nativeBuildInputs ? [ ]
, ...
}@args:

stdenvNoCC.mkDerivation (
  (builtins.removeAttrs args [ "toolchain" "nativeBuildInputs" ]) // {
    inherit pname version;

    nativeBuildInputs = [ toolchain ] ++ nativeBuildInputs;

    dontFixup = true;
    dontStrip = true;
    dontPatchELF = true;
    dontPatchShebangs = true;

    SOURCE_DATE_EPOCH = "1";
    ZERO_AR_DATE = "1";
    TZ = "UTC";
    LC_ALL = "C";

    preConfigure = ''
      source ${buildSupport}
    '';

    passthru = (args.passthru or { }) // {
      inherit toolchain;
      sysroot = toolchain.sysroot;
    };
  }
)
