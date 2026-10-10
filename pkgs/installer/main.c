#include "mdpkg.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char usage[] =
    "usage: mdpkg -pkg FILE -target DIRECTORY [-script-runner EXECUTABLE]\n"
    "       mdpkg -pkginfo -pkg FILE [-target DIRECTORY]\n"
    "       mdpkg -vers\n"
    "\n"
    "  -pkg FILE               the flat package\n"
    "  -target DIRECTORY       the root to install into (also -root); \"/\" is\n"
    "                          the running root, installed into in place\n"
    "  -script-runner PROGRAM  run install scripts through PROGRAM; needed for\n"
    "                          any root but \"/\", where scripts run directly\n"
    "  -system-version X.Y     answer system.version.ProductVersion with X.Y\n"
    "                          instead of reading the host's SystemVersion.plist\n"
    "  -skip-scripts           install payloads and receipts; run no package\n"
    "                          scripts (none of them is checked or required)\n"
    "  -pkginfo                describe the package and install nothing\n"
    "                          optional -target resolves JavaScript read-only\n"
    "\n"
    "The subcommands `mdpkg install` and `mdpkg inspect` take the same options.\n";

static void inspect(const Package *pkg) {
  if (pkg->unresolved)
    puts("JavaScript selection unresolved: provide -target to evaluate checks and choices");
  for (size_t i = 0; i < pkg->count; i++) {
    const Component *c = &pkg->components[i];
    printf("%s %s /%s", c->identifier, c->version, c->location);
    if (c->metadata_only)
      printf(": candidate (selection unresolved)");
    else
      printf(": %zu payload entries", c->payload.count);
    for (int h = 0; h < HOOK_COUNT; h++)
      if (c->hooks[h])
        printf("; script %s", hook_names[h]);
    putchar('\n');
  }
  if (pkg->host_architectures)
    printf("host architectures (not enforced): %s\n", pkg->host_architectures);
  if (pkg->allowed_os_versions)
    printf("allowed OS versions (not enforced): %s\n", pkg->allowed_os_versions);
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
    if (is(argv[i], "-skip-scripts") && !opt_skip_scripts) {
      opt_skip_scripts = 1;
      continue;
    }
    if (is(argv[i], "-system-version") && !opt_system_version && i + 1 < argc) {
      const char *v = argv[++i];
      size_t n = strspn(v, "0123456789.");
      if (!n || v[n] || v[0] == '.' || v[n - 1] == '.' || strstr(v, ".."))
        die("-system-version must be a numeric dotted version: %s", v);
      opt_system_version = v;
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
  if (!installing && runner)
    die("inspecting does not take -script-runner");
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
  else {
    if (root) {
      char *target = inspect_target(root);
      package_resolve(&pkg, target, is_running_root(root));
      free(target);
    } else if (pkg.needs_js)
      package_inspect_candidates(&pkg);
    else
      package_resolve(&pkg, NULL, 0);
    inspect(&pkg);
  }
  return 0;
}
