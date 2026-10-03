# Only headers, private to top's build. Framework implementations are absent.
{ runCommand, sources }:

runCommand "top-framework-headers" { } ''
  mkdir -p $out/CoreFoundation $out/IOKit/storage
  cp ${sources.CF}/*.h $out/CoreFoundation/
  chmod u+w $out/CoreFoundation/CoreFoundation.h
  # top needs these public APIs. Avoid the full umbrella's unrelated
  # CFStream/CFBundle dependencies on unreleased SDK headers.
  cat > $out/CoreFoundation/CoreFoundation.h <<'EOF'
  #include <CoreFoundation/CFBase.h>
  #include <CoreFoundation/CFDictionary.h>
  #include <CoreFoundation/CFNumber.h>
  #include <CoreFoundation/CFString.h>
  EOF
  cp ${sources.IOKitUser}/IOKitLib.h $out/IOKit/
  cp ${sources.IOStorageFamily}/IOBlockStorageDriver.h $out/IOKit/storage/
''
