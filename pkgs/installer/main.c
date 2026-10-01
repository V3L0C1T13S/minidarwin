#include "mdpkg.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char usage[] =
    "usage: mdpkg -pkg FILE -target DIRECTORY [-script-runner EXECUTABLE]\n"
    "       mdpkg -pkginfo -pkg FILE\n"
    "       mdpkg -vers\n"
    "\n"
    "  -pkg FILE               the flat package\n"
    "  -target DIRECTORY       the root to install into (also -root); \"/\" is\n"
    "                          the running root, installed into in place\n"
    "  -script-runner PROGRAM  run install scripts through PROGRAM; needed for\n"
    "                          any root but \"/\", where scripts run directly\n"
    "  -pkginfo                describe the package and install nothing\n"
    "\n"
    "The subcommands `mdpkg install` and `mdpkg inspect` take the same options.\n";

static void inspect(const Package *pkg) {
  for (size_t i = 0; i < pkg->count; i++) {
    const Component *c = &pkg->components[i];
    printf("%s %s /%s: %zu payload entries", c->identifier, c->version,
           c->location, c->payload.count);
    for (int h = 0; h < HOOK_COUNT; h++)
      if (c->hooks[h])
        printf("; script %s", hook_names[h]);
    putchar('\n');
  }
  if (pkg->host_architectures)
    printf("host architectures (not enforced): %s\n", pkg->host_architectures);
}

static int is(const char *arg, const char *name) {
  return !strcmp(arg, name);
}

int main(int argc, char **argv) {
  if (argc == 2 && (is(argv[1], "-help") || is(argv[1], "-h") ||
                    is(argv[1], "--help"))) {
    fputs(usage, stdout);
    return 0;
  }
  if (argc == 2 && (is(argv[1], "-vers") || is(argv[1], "-version") ||
                    is(argv[1], "--version"))) {
    puts("mdpkg " MDPKG_VERSION);
    return 0;
  }
  int first = 1, installing = 1, subcommand = 0, pkginfo = 0;
  if (argc > 1 && argv[1][0] != '-') {
    subcommand = 1;
    installing = is(argv[1], "install");
    if (!installing && !is(argv[1], "inspect")) {
      fputs(usage, stderr);
      return 2;
    }
    first = 2;
  }
  const char *package = NULL, *root = NULL, *runner = NULL;
  for (int i = first; i < argc; i++) {
    if (is(argv[i], "-pkginfo") && !pkginfo) {
      pkginfo = 1;
      continue;
    }
    const char **slot = is(argv[i], "-pkg")                ? &package
                        : is(argv[i], "-target") ||
                                  is(argv[i], "-root")     ? &root
                        : is(argv[i], "-script-runner")    ? &runner
                                                           : NULL;
    if (!slot || *slot || i + 1 >= argc)
      die("unknown, duplicate or incomplete option: %s\n%s", argv[i], usage);
    *slot = argv[++i];
  }
  if (pkginfo) {
    if (subcommand && installing)
      die("-pkginfo does not install");
    installing = 0;
  }
  if (!package)
    die("-pkg is required");
  if (!installing && (root || runner))
    die("inspecting takes only -pkg");
  if (installing && !root)
    die("-target is required");

  char package_path[PATH_MAX], runner_path[PATH_MAX];
  if (!realpath(package, package_path))
    die("%s: %s", package, strerror(errno));
  if (runner && (!realpath(runner, runner_path) || access(runner_path, X_OK)))
    die("script runner %s is not executable", runner);

  Package pkg;
  package_load(&pkg, package_path);
  if (installing)
    install_package(&pkg, root, runner ? runner_path : NULL);
  else
    inspect(&pkg);
  return 0;
}
