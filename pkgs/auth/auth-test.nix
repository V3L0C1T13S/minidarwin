# Inspect authentication and policy paths without executing target programs.
{ runCommand, su, sudo, targetArch }:
runCommand "minidarwin-auth-test-${sudo.version}"
{ nativeBuildInputs = [ sudo.toolchain ]; }
  ''
    set -euo pipefail
    mkdir -p "$out"
    for f in ${su}/usr/bin/su ${sudo}/usr/bin/sudo ${sudo}/usr/sbin/visudo; do
      test -x "$f"
      # The rootfs format currently ships ordinary executables, without setuid.
      test ! -u "$f"
      $LIPO "$f" -verify_arch ${if targetArch == "aarch64" then "arm64" else "x86_64"}
      $NM -u "$f" | awk '{ print $NF }' | sort -u > "$out/$(basename "$f").imports"
    done
    for tool in su sudo; do
      for symbol in _pam_start _pam_authenticate _pam_acct_mgmt _pam_setcred \
        _pam_open_session _pam_close_session _setuid _setgid; do
        grep -qx -- "$symbol" "$out/$tool.imports"
      done
    done
    grep -qx _audit_submit "$out/su.imports"
    grep -qx _rootless_restricted_environment "$out/su.imports"
    grep -qx _rootless_check_trusted_fd "$out/sudo.imports"
    $NM --defined-only ${sudo}/usr/bin/sudo | awk '{ print $NF }' | sort -u > "$out/sudo.definitions"
    # sudo's static policy, PAM backend, PTY execution and command interception
    # must be linked, including the generated protobuf serialization code.
    for symbol in _sudoers_policy _sudoers_check_cmnd _sudo_pam_verify \
      _exec_pty _intercept_request__unpack; do
      grep -qx -- "$symbol" "$out/sudo.definitions"
    done
    test "$(readlink ${sudo}/usr/bin/sudoedit)" = sudo
    for f in sudoers sudo_lecture pam.d/sudo pam.d/sudo_local.template; do
      test -s "${sudo}/private/etc/$f"
    done
    test -s ${su}/private/etc/pam.d/su
    grep -q 'pam_opendirectory.so' ${su}/private/etc/pam.d/su
    grep -q 'pam_opendirectory.so' ${sudo}/private/etc/pam.d/sudo
    test -s ${su}/usr/share/man/man1/su.1
    test -s ${sudo}/usr/share/man/man8/sudo.8
    test -s ${sudo}/usr/share/man/man8/visudo.8
    test -s ${sudo}/usr/share/man/man5/sudoers.5
    $OTOOL -L ${sudo}/usr/bin/sudo | tail -n +2 | awk '{ print $1 }' | sort -u > "$out/sudo.deps"
    cat > expected <<'EOF'
    /usr/lib/libSystem.B.dylib
    /usr/lib/libz.1.dylib
    EOF
    diff -u expected "$out/sudo.deps"
  ''
