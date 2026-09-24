# Stage 6: patch_cmds targets (see ../cmds/mk-cmds.nix): cmp, diff, diff3,
# diffstat, patch, sdiff. Not reproduced: apple-generic versioning's generated
# <tool>_vers.c, as for shell_cmds; the test files (/AppleInternal/Tests).
{ mkCmds
, sources
, toolchain
, libutil
}:

let
  # cmp, diff, diff3 and sdiff come from Xcode's newer target template.
  modern = [
    "-std=gnu11" # GCC_C_LANGUAGE_STANDARD
    "-Werror=return-type" # GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR
    "-Wshorten-64-to-32" # GCC_WARN_64_TO_32_BIT_CONVERSION
    "-Wconditional-uninitialized" # GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE
    "-Wstrict-prototypes" # CLANG_WARN_STRICT_PROTOTYPES
  ];

  # Per target, what differs from the project's Release settings; the
  # attributes are described in mk-cmds.nix.
  tools = {
    cmp = {
      cflags = modern;
      libraries = [{ pkg = libutil; l = "util"; }]; # OTHER_LDFLAGS = -lutil
    };
    diff = { cflags = modern ++ [ "-Idiff" ]; }; # HEADER_SEARCH_PATHS
    diff3 = { cflags = modern; };
    diffstat = {
      defines = [ "HAVE_CONFIG_H" "_XOPEN_SOURCE=500" "_DARWIN_C_SOURCE" ];
      cflags = [ "-Idiffstat" ]; # HEADER_SEARCH_PATHS
    };
    patch = { };
    sdiff = {
      cflags = modern;
      notCompiled."sdiff/extern.h" = "a header in the sources phase";
    };
  };
in

mkCmds {
  pname = "patch_cmds";
  src = sources.patch_cmds;
  inherit toolchain tools;
  sourceLists = import ./patch-cmds-sources.nix;

  # Project-level Release settings (patch_cmds.xcodeproj).
  cflags = [
    "-Os" # GCC_OPTIMIZATION_LEVEL (Release default)
    "-Wall" # WARNING_CFLAGS
  ];
  defines = [ ];
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING
}
