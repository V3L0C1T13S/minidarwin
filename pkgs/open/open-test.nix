{ runCommand, python3, open, openBootstrap, launchdBootstrap }:

runCommand "minidarwin-open-test" { nativeBuildInputs = [ python3 ]; } ''
  export MD_OPEN=${openBootstrap}/bin/open
  export MD_OPEND=${openBootstrap}/libexec/opend
  export MD_OPEN_PLIST=${openBootstrap}/share/open/org.minidarwin.opend.plist
  export MD_LAUNCHD=${launchdBootstrap}/bin/launchd
  python3 ${./test-open.py} -v
  test -x ${open}/usr/bin/open
  test -x ${open}/usr/libexec/opend
  mkdir -p $out
  ln -s ${open} $out/target
  echo "open checks passed" > $out/result
''
