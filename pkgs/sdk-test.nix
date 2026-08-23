# SDK smoke test: parses one header from each SDK project and checks include path.
{ lib, stdenvNoCC, writeText, toolchain, sdkHeaders }:

let
  probe = writeText "sdk-probe.c" ''
    /* one header per SDK project */
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <unistd.h>
    #include <errno.h>
    #include <fcntl.h>
    #include <signal.h>
    #include <time.h>
    #include <locale.h>
    #include <wchar.h>
    #include <math.h>
    #include <complex.h>
    #include <fenv.h>
    #include <sys/syscall.h>
    #include <sys/mman.h>
    #include <sys/socket.h>
    #include <sys/event.h>
    #include <sys/attr.h>
    #include <netinet/in.h>
    #include <mach/mach.h>
    #include <mach/task.h>
    #include <mach/thread_act.h>
    #include <mach/vm_map.h>
    #include <mach/mach_vm.h>
    #include <mach/mach_port.h>
    #include <mach/mach_time.h>
    #include <mach/host_priv.h>
    #include <mach/processor_set.h>
    #include <mach/exc.h>
    #include <pthread.h>
    #include <pthread/qos.h>
    #include <malloc/malloc.h>
    #include <os/lock.h>
    #include <os/base.h>
    #include <libkern/OSAtomic.h>
    #include <libkern/OSByteOrder.h>
    #include <Block.h>
    #include <dispatch/dispatch.h>
    #include <dlfcn.h>
    #include <mach-o/dyld.h>
    #include <mach-o/loader.h>
    #include <mach-o/nlist.h>
    #include <copyfile.h>
    #include <removefile.h>
    #include <notify.h>
    #include <libutil.h>
    #include <resolv.h>
    #include <Availability.h>
    #include <AvailabilityMacros.h>
    #include <os/availability.h>
    #include <TargetConditionals.h>

    _Static_assert(sizeof(void *) == 8, "expected an LP64 target");
    _Static_assert(TARGET_OS_MAC == 1, "TargetConditionals disagrees");
    _Static_assert(sizeof(struct mach_header_64) == 32, "mach_header_64 layout");
    _Static_assert(SYS_write > 0, "syscall.h was not generated");

    /* exercise mig + availability */
    kern_return_t probe_mach(task_t t, vm_address_t *a);
    kern_return_t probe_mach(task_t t, vm_address_t *a) {
      return vm_allocate(t, a, 4096, 1);
    }

    int probe_dispatch(void);
    int probe_dispatch(void) {
      dispatch_queue_t q = dispatch_get_main_queue();
      return q != NULL;
    }
  '';
in

stdenvNoCC.mkDerivation {
  pname = "minidarwin-sdk-test";
  version = sdkHeaders.version;

  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = [ toolchain ];

  buildPhase = ''
    runHook preBuild

    echo "== include search path"
    paths=$($CC -E -v -x c /dev/null 2>&1 |
            sed -n '/#include <\.\.\.>/,/End of search/p' |
            grep '^ /')
    echo "$paths"

    # Must be store paths only (no host SDK).
    if echo "$paths" | grep -vq '^ /nix/store/'; then
      echo "IMPURE: non-store directory on the include search path" >&2
      exit 1
    fi
    if [ "$(echo "$paths" | wc -l)" -ne 2 ]; then
      echo "unexpected number of include directories (want clang builtins + sysroot)" >&2
      exit 1
    fi

    echo "== compiling the probe (C)"
    $CC -std=gnu17 -Wall -c ${probe} -o probe.o

    echo "== compiling the probe (C++)"
    $CXX -std=gnu++20 -fsyntax-only -x c++ ${probe}

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out
    cp probe.o $out/
    echo "sdk ok" > $out/result
  '';

  meta.description = "Parses one header from every project in the minidarwin SDK";
}
