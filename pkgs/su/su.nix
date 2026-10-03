# shell_cmds.xcodeproj's su target, including PAM and BSM auditing.
{ lib, mkCmds, sources, toolchain, authHeaders }:
mkCmds {
  pname = "su";
  version = lib.removePrefix "shell_cmds-" sources.shell_cmds.rev;
  src = sources.shell_cmds;
  inherit toolchain;
  sourceLists.su = [ "su/su.c" ];
  tools.su = {
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
      "_pam_getenv" = "pam";
      "_pam_open_session" = "pam";
      "_pam_close_session" = "pam";
      "_pam_strerror" = "pam";
      "_openpam_ttyconv" = "pam";
      "_audit_submit" = "bsm";
      "_getpwnam" = "system_info";
      "_getpwuid" = "system_info";
      "_initgroups" = "system_info";
      "_openlog" = "system_asl";
      "_syslog$DARWIN_EXTSN" = "system_asl";
      "_rootless_restricted_environment" = "system_darwin";
      "_dlopen" = "dyld";
      "_dlsym" = "dyld";
      "_environ" = "dyld";
    };
  };
  cflags = [ "-std=gnu99" "-Os" "-I${authHeaders}" "-I${./include}" ];
  defines = [ "__FBSDID=__RCSID" "USE_BSM_AUDIT" ];
  ldflags = [ "-Wl,-dead_strip" ];
  # audit.h in the pinned XNU already declares the session types/constants
  # used here; the SDK's separate audit_session.h is not released.
  postPatch = ''
    substituteInPlace su/su.c --replace-fail '#include <bsm/audit_session.h>' '#include <bsm/audit.h>'
    # Apple's source declares auid twice when BSM auditing is enabled.
    substituteInPlace su/su.c --replace-fail $'au_id_t\t\t auid;\n\t/* 4043304 */' $'/* auid is declared by USE_BSM_AUDIT above. */\n\t/* 4043304 */'
  '';
  extraInstall = ''
    install -Dm644 su/su.pam $out/private/etc/pam.d/su
  '';
}
