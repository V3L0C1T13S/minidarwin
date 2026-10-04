# VARIANT_DYLD_INCLUDE from Libc 1752.120.2; compiler flags from libc_dyld.
[
  { path = "darwin/subsystem.c"; }
  { path = "gen/FreeBSD/arc4random.c"; flags = "$(FreeBSD_CFLAGS)"; }
  { path = "gen/FreeBSD/closedir.c"; flags = "$(FreeBSD_CFLAGS) -DLIBC_ALIAS_CLOSEDIR -include gen/__dirent.h"; }
  { path = "gen/FreeBSD/getcwd.c"; flags = "$(FreeBSD_CFLAGS)"; }
  { path = "gen/FreeBSD/getpagesize.c"; flags = "$(FreeBSD_CFLAGS)"; }
  { path = "gen/FreeBSD/opendir.c"; flags = "$(FreeBSD_CFLAGS) -DLIBC_ALIAS___OPENDIR2 -DLIBC_ALIAS_OPENDIR -include gen/__dirent.h"; }
  { path = "gen/FreeBSD/readdir.c"; flags = "$(FreeBSD_CFLAGS) -include gen/__dirent.h"; }
  { path = "gen/FreeBSD/scandir.c"; flags = "$(FreeBSD_CFLAGS) -include gen/__dirent.h"; }
  { path = "gen/FreeBSD/sysctl.c"; flags = "$(FreeBSD_CFLAGS)"; }
  { path = "gen/FreeBSD/sysctlbyname.c"; flags = "$(FreeBSD_CFLAGS)"; }
  { path = "gen/FreeBSD/telldir.c"; flags = "$(FreeBSD_CFLAGS) -DLIBC_ALIAS__SEEKDIR -DLIBC_ALIAS_TELLDIR -include gen/__dirent.h"; }
  { path = "gen/FreeBSD/usleep.c"; flags = "$(FreeBSD_CFLAGS) -DLIBC_ALIAS_USLEEP"; }
  { path = "gen/dirfd.c"; }
  { path = "gen/nanosleep.c"; flags = "-DLIBC_ALIAS_NANOSLEEP"; }
  { path = "stdlib/FreeBSD/atexit.c"; flags = "$(FreeBSD_CFLAGS)"; }
  { path = "stdlib/FreeBSD/exit.c"; flags = "$(FreeBSD_CFLAGS)"; }
  { path = "stdlib/FreeBSD/heapsort.c"; flags = "$(FreeBSD_CFLAGS)"; }
  { path = "stdlib/FreeBSD/merge.c"; flags = "$(FreeBSD_CFLAGS)"; }
  { path = "stdlib/FreeBSD/qsort.c"; flags = "$(FreeBSD_CFLAGS)"; }
  { path = "stdlib/FreeBSD/realpath.c"; flags = "$(FreeBSD_CFLAGS) -DLIBC_ALIAS_REALPATH"; }
  { path = "string/FreeBSD/strdup.c"; flags = "$(FreeBSD_CFLAGS)"; }
  { path = "string/FreeBSD/strrchr.c"; flags = "$(FreeBSD_CFLAGS)"; }
  { path = "string/bcopy.c"; flags = "-momit-leaf-frame-pointer"; }
  { path = "string/strcat.c"; }
  { path = "sys/_libc_init.c"; }
  { path = "sys/gettimeofday.c"; }
]
