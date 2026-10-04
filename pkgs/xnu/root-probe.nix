# A filesystem fixture for root mounting, deliberately without a PID 1 binary.
{ runCommand, e2fsprogs }:
runCommand "minidarwin-root-mount-fixture"
{ nativeBuildInputs = [ e2fsprogs ]; } ''
  mkdir -p root/dev root/private/etc root/sbin $out
  echo 'MiniDarwin root mount fixture' > root/boot-proof
  find root -exec touch -h -t 198001010000.00 {} +
  truncate -s 64M $out/root.ext4
  export E2FSPROGS_FAKE_TIME=315532800
  mke2fs -q -t ext4 -F -b 4096 -I 256 -m 0 \
    -U da41c826-7cac-4870-90ee-12b31d14b270 -L MiniDarwin \
    -O ^64bit,^metadata_csum,^orphan_file,^has_journal \
    -E root_owner=0:0,hash_seed=da41c826-7cac-4870-90ee-12b31d14b270,lazy_itable_init=0,lazy_journal_init=0 \
    -d root $out/root.ext4
  e2fsck -fn $out/root.ext4
''
