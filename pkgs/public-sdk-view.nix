# <minidarwin/public-sdk-view.h>: force-included by SDK consumers that are
# written against Apple's public SDK rather than built into libSystem. Defines
# the include guards of the private headers xnu includes only without
# MODULES_SUPPORTED, which the SDK keeps (it is unifdef'd -UMODULES_SUPPORTED
# for the libsystem members' sake). See scripts/public-sdk-view.py.
{ runCommand, python3, sources, sdkHeaders }:

runCommand "minidarwin-public-sdk-view" { nativeBuildInputs = [ python3 ]; } ''
  mkdir -p $out/include/minidarwin
  python3 ${../scripts/public-sdk-view.py} ${sources.xnu} ${sdkHeaders}/usr/include \
    > $out/include/minidarwin/public-sdk-view.h
''
