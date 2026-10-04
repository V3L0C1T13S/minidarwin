{ runCommand, python3, launchd, launchdBootstrap }:

runCommand "minidarwin-launchd-test" { nativeBuildInputs = [ python3 ]; } ''
  ${launchdBootstrap}/libexec/launchd-unit-test
  export MD_LAUNCHD=${launchdBootstrap}/bin/launchd
  export MD_LAUNCHCTL=${launchdBootstrap}/bin/launchctl
  python3 ${./test-launchd.py} -v
  test -x ${launchd}/sbin/launchd
  test -x ${launchd}/bin/launchctl
  mkdir -p $out
  ln -s ${launchd} $out/target
  echo "launchd checks passed" > $out/result
''
