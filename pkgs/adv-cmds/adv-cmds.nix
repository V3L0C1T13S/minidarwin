# Stage 6: adv_cmds targets (see ../cmds/mk-cmds.nix).
# Not reproduced: apple-generic versioning's generated <tool>_vers.c, as for
# shell_cmds; the targets' test files (/AppleInternal/Tests).
#
# ps is installed 0755, not 4755 as install-ps.sh does: the rootfs format has
# no set-id bits. Nor does it carry ps/entitlements.plist -- an ad-hoc
# signature cannot hold com.apple.private entitlements -- so it is built, as
# Apple builds it, with PS_ENTITLED, and reads what an unentitled process can.
#
# locale is C++, so this package links with toolchainStage4.
#
# Not built: last (written against libxo, which Apple has not released), pkill
# and pgrep (libsysmon, closed source), localedef (a host tool too, and the
# locale database is not built), genwrap (Apple's build-time wrapper
# generator), ps_lowpriv and the test helpers.
{ lib
, mkCmds
, sources
, toolchain
, ncurses
, runCommand
}:

let
  # ps includes <System/sys/persona.h> and <System/sys/proc.h>: System.framework's
  # headers, by framework name. The SDK's System.framework/PrivateHeaders holds
  # only the headers whose SFPINCFRAME rendering differs from usr/include's
  # (sdk-headers.nix), which an ordinary #include falls through from, but a
  # framework-qualified one cannot. This is that framework as Apple's SDK has
  # it: usr/include, with PrivateHeaders laid over it.
  systemFramework = runCommand "system-framework-includes" { } ''
    mkdir -p $out/System
    cp -rs ${toolchain.sysroot}/usr/include/. $out/System/
    chmod -R u+w $out/System
    cp -rsf ${toolchain.sysroot}/System/Library/Frameworks/System.framework/PrivateHeaders/. $out/System/
  '';

  fbsdid = [ "__FBSDID=__RCSID" ]; # the targets that set GCC_PREPROCESSOR_DEFINITIONS

  # Per target, what differs from the project's Release settings; the
  # attributes are described in mk-cmds.nix.
  tools = {
    cap_mkdb = { };
    finger = {
      defines = fbsdid;
      man = {
        "finger/finger.1" = "/usr/share/man/man1/finger.1";
        "finger/finger.conf.5" = "/usr/share/man/man5/finger.conf.5";
      };
      allowUndefined = {
        # Users, their login records, and remote fingerd hosts.
        "_endutxent" = "system_asl"; # utmpx; see shell_cmds' who
        "_endutxent_wtmp" = "system_asl";
        "_getutxent" = "system_asl";
        "_getutxent_wtmp" = "system_asl";
        "_setutxent" = "system_asl";
        "_setutxent_wtmp" = "system_asl";
        "_freeaddrinfo" = "system_info";
        "_gai_strerror" = "system_info";
        "_getaddrinfo" = "system_info";
        "_getnameinfo" = "system_info";
        "_getpwent" = "system_info";
        "_getpwnam" = "system_info";
        "_setpassent" = "system_info";
      };
    };
    gencat = { defines = fbsdid; };
    locale = { };
    lsvfs = { };
    ps = {
      installDir = "/bin";
      defines = fbsdid;
      cflags = [ "-DPS_ENTITLED" "-I${systemFramework}" ]; # OTHER_CFLAGS
      # -U, -G, -g and the user/ruser/group columns.
      allowUndefined = {
        "_getgrgid" = "system_info";
        "_getgrnam" = "system_info";
        "_getpwnam" = "system_info";
        "_getpwuid" = "system_info";
        "_user_from_uid" = "system_info";
      };
    };
    stty = { installDir = "/bin"; };
    tabs = {
      defines = fbsdid;
      # Frameworks phase: libtermcap.dylib, libncurses' symlink.
      libraries = [{ pkg = ncurses; l = "termcap"; }];
    };
    tty = { defines = fbsdid; };
    whois = {
      allowUndefined = {
        "_freeaddrinfo" = "system_info";
        "_gai_strerror" = "system_info";
        "_getaddrinfo" = "system_info";
      };
    };
  };
in

mkCmds {
  pname = "adv_cmds";
  src = sources.adv_cmds;
  inherit toolchain tools;
  sourceLists = import ./adv-cmds-sources.nix;

  # Project-level Release settings (adv_cmds.xcodeproj). No
  # GCC_C_LANGUAGE_STANDARD and no project GCC_PREPROCESSOR_DEFINITIONS.
  cflags = [
    "-Os" # GCC_OPTIMIZATION_LEVEL (Release default)
    "-fno-common" # GCC_NO_COMMON_BLOCKS
    "-Werror=format-nonliteral"
    "-Werror=format" # WARNING_CFLAGS
  ];
  defines = [ ];
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING
}
