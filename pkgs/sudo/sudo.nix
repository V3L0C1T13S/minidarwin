# Apple's checked-in config.h selects its statically linked sudoers plugin.
# Compile the Xcode source lists directly with the hermetic target compiler.
{ lib, mkCmds, sources, toolchain, authHeaders, zlib }:
let
  lists = import ./sudo-sources.nix;
  util = lists.sudo_util;
  parser = lists.parsesudoers;
  policy = lists.sudoers ++ lists.sudo_eventlog ++ lists.sudo_iolog
    ++ lists.logsrv ++ lists."protobuf-c";
  allowUndefined = {
    "_endutxent" = "system_asl";
    "_pututxline" = "system_asl";
    "_setutxent" = "system_asl";
    "_getutxline" = "system_asl";
    "_openlog" = "system_asl";
    "_syslog$DARWIN_EXTSN" = "system_asl";
    "_getgrouplist_2" = "system_info";
    "_getgrouplist" = "system_info";
    "_freeaddrinfo" = "system_info";
    "_gai_strerror" = "system_info";
    "_getaddrinfo" = "system_info";
    "_freeifaddrs" = "system_info";
    "_getifaddrs" = "system_info";
    "_getpwuid" = "system_info";
    "_setgroupent" = "system_info";
    "_setpassent" = "system_info";
    "_getpwnam" = "system_info";
    "_getgrgid" = "system_info";
    "_getgrnam" = "system_info";
    "_getdomainname" = "system_info";
    "_innetgr" = "system_info";
    "_environ" = "dyld";
    "_dlclose" = "dyld";
    "_dlerror" = "dyld";
    "_dlopen" = "dyld";
    "_dlsym" = "dyld";
    "_pam_acct_mgmt" = "pam";
    "_pam_authenticate" = "pam";
    "_pam_chauthtok" = "pam";
    "_pam_close_session" = "pam";
    "_pam_end" = "pam";
    "_pam_get_item" = "pam";
    "_pam_getenvlist" = "pam";
    "_pam_open_session" = "pam";
    "_pam_set_data" = "pam";
    "_pam_set_item" = "pam";
    "_pam_setcred" = "pam";
    "_pam_start" = "pam";
    "_pam_strerror" = "pam";
    "_rootless_check_trusted_fd" = "system_darwin";
  };
in
mkCmds {
  pname = "sudo";
  src = sources.sudo;
  inherit toolchain;
  sourceLists = {
    # sudo_printf.c is a fallback in Apple's sudoers archive. The policy
    # object supplies that symbol in sudo; visudo needs the fallback.
    sudo = lib.filter (f: f != "sudo/plugins/sudoers/sudo_printf.c")
      (lib.unique (lists.sudo ++ [ "sudo/src/intercept.pb-c.c" ] ++ util ++ parser ++ policy));
    visudo = lib.unique (lists.visudo ++ util ++ parser);
  };
  tools = {
    sudo = {
      inherit allowUndefined;
      libraries = [{ pkg = zlib; l = "z"; }];
      man = {
        "sudo/docs/sudo.man" = "/usr/share/man/man8/sudo.8";
        "sudo/docs/sudoers.man" = "/usr/share/man/man5/sudoers.5";
        "sudo/docs/sudo.conf.man" = "/usr/share/man/man5/sudo.conf.5";
      };
      links."/usr/bin/sudoedit" = "/usr/bin/sudo";
    };
    visudo = {
      allowUndefined = {
        "_getgrouplist_2" = "system_info";
        "_getgrouplist" = "system_info";
        "_getpwuid" = "system_info";
        "_getpwnam" = "system_info";
        "_getgrgid" = "system_info";
        "_getgrnam" = "system_info";
        "_innetgr" = "system_info";
        "_getdomainname" = "system_info";
      };
      installDir = "/usr/sbin";
      man = { "sudo/docs/visudo.man" = "/usr/share/man/man8/visudo.8"; };
    };
  };
  # Dynamic library validation is retained. MDM and EndpointSecurity require
  # unreleased private framework headers and are not enabled in this build.
  defines = [ "__APPLE_DYNAMIC_LV__" "SUDOERS_UID=0" "SUDOERS_GID=0" "SUDOERS_MODE=0440" ];
  cflags = [
    "-std=gnu99"
    "-Os"
    "-fno-common"
    "-Isudo"
    "-Isudo/include"
    "-Isudo/plugins/sudoers"
    "-Isudo/src"
    "-Isudo/lib/eventlog"
    "-Isudo/lib/protobuf-c"
    "-I${authHeaders}"
    "-I${zlib}/usr/include"
    "-iwithsysroot"
    "/System/Library/Frameworks/System.framework/PrivateHeaders"
  ];
  ldflags = [ "-Wl,-dead_strip" ];
  postPatch = ''
    # No configure step: use Apple's checked-in headers and Xcode lists.
    rm sudo/scripts/ltmain.sh
    for f in sudo/lib/util/sudo_conf.c sudo/lib/util/sudo_dso.c \
      sudo/lib/eventlog/eventlog.c sudo/lib/iolog/iolog_openat.c \
      sudo/plugins/sudoers/defaults.c; do
      substituteInPlace "$f" --replace-fail '<System/sys/codesign.h>' '<sys/codesign.h>'
    done
    substituteInPlace sudo/plugins/sudoers/audit.c \
      --replace-fail '#ifdef __APPLE__' '#ifdef __APPLE_AUDIT__'
  '';
  extraInstall = ''
    install -Dm644 files/sudoers $out/private/etc/sudoers
    install -Dm644 files/sudo_lecture $out/private/etc/sudo_lecture
    install -Dm644 pam.d/sudo $out/private/etc/pam.d/sudo
    install -Dm644 pam.d/sudo_local.template $out/private/etc/pam.d/sudo_local.template
    mkdir -p $out/private/etc/sudoers.d
    install -Dm644 sudo/LICENSE.md $out/usr/share/licenses/sudo/LICENSE.md
  '';
}
