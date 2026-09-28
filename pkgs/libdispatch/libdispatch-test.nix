# Link-only probe: dyld is not shipped yet, so target programs cannot run.
{ stdenvNoCC
, writeText
, toolchain
, libSystem
, copyfile
, buildSupport
}:

let
  probe = writeText "libdispatch-probe.c" ''
    #include <dispatch/dispatch.h>

    static void run(void *context) { (void)context; }

    int main(void) {
      static dispatch_once_t once;
      dispatch_once(&once, ^{ });

      dispatch_queue_t queue = dispatch_queue_create("minidarwin.test", NULL);
      dispatch_group_t group = dispatch_group_create();
      dispatch_group_async_f(group, queue, NULL, run);
      dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      dispatch_semaphore_signal(sem);
      dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

      dispatch_io_t io = dispatch_io_create(DISPATCH_IO_STREAM, -1, queue,
          ^(int error) { (void)error; });
      dispatch_io_close(io, 0);
      dispatch_release(io);
      dispatch_release(sem);
      dispatch_release(group);
      dispatch_release(queue);
      return 0;
    }
  '';
in

stdenvNoCC.mkDerivation {
  pname = "minidarwin-libdispatch-test";
  version = libSystem.version;
  dontUnpack = true;
  dontFixup = true;
  nativeBuildInputs = [ toolchain ];

  buildPhase = ''
    runHook preBuild
    source ${buildSupport}

    $CC -fblocks -O0 ${probe} -o probe -lSystem
    md_verify_pure probe
    md_verify_signed probe

    for symbol in _dispatch_once _dispatch_queue_create \
      _dispatch_group_create _dispatch_group_async_f _dispatch_group_wait \
      _dispatch_semaphore_create _dispatch_semaphore_signal \
      _dispatch_semaphore_wait _dispatch_io_create; do
      $NM -u probe | grep -qx "$symbol" || {
        echo "probe does not import $symbol" >&2; exit 1; }
    done

    # copyfile must now import libdispatch's initializer, not define one.
    $NM -u ${copyfile}/usr/lib/libcopyfile.dylib | grep -qx _dispatch_once || {
      echo "copyfile does not import dispatch_once" >&2; exit 1; }
    if $NM --defined-only ${copyfile}/usr/lib/libcopyfile.dylib |
      grep -q ' _dispatch_once$'; then
      echo "copyfile still defines dispatch_once" >&2
      exit 1
    fi
    md_verify_reexports ${libSystem}/usr/lib/libSystem.B.dylib \
      /usr/lib/system/libdispatch.dylib

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out
    cp probe $out/
    echo "libdispatch link and copyfile import ok" > $out/result
  '';
}
