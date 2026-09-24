# Stage 6: basic_cmds targets (see ../cmds/mk-cmds.nix).
# Not reproduced: apple-generic versioning's generated <tool>_vers.c, as for
# shell_cmds. write is installed 0755, not set-group-id tty as its
# INSTALL_MODE_FLAG and INSTALL_GROUP say: the rootfs format has no set-id
# bits, so it can write only to terminals the user may.
{ mkCmds
, sources
, toolchain
}:

let
  # Per target, what differs from the project's Release settings; the
  # attributes are described in mk-cmds.nix.
  tools = {
    mesg = { };
    write = {
      allowUndefined = {
        # The recipient's terminal, from utmpx; see shell_cmds' who.
        "_endutxent" = "system_asl";
        "_getutxent" = "system_asl";
        "_getutxline" = "system_asl";
        "_setutxent" = "system_asl";
        "_getpwuid" = "system_info"; # the sender's name
      };
    };
  };
in

mkCmds {
  pname = "basic_cmds";
  src = sources.basic_cmds;
  inherit toolchain tools;
  sourceLists = import ./basic-cmds-sources.nix;

  # Project-level Release settings (basic_cmds.xcodeproj): no warning flags,
  # definitions or language standard.
  cflags = [ "-Os" ]; # GCC_OPTIMIZATION_LEVEL (Release default)
  defines = [ ];
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING
}
