# Stage 6: system_cmds targets (see ../cmds/mk-cmds.nix) -- the ones a plain
# userland has: sync, sysctl, getconf, dmesg, zdump/zic, accounting (ac,
# accton, sa), ...
# Not reproduced: the project's base.xcconfig includes Apple's internal
# BSD.xcconfig, which is not released; what base.xcconfig itself sets is below.
#
# Not built, among the rest: the tools that need frameworks or libraries that
# are not released or not built (chpass, chkpasswd, dynamic_pager,
# fs_usage, gcore, iostat, nvram, reboot, shutdown, latency,
# sc_usage, ...), the set-uid ones the rootfs format cannot mark (at,
# newgrp, passwd), and Apple-internal diagnostics (kpgo, stackshot, zlog, ...).
{ lib
, mkCmds
, sources
, toolchain
, runCommand
, gawk
, callPackage
, authHeaders
}:

let
  src = sources.system_cmds;
  archHeaders = callPackage ./arch-headers.nix { };

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
    arch = {
      # TARGET_OS_OSX selects Apple's Intel-on-ARM support and the kernel
      # affinity reset. Include it explicitly, independent of CF's umbrella.
      cflags = baseCflags ++ [ "-include" "TargetConditionals.h" "-I${archHeaders}" "-I${./include}" ];
      man = {
        "arch/arch.1" = "/usr/share/man/man1/arch.1";
        "arch/machine.1" = "/usr/share/man/man1/machine.1";
      };
      links."/usr/bin/machine" = "/usr/bin/arch";
      # Preserve plist preferences; these implementations are not built yet.
      allowUndefined = {
        "_environ" = "dyld";
        "_CFArrayGetCount" = "CoreFoundation";
        "_CFArrayGetTypeID" = "CoreFoundation";
        "_CFArrayGetValueAtIndex" = "CoreFoundation";
        "_CFDataCreateWithBytesNoCopy" = "CoreFoundation";
        "_CFDictionaryGetTypeID" = "CoreFoundation";
        "_CFDictionaryGetValue" = "CoreFoundation";
        "_CFEqual" = "CoreFoundation";
        "_CFGetTypeID" = "CoreFoundation";
        "_CFPropertyListCreateWithData" = "CoreFoundation";
        "_CFRelease" = "CoreFoundation";
        "_CFStringGetCString" = "CoreFoundation";
        "_CFStringGetFileSystemRepresentation" = "CoreFoundation";
        "_CFStringGetTypeID" = "CoreFoundation";
        "___CFConstantStringClassReference" = "CoreFoundation";
        "_kCFAllocatorDefault" = "CoreFoundation";
        "_kCFAllocatorMalloc" = "CoreFoundation";
        "_sysdir_start_search_path_enumeration" = "system_coreservices";
        "_sysdir_get_next_search_path_enumeration" = "system_coreservices";
      };
    };
    dmesg = { installDir = "/sbin"; man = man8 "dmesg"; };
    getconf = {
      defines = [ "APPLE_GETCONF_UNDERSCORE" ];
      builtProducts = getconfGenerated;
      includes = [ "getconf" ]; # the generated files include "getconf.h"
    };
    hostinfo = { man = man8 "hostinfo"; };
    login = {
      # INSTALL_MODE_FLAG u+s: installed 0755, as su is -- the rootfs format
      # has no set-id bits. The entitlements are not carried either.
      man."login/login.1" = "/usr/share/man/man1/login.1";
      defines = [ "USE_PAM" "USE_BSM_AUDIT" ];
      cflags = baseCflags ++ [ "-I${authHeaders}" "-I${./login-include}" ];
      allowUndefined = {
        "_pam_start" = "pam";
        "_pam_end" = "pam";
        "_pam_authenticate" = "pam";
        "_pam_acct_mgmt" = "pam";
        "_pam_chauthtok" = "pam";
        "_pam_setcred" = "pam";
        "_pam_set_item" = "pam";
        "_pam_get_item" = "pam";
        "_pam_getenvlist" = "pam";
        "_pam_open_session" = "pam";
        "_pam_strerror" = "pam";
        "_pam_close_session" = "pam";
        "_openpam_ttyconv" = "pam";
        "_audit_set_terminal_id" = "bsm";
        "_au_close" = "bsm";
        "_au_open" = "bsm";
        "_au_to_return32" = "bsm";
        "_au_to_subject32_ex" = "bsm";
        "_au_to_text" = "bsm";
        "_au_user_mask" = "bsm";
        "_au_write" = "bsm";
        # Weak, as Apple links libEndpointSecuritySystem; see login-include.
        "_ess_notify_login_login" = "EndpointSecuritySystem";
        "_ess_notify_login_logout" = "EndpointSecuritySystem";
        "_getgrnam" = "system_info";
        "_getpwnam_r" = "system_info";
        "_endpwent" = "system_info";
        "_initgroups" = "system_info";
        "_getlastlogxbyname" = "system_asl"; # utmpx, see shell_cmds' who
        "_openlog" = "system_asl";
        "_syslog$DARWIN_EXTSN" = "system_asl";
        "_environ" = "dyld";
      };
    };
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

  postPatch = ''
    # As su: <bsm/audit_session.h> is not released; the pinned xnu's
    # <bsm/audit.h> declares the session types and flags login uses.
    substituteInPlace login/login.c login/login_audit.c \
      --replace-fail '#include <bsm/audit_session.h>' '#include <bsm/audit.h>'
    # launchd's <servers/bootstrap.h> is unreleased, and login uses nothing
    # from it.
    substituteInPlace login/login.c --replace-fail '#include <servers/bootstrap.h>' ""
    # Unused legacy directory-search header; arch uses sysdir.h instead.
    substituteInPlace arch/arch.c --replace-fail '#include <NSSystemDirectories.h>' ""
  '';

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
  # login's pam.d CopyFiles phase.
  extraInstall = ''
    install -Dm644 login/pam.d/login $out/private/etc/pam.d/login
    install -Dm644 login/pam.d/login.term $out/private/etc/pam.d/login.term
  '';
  ldflags = [ "-Wl,-dead_strip" ]; # DEAD_CODE_STRIPPING
}
