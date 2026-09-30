#include "mdpkg.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char usage[] =
    "usage: mdpkg inspect --pkg FILE\n"
    "       mdpkg install --pkg FILE --root DIRECTORY "
    "[--script-runner EXECUTABLE]\n"
    "       mdpkg --version\n";

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

int main(int argc, char **argv) {
  if (argc == 2 && (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h"))) {
    fputs(usage, stdout);
    return 0;
  }
  if (argc == 2 && !strcmp(argv[1], "--version")) {
    puts("mdpkg " MDPKG_VERSION);
    return 0;
  }
  int installing = argc > 1 && !strcmp(argv[1], "install");
  if (argc < 2 || (!installing && strcmp(argv[1], "inspect"))) {
    fputs(usage, stderr);
    return 2;
  }
  const char *package = NULL, *root = NULL, *runner = NULL;
  for (int i = 2; i < argc; i += 2) {
    const char **slot = !strcmp(argv[i], "--pkg")    ? &package
                        : !strcmp(argv[i], "--root") ? &root
                        : !strcmp(argv[i], "--script-runner") ? &runner
                                                              : NULL;
    if (!slot || *slot || i + 1 >= argc)
      die("unknown, duplicate or incomplete option: %s\n%s", argv[i], usage);
    *slot = argv[i + 1];
  }
  if (!package)
    die("--pkg is required");
  if (!installing && (root || runner))
    die("inspect takes only --pkg");
  if (installing && !root)
    die("--root is required");

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
