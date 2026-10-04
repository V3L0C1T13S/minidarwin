# Stage a writable runtime filesystem for the source-built ext4 driver.
# `interactive` swaps the one-shot boot proof (what `bootTest` checks) for a
# console shell that launchd restarts when it exits.
{ runCommand, python3, e2fsprogs, bootRootfs, interactive ? false }:
let
  job = if interactive then ''
    <key>Label</key><string>org.minidarwin.console-shell</string>
    <key>ProgramArguments</key><array>
      <string>/bin/sh</string><string>-c</string>
      <string>/usr/bin/uname -a; exec /bin/sh -i</string>
    </array>
    <key>EnvironmentVariables</key><dict>
      <key>TERM</key><string>xterm</string>
      <key>HOME</key><string>/</string>
    </dict>
    <key>WorkingDirectory</key><string>/</string>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>1</integer>
    <key>StandardInPath</key><string>/dev/console</string>
  '' else ''
    <key>Label</key><string>org.minidarwin.boot-proof</string>
    <key>ProgramArguments</key><array>
      <string>/bin/sh</string><string>-c</string>
      <string>/usr/bin/uname -a &amp;&amp; printf 'MiniDarwin: userland boot complete\n'</string>
    </array>
  '';
in
runCommand "minidarwin-boot-root-partition"
{ nativeBuildInputs = [ python3 e2fsprogs ]; } ''
  cp -R ${bootRootfs}/. root
  chmod -R u+w root
  mkdir -p root/dev root/private/tmp root/private/var/{run,log,tmp} \
    root/System/Library/LaunchDaemons root/Library/LaunchDaemons $out
  ln -s private/var root/var
  ln -s private/tmp root/tmp
  chmod 1777 root/private/tmp root/private/var/tmp
  if [ ! -e root/bin/sh ]; then ln -s bash root/bin/sh; fi
  test -x root/bin/sh
  test -x root/usr/bin/uname
  test -x root/sbin/launchd
  test -x root/usr/lib/dyld
  cat > root/System/Library/LaunchDaemons/org.minidarwin.boot-proof.plist <<'PLIST'
  <?xml version="1.0" encoding="UTF-8"?>
  <plist version="1.0"><dict>
    ${job}
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>/dev/console</string>
    <key>StandardErrorPath</key><string>/dev/console</string>
  </dict></plist>
  PLIST
  find root -exec touch -h -t 198001010000.00 {} +
  size=$(du -sk root | cut -f1)
  truncate -s "$(( (size * 5 / 4 / 1024 + 128) * 1024 * 1024 ))" $out/root.ext4
  export E2FSPROGS_FAKE_TIME=315532800
  mke2fs -q -t ext4 -F -b 4096 -I 256 -m 0 \
    -U da41c826-7cac-4870-90ee-12b31d14b270 -L MiniDarwin \
    -O ^64bit,^metadata_csum,^orphan_file,^has_journal \
    -E root_owner=0:0,hash_seed=da41c826-7cac-4870-90ee-12b31d14b270,lazy_itable_init=0,lazy_journal_init=0 \
    -d root $out/root.ext4
  # mke2fs preserves input ownership. Normalize every inode, including symlinks,
  # rather than inheriting the Nix builder's UID in the guest filesystem.
  python3 ${./normalize-ext4.py} root $out/root.ext4
  e2fsck -fn $out/root.ext4
''
