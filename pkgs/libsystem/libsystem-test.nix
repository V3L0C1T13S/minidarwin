# Stage 4 check: link executable against -lSystem only, assert no undefined symbols.
# Exercises platform memcpy and flsl differences from Apple layout.
{ lib
, stdenvNoCC
, writeText
, toolchain
, libSystem
, buildSupport
}:

let
  probe = writeText "libsystem-probe.c" ''
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <strings.h>
    #include <pthread.h>
    #include <dirent.h>
    #include <regex.h>
    #include <time.h>
    #include <errno.h>
    #include <fcntl.h>
    #include <unistd.h>
    #include <uuid/uuid.h>
    #include <sys/stat.h>
    #include <mach/mach.h>
    #include <mach/mach_time.h>
    #include <os/lock.h>
    #include <Block.h>
    #include <mach-o/getsect.h>

    /* stdio/heap/string (string funcs from libsystem_platform). */
    static int strings_and_heap(void) {
      char *buf = malloc(64);
      if (!buf) return 0;
      strlcpy(buf, "minidarwin", 64);
      memset(buf + 10, '!', 3);
      buf[13] = '\0';
      int n = snprintf(NULL, 0, "%s %zu %a", buf, strlen(buf), 0.5);
      char *dup = strdup(buf);
      n += (dup && strcmp(dup, buf) == 0) + (memchr(buf, '!', 13) != NULL) +
           (index(buf, 'd') != NULL) + (strstr(buf, "darwin") != NULL);
      free(dup);
      free(buf);
      return n;
    }

    /* qsort via flsl (only entry point with no released source). */
    static int cmp(const void *a, const void *b) {
      return *(const int *)a - *(const int *)b;
    }
    static int sorting(void) {
      int v[] = { 9, 3, 7, 1, 8, 2 };
      qsort(v, 6, sizeof(int), cmp);
      int key = 7;
      return bsearch(&key, v, 6, sizeof(int), cmp) != NULL;
    }

    /* pthread + os_unfair_lock. */
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static void *thread(void *arg) {
      os_unfair_lock_lock(&lock);
      int *n = arg;
      *n += 1;
      os_unfair_lock_unlock(&lock);
      return NULL;
    }
    static int threads(void) {
      pthread_t t;
      int n = 0;
      if (pthread_create(&t, NULL, thread, &n) != 0) return 0;
      pthread_join(t, NULL);
      return n;
    }

    /* blocks: _NSConcreteStackBlock + Block_copy. */
    static int blocks(void) {
      __block int x = 1;
      void (^b)(void) = ^{ x += 41; };
      void (^heap)(void) = Block_copy(b);
      heap();
      Block_release(heap);
      return x;
    }

    /* kernel (direct + via Libc). */
    static int kernel(void) {
      uint64_t t = mach_absolute_time();
      mach_port_t self = mach_task_self();
      struct stat st;
      int rc = stat("/", &st);
      DIR *d = opendir(".");
      int n = 0;
      if (d) { n = readdir(d) != NULL; closedir(d); }
      return (t != 0) + (self != MACH_PORT_NULL) + (rc == 0) + n;
    }

    /* time/regex/uuid + libmacho getsectiondata. */
    static int the_rest(void) {
      time_t now = time(NULL);
      struct tm tm;
      char when[64];
      localtime_r(&now, &tm);
      strftime(when, sizeof(when), "%Y", &tm);

      regex_t re;
      int n = 0;
      if (regcomp(&re, "^[0-9]+$", REG_EXTENDED) == 0) {
        n += regexec(&re, when, 0, NULL, 0) == 0;
        regfree(&re);
      }

      uuid_t u;
      char us[37];
      uuid_generate(u);
      uuid_unparse(u, us);

      unsigned long size = 0;
      extern const struct mach_header_64 __dso_handle;
      n += getsectiondata(&__dso_handle, "__TEXT", "__text", &size) != NULL;
      return n + (strlen(us) == 36);
    }

    int main(void) {
      int n = strings_and_heap() + sorting() + threads() + blocks() +
              kernel() + the_rest();
      fprintf(stdout, "minidarwin libSystem probe: %d\n", n);
      return n > 0 ? 0 : 1;
    }
  '';
in

stdenvNoCC.mkDerivation {
  pname = "minidarwin-libsystem-test";
  version = libSystem.version;

  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = [ toolchain ];

  buildPhase = ''
    runHook preBuild
    source ${buildSupport}

    echo "== compiling the probe"
    $CC -std=gnu11 -Wall -Werror -O1 -fblocks -c ${probe} -o probe.o

    echo "== linking an executable against -lSystem and nothing else"
    # Executable: -undefined error (default); sysroot provides libSystem via install names.
    $CC -o probe probe.o -lSystem

    md_verify_pure   probe
    md_verify_signed probe

    echo "== every undefined symbol must come from libSystem"
    # Undefined symbols are runtime imports; only libSystem is on link line.
    $NM -u probe | sort -u > undefined.txt
    echo "-- $(wc -l < undefined.txt | tr -d ' ') imports"
    [ -s undefined.txt ] || { echo "no imports at all -- suspicious" >&2; exit 1; }

    # Only _dyld_stub_binder (dyld) plus plain C symbols with optional $VARIANT suffix.
    grep -vE '^(_dyld_stub_binder|_[A-Za-z_][A-Za-z_0-9]*(\$[A-Za-z_0-9]+)?)$' \
      undefined.txt > unexpected.txt || true
    if [ -s unexpected.txt ]; then
      echo "unexpected imports:" >&2
      cat unexpected.txt >&2
      exit 1
    fi

    echo "== the only library it links is libSystem"
    deps=$($OTOOL -L probe | tail -n +2 | awk '{ print $1 }' | sort -u)
    echo "$deps"
    if [ "$deps" != "/usr/lib/libSystem.B.dylib" ]; then
      echo "the probe links something other than libSystem" >&2
      exit 1
    fi

    # Check platform-placed symbols (strlen/strcmp/index) and one per key library; flsl is internal to libsystem_c.
    echo "-- imports: $(tr '\n' ' ' < undefined.txt)"
    for s in _strlen _strcmp _index _qsort _malloc _pthread_create \
             __Block_copy _getsectiondata _mach_task_self_; do
      grep -qx -- "$s" undefined.txt || {
        echo "the probe no longer imports $s" >&2; exit 1; }
    done

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out
    cp probe undefined.txt $out/
    echo "stage 4 libSystem ok" > $out/result
  '';

  meta.description = "Links a C program against minidarwin's libSystem umbrella";
}
