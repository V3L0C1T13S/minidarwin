# Stage 6: system_cmds targets (see ../cmds/mk-cmds.nix) -- the ones a plain
# userland has: sync, sysctl, getconf, dmesg, zdump/zic, accounting (ac,
# accton, sa), ...
# Not reproduced: the project's base.xcconfig includes Apple's internal
# BSD.xcconfig, which is not released; what base.xcconfig itself sets is below.
#
# Not built, among the rest: the tools that need frameworks or libraries that
# are not released or not built (arch, chpass, chkpasswd, dynamic_pager,
# fs_usage, gcore, iostat, login, nvram, reboot, shutdown, latency,
# sc_usage, ...), the set-uid ones the rootfs format cannot mark (at,
# newgrp, passwd), and Apple-internal diagnostics (kpgo, stackshot, zlog, ...).
{ lib
, mkCmds
, sources
, toolchain
, runCommand
, gawk
}:

let
  src = sources.system_cmds;

  # base.xcconfig's OTHER_CFLAGS (XPC_BUILD_OTHER_CFLAGS) and
  # HEADER_SEARCH_PATHS, for every target that does not set its own.
  xpcDefines = [
    "-DHAVE_KDEBUG_TRACE=1"
    "-DCONFIG_EMULATE_XNU_INITPROC_SELECTION=0"
    "-DHAVE_GALARCH_AVAILABILITY=1" # XPC_COMPATIBILITY_DEFINES_currentmajor
    "-D__XPC_PROJECT_BUILD__=1"
  ];
  baseCflags = xpcDefines ++ [
    "-iwithsysroot"
    "/System/Library/Frameworks/System.framework/PrivateHeaders"
    "-I."
  ];

  # getconf's script phase: fake-gperf.awk over each .gperf.
  getconfGenerated = runCommand "getconf-generated" { nativeBuildInputs = [ gawk ]; } ''
    mkdir -p $out
    for t in confstr limits pathconf progenv sysconf unsigned_limits; do
      LC_ALL=C awk -f ${src}/getconf/fake-gperf.awk ${src}/getconf/$t.gperf > $out/$t.c
    done
  '';

  man8 = name: { "${name}/${name}.8" = "/usr/share/man/man8/${name}.8"; };

  # Per target, what differs from the project's Release settings; the
  # attributes are described in mk-cmds.nix.
  tools = {
    ac = {
      installDir = "/usr/sbin";
      man = man8 "ac";
      # Login records, from wtmpx; see shell_cmds' who.
      allowUndefined = {
        "_endutxent_wtmp" = "system_asl";
        "_getutxent_wtmp" = "system_asl";
        "_setutxent_wtmp" = "system_asl";
        "_wtmpxname" = "system_asl";
      };
    };
    accton = { installDir = "/usr/sbin"; man = man8 "accton"; };
    dmesg = { installDir = "/sbin"; man = man8 "dmesg"; };
    getconf = {
      defines = [ "APPLE_GETCONF_UNDERSCORE" ];
      builtProducts = getconfGenerated;
      includes = [ "getconf" ]; # the generated files include "getconf.h"
    };
    hostinfo = { man = man8 "hostinfo"; };
    mkfile = { installDir = "/usr/sbin"; man = man8 "mkfile"; };
    nologin = {
      installDir = "/sbin";
      man = {
        "nologin/nologin.5" = "/usr/share/man/man5/nologin.5";
        "nologin/nologin.8" = "/usr/share/man/man8/nologin.8";
      };
      # The refused login is logged.
      allowUndefined = {
        "_closelog" = "system_asl";
        "_openlog" = "system_asl";
        "_syslog$DARWIN_EXTSN" = "system_asl";
      };
    };
    pwd_mkdb = {
      installDir = "/usr/sbin";
      man = man8 "pwd_mkdb";
      defines = [ "_PW_NAME_LEN=MAXLOGNAME" ''_PW_YPTOKEN="__YP!"'' ];
    };
    sa = {
      installDir = "/usr/sbin";
      man = man8 "sa";
      defines = [ "AHZV1=64" ];
      allowUndefined."_user_from_uid" = "system_info"; # -m's per-user summary
    };
    sync = { installDir = "/bin"; man = man8 "sync"; };
    sysctl = {
      installDir = "/usr/sbin";
      man = {
        "sysctl/sysctl.8" = "/usr/share/man/man8/sysctl.8";
        "sysctl/sysctl.conf.5" = "/usr/share/man/man5/sysctl.conf.5";
      };
    };
    vm_stat = { };
    wait4path = {
      # xcconfigs/wait4path.xcconfig, which is libxpc's executable.xcconfig.
      installDir = "/bin";
      cflags = xpcDefines ++ [
        "-DXPC_BUILD_TARGET_EXECUTABLE=1"
        "-DXPC_PROJECT_EXPORT=XPC_EXPORT"
        "-DXPC_DEBUGEXPORT=XPC_NOEXPORT"
        "-DXPC_TESTEXPORT=XPC_NOEXPORT" # XPC_BUILD_EXPORT_DEFAULTS
        "-D__XPC_BUILDING_WAIT4PATH__=1"
        "-iwithsysroot"
        "/System/Library/Frameworks/System.framework/PrivateHeaders"
        "-I."
        "-Iwait4path"
      ];
      notCompiled."wait4path/wait4path.version" = "the xcconfig's version settings, #included by it";
    };
    # HEADER_SEARCH_PATHS and OTHER_CFLAGS replace base.xcconfig's.
    zdump = { installDir = "/usr/sbin"; man = man8 "zdump"; cflags = [ "-Izic" "-include" "tzconfig.h" ]; };
    zic = {
      installDir = "/usr/sbin";
      man = man8 "zic";
      cflags = [ "-Izic" "-include" "tzconfig.h" ];
      # -u, -g: the owner and group of what it writes.
      allowUndefined = {
        "_getgrnam" = "system_info";
        "_getpwnam" = "system_info";
      };
    };
  };
in

mkCmds {
  pname = "system_cmds";
  inherit src toolchain;
  tools = lib.mapAttrs (_: t: t // { cflags = t.cflags or baseCflags; }) tools;
  sourceLists = import ./system-cmds-sources.nix;

  # Project-level Release settings (system_cmds.xcodeproj) over
  # xcconfigs/base.xcconfig. The project's GCC_TREAT_WARNINGS_AS_ERRORS = NO
  # wins over the xcconfig's YES.
  cflags = [
    "-std=gnu99" # GCC_C_LANGUAGE_STANDARD
    "-Os" # GCC_OPTIMIZATION_LEVEL (Release default)
    "-fno-common" # GCC_NO_COMMON_BLOCKS
    "-fvisibility=hidden" # GCC_SYMBOLS_PRIVATE_EXTERN
    "-Wall"
    "-Wcast-align"
    "-Werror=strict-prototypes" # WARNING_CFLAGS
  ];
  defines = [ ];
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING
}
