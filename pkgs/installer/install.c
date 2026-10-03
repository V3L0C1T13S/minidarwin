/* Installing into an offline root, as a transaction:
 *
 *   ROOT.mdpkg-lock           flock()ed for the duration; kept afterwards
 *   ROOT.mdpkg-transaction/   0700, created once preflight has passed
 *     target                  ROOT, so a stale transaction is never misapplied
 *     new/                    private copy of ROOT; payloads and scripts land here
 *     original/               ROOT itself, moved aside during publication
 *
 * Publication is rename(ROOT, original) then rename(new, ROOT). A transaction
 * interrupted between the two is rolled back (original/ is put back) by the
 * next invocation; one interrupted after both is completed. The original is
 * only deleted once the new tree is in place. Nothing guards against other
 * processes using ROOT meanwhile: roots are offline.
 *
 * The running root cannot be swapped, so installing into it is different: it
 * is done in place, with no copy. Nothing is replaced (preflight has already
 * refused collisions), every directory, file and link created is journalled,
 * and a failure removes what the journal holds. What scripts did is not
 * undone, and nor is a crash. */
#include "mdpkg.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/clonefile.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <unistd.h>

static struct {
  char *root, *parent, *dir, *stage, *original;
  int published, live;
} tx;

static char **journal; /* host paths created in a live install */
static size_t journal_count;
static char *live_tmp; /* script work area of a live install */

static EntryList base_directories; /* modes and times to restore in stage */

/* Best-effort removal for rollback paths, where dying is not an option. */
static int remove_tree(const char *path, int depth) {
  struct stat st;
  if (lstat(path, &st))
    return errno == ENOENT ? 0 : -1;
  if (!S_ISDIR(st.st_mode))
    return unlink(path);
  if (depth > LIMIT_DEPTH || chmod(path, (st.st_mode & 07777) | S_IRWXU))
    return -1;
  DIR *d = opendir(path);
  if (!d)
    return -1;
  int status = 0;
  for (struct dirent *e; (e = readdir(d));) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
      continue;
    char child[PATH_MAX];
    if (snprintf(child, sizeof(child), "%s/%s", path, e->d_name) >=
            (int)sizeof(child) ||
        remove_tree(child, depth + 1))
      status = -1;
  }
  closedir(d);
  return status || rmdir(path) ? -1 : 0;
}

static void remove_or_die(const char *path) {
  if (remove_tree(path, 0))
    die("cannot remove %s", path);
}

static void sync_dir(const char *path) {
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  if (fd < 0 || (fsync(fd) && errno != EINVAL))
    die("sync %s: %s", path, strerror(errno));
  close(fd);
}

/* die() hook: leave ROOT as it was, or as published. */
static void rollback(void) {
  struct stat st;
  if (!tx.published && !lstat(tx.original, &st) && lstat(tx.root, &st) &&
      rename(tx.original, tx.root)) {
    fprintf(stderr, "mdpkg: original root retained at %s; rerun to recover\n",
            tx.original);
    return;
  }
  if (remove_tree(tx.dir, 0))
    fprintf(stderr, "mdpkg: could not remove %s\n", tx.dir);
}

static void recover(void) {
  struct stat st;
  if (lstat(tx.dir, &st) || !S_ISDIR(st.st_mode) || st.st_uid != geteuid() ||
      (st.st_mode & 0777) != 0700)
    die("unsafe transaction directory: %s", tx.dir);
  char *marker = path_join(tx.dir, "target");
  Bytes target = file_read(marker, PATH_MAX);
  if (target.len != strlen(tx.root) || memcmp(target.data, tx.root, target.len))
    die("transaction %s belongs to another root", tx.dir);
  free(target.data);
  free(marker);
  if (path_exists(tx.original)) {
    if (!path_exists(tx.root)) {
      if (rename(tx.original, tx.root))
        die("cannot restore %s: %s", tx.root, strerror(errno));
      fputs("mdpkg: rolled back an interrupted publication\n", stderr);
    } else if (lstat(tx.root, &st) || !S_ISDIR(st.st_mode))
      die("unsafe published root: %s", tx.root);
    else
      fputs("mdpkg: completed an interrupted publication\n", stderr);
  }
  remove_or_die(tx.dir);
  sync_dir(tx.parent);
}

static void lock_and_recover(const char *requested) {
  /* Canonicalize the parent only, so a symlinked ROOT is still refused. */
  char *absolute;
  if (*requested == '/')
    absolute = xstrdup(requested);
  else {
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd)))
      die("getcwd: %s", strerror(errno));
    absolute = path_join(cwd, requested);
  }
  for (size_t n = strlen(absolute); n > 1 && absolute[n - 1] == '/';)
    absolute[--n] = 0;
  const char *name = strrchr(absolute, '/') + 1;
  if (!*name || !strcmp(name, ".") || !strcmp(name, ".."))
    die("refusing root %s", requested);
  char *parent = path_parent(absolute), resolved[PATH_MAX];
  if (!realpath(parent, resolved))
    die("root parent %s: %s", parent, strerror(errno));
  tx.parent = xstrdup(resolved);
  tx.root = path_join(tx.parent, name);
  free(parent);
  free(absolute);
  if (path_has_prefix(tx.root, "/nix/store"))
    die("refusing a Nix store destination");

  char lock_path[PATH_MAX];
  snprintf(lock_path, sizeof(lock_path), "%s.mdpkg-lock", tx.root);
  int fd = open(lock_path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
  struct stat st;
  if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) ||
      st.st_uid != geteuid() || st.st_nlink != 1)
    die("unsafe lock file %s", lock_path);
  if (flock(fd, LOCK_EX | LOCK_NB))
    die("%s is locked by another mdpkg", tx.root);
  /* The descriptor stays open, and the lock held, until exit. */

  char dir[PATH_MAX];
  snprintf(dir, sizeof(dir), "%s.mdpkg-transaction", tx.root);
  tx.dir = xstrdup(dir);
  tx.stage = path_join(tx.dir, "new");
  tx.original = path_join(tx.dir, "original");
  if (path_exists(tx.dir))
    recover();
  if (lstat(tx.root, &st) || !S_ISDIR(st.st_mode) ||
      access(tx.root, R_OK | X_OK) || access(tx.parent, W_OK))
    die("root must be a real, readable directory with a writable parent");
}

/* Resolves REL beneath BASE as the kernel would, following symlinks, but
 * refuses to leave BASE: ".." above it, an absolute symlink, or a loop.
 * Missing components are taken literally. A final symlink is followed only
 * with FOLLOW_LAST. The result has no symlink components, so writes to it
 * pass path_parents(). */
char *resolve_target_path(const char *base, const char *rel,
                          int follow_last, int live) {
  char *done = xstrdup(""), *todo = xstrdup(rel);
  int hops = 0;
  while (*todo) {
    size_t n = strcspn(todo, "/");
    char *name = xstrndup(todo, n), *rest = xstrdup(todo + n + !!todo[n]);
    free(todo);
    todo = rest;
    if (!*name || !strcmp(name, ".")) {
      free(name);
      continue;
    }
    if (!strcmp(name, "..")) {
      if (!*done)
        die("%s leaves the root", rel);
      char *up = path_parent(done);
      free(done);
      done = up;
      free(name);
      continue;
    }
    char *next = path_join(done, name), *host = path_join(base, next);
    free(name);
    struct stat st;
    int missing = lstat(host, &st) != 0;
    if (missing && errno != ENOENT)
      die("stat %s: %s", host, strerror(errno));
    if (!missing && S_ISLNK(st.st_mode) && (*todo || follow_last)) {
      if (++hops > LIMIT_SYMLINK_HOPS)
        die("too many symlinks resolving %s", rel);
      char target[PATH_MAX];
      ssize_t len = readlink(host, target, sizeof(target) - 1);
      if (len < 0)
        die("readlink %s: %s", host, strerror(errno));
      target[len] = 0;
      const char *relative = target;
      if (*target == '/') {
        /* In the running root an absolute link points inside it. */
        if (!live)
          die("%s passes through an absolute symlink: %s", rel, next);
        while (*relative == '/')
          relative++;
        free(done);
        done = xstrdup("");
        free(next);
        next = NULL;
      }
      char *spliced = path_join(relative, todo);
      free(todo);
      todo = spliced;
      free(next);
    } else {
      if (!missing && *todo && !S_ISDIR(st.st_mode))
        die("not a directory: %s", next);
      free(done);
      done = next;
    }
    free(host);
  }
  free(todo);
  return done;
}

static char *resolve_beneath(const char *base, const char *rel, int follow_last) {
  return resolve_target_path(base, rel, follow_last, tx.live);
}

static int is_reserved(const char *path) {
  return path_has_prefix(path, RECEIPTS_DIR) ||
         path_has_prefix(path, INVENTORY_DIR) ||
         path_has_prefix(path, SCRIPTS_DIR);
}

/* Payload paths follow the root's existing symlinks, as Apple's installer
 * does: a package's /etc/x lands in /private/etc/x when /etc is a link. The
 * directory entry /etc itself then describes the directory it points to. */
static void place_payload(Package *pkg) {
  EntryList all = {0};
  for (size_t i = 0; i < pkg->count; i++) {
    EntryList *payload = &pkg->components[i].payload;
    for (size_t j = 0; j < payload->count; j++) {
      Entry *e = &payload->items[j];
      char *placed;
      if (S_ISDIR(e->mode))
        placed = resolve_beneath(tx.root, e->path, 1);
      else {
        char *parent = path_parent(e->path),
             *resolved = resolve_beneath(tx.root, parent, 1);
        placed = path_join(resolved, strrchr(e->path, '/')
                                         ? strrchr(e->path, '/') + 1
                                         : e->path);
        free(parent);
        free(resolved);
      }
      if (strcmp(placed, e->path)) {
        e->package_path = e->path;
        e->path = placed;
      } else
        free(placed);
      if (is_reserved(e->path))
        die("payload writes to a path mdpkg reserves: %s", e->path);
      entries_append(&all, *e);
    }
  }
  entries_check_paths(&all, 1);
  free(all.items);
}

static void preflight(Package *pkg, const char *runner) {
  place_payload(pkg);
  for (size_t i = 0; i < pkg->count; i++) {
    Component *c = &pkg->components[i];
    for (int h = 0; h < HOOK_COUNT; h++)
      if (c->hooks[h] && !runner && !tx.live)
        die("%s has a %s script; an offline root needs an isolating "
            "-script-runner (scripts run directly only in the running root)",
            c->identifier, hook_names[h]);
    const char *records[][2] = {{RECEIPTS_DIR, ".plist"},
                                {RECEIPTS_DIR, ".bom"},
                                {INVENTORY_DIR, ".inventory.plist"}};
    for (size_t r = 0; r < 3; r++) {
      char rel[PATH_MAX];
      snprintf(rel, sizeof(rel), "%s/%s%s", records[r][0], c->identifier,
               records[r][1]);
      path_parents(tx.root, rel, 0);
      char *host = path_join(tx.root, rel);
      if (path_exists(host))
        die("%s is already installed (%s exists)", c->identifier, rel);
      free(host);
    }
    for (size_t j = 0; j < c->payload.count; j++) {
      Entry *e = &c->payload.items[j];
      if (!*e->path)
        continue;
      path_parents(tx.root, e->path, 0);
      char *host = path_join(tx.root, e->path);
      struct stat st;
      if (!lstat(host, &st) && !(S_ISDIR(e->mode) && S_ISDIR(st.st_mode)))
        die("payload would replace an existing file: /%s", e->path);
      free(host);
    }
  }
  char *scripts = path_join(tx.root, SCRIPTS_DIR);
  if (path_exists(scripts))
    die("reserved path exists in root: /%s", SCRIPTS_DIR);
  free(scripts);
}

static void apply_ownership(const char *path, uid_t uid, gid_t gid,
                            int is_symlink) {
  static int warned;
  if (geteuid() == 0) {
    if (is_symlink ? lchown(path, uid, gid) : chown(path, uid, gid))
      die("chown %s: %s", path, strerror(errno));
  } else if ((uid != geteuid() || gid != getegid()) && !warned) {
    fputs("mdpkg: unprivileged install: files are owned by the installing "
          "user; requested ownership is recorded in the inventory\n",
          stderr);
    warned = 1;
  }
}

static void set_times(const char *path, struct timespec atime,
                      struct timespec mtime, int is_symlink) {
  struct timespec times[2] = {atime, mtime};
  if (utimensat(AT_FDCWD, path, times, is_symlink ? AT_SYMLINK_NOFOLLOW : 0))
    die("set times on %s: %s", path, strerror(errno));
}

/* com.apple.provenance is attached by the kernel to files a process
 * creates on current macOS; it records who wrote the file and is not part of
 * the root's content, so losing it in the copy loses nothing. */
static int has_xattrs(const char *path) {
  char names[4096];
  ssize_t n = listxattr(path, names, sizeof(names), XATTR_NOFOLLOW);
  if (n < 0)
    return errno != ENOTSUP;
  for (ssize_t i = 0; i < n; i += (ssize_t)strlen(names + i) + 1)
    if (strcmp(names + i, "com.apple.provenance"))
      return 1;
  return 0;
}

/* Copies ROOT to the stage. Files are APFS clones where possible: separate,
 * writable copies that share blocks until written, never hard links. Base
 * directories are made writable while staging and restored at the end.
 * Metadata the copy would lose (flags, xattrs, ACLs) is refused instead. */
static void stage_copy(const char *from, const char *to, const char *rel,
                       int depth) {
  if (depth > LIMIT_DEPTH)
    die("root nesting limit");
  struct stat st;
  if (lstat(from, &st))
    die("stat %s: %s", from, strerror(errno));
  if (st.st_flags || has_xattrs(from))
    die("root entry has flags or extended attributes: %s", from);
  if (S_ISDIR(st.st_mode)) {
    if (mkdir(to, 0700))
      die("mkdir %s: %s", to, strerror(errno));
    entries_append(&base_directories,
                   (Entry){.path = xstrdup(rel), .mode = st.st_mode,
                           .mtime = st.st_mtime});
    DIR *d = opendir(from);
    if (!d)
      die("opendir %s: %s", from, strerror(errno));
    for (struct dirent *e; (e = readdir(d));) {
      if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
        continue;
      char *a = path_join(from, e->d_name), *b = path_join(to, e->d_name),
           *r = path_join(rel, e->d_name);
      stage_copy(a, b, r, depth + 1);
      free(a);
      free(b);
      free(r);
    }
    closedir(d);
    apply_ownership(to, st.st_uid, st.st_gid, 0);
    if (chmod(to, (st.st_mode & 07777) | S_IRWXU))
      die("chmod %s: %s", to, strerror(errno));
  } else if (S_ISREG(st.st_mode)) {
    if (clonefile(from, to, CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) {
      if (errno != ENOTSUP && errno != EXDEV)
        die("clone %s: %s", from, strerror(errno));
      file_copy(from, to, st.st_mode);
      set_times(to, st.st_atimespec, st.st_mtimespec, 0);
    }
    apply_ownership(to, st.st_uid, st.st_gid, 0);
  } else if (S_ISLNK(st.st_mode)) {
    char target[PATH_MAX];
    ssize_t n = readlink(from, target, sizeof(target) - 1);
    if (n < 0)
      die("readlink %s: %s", from, strerror(errno));
    target[n] = 0;
    if (symlink(target, to))
      die("symlink %s: %s", to, strerror(errno));
    apply_ownership(to, st.st_uid, st.st_gid, 1);
    set_times(to, st.st_atimespec, st.st_mtimespec, 1);
  } else
    die("unsupported file type in root: %s", from);
}

static void restore_base_directories(void) {
  for (size_t i = base_directories.count; i > 0; i--) {
    Entry *e = &base_directories.items[i - 1];
    char *path = path_join(tx.stage, e->path);
    struct stat st;
    if (lstat(path, &st) || !S_ISDIR(st.st_mode))
      die("a script replaced the directory /%s", e->path);
    if (chmod(path, e->mode & 07777))
      die("chmod %s: %s", path, strerror(errno));
    struct timespec t = {e->mtime, 0};
    set_times(path, t, t, 0);
    free(path);
  }
}

/* Where payloads and scripts act: the staged copy, or the root itself. */
static const char *base_dir(void) { return tx.live ? tx.root : tx.stage; }

static void journal_add(const char *path) {
  journal = xrealloc(journal, journal_count + 1, sizeof(*journal));
  journal[journal_count++] = xstrdup(path);
}

/* Undoes a live install's own creations, newest first. A directory a script
 * filled is left in place. */
static void journal_undo(void) {
  for (size_t i = journal_count; i > 0; i--) {
    struct stat st;
    const char *p = journal[i - 1];
    if (lstat(p, &st))
      continue;
    if (S_ISDIR(st.st_mode) ? rmdir(p) : unlink(p))
      fprintf(stderr, "mdpkg: could not remove %s: %s\n", p, strerror(errno));
  }
}

/* Writes ENTRIES beneath BASE. Existing directories are kept as they are;
 * anything else existing is a collision. Directories created here get their
 * packaged mode and time after their contents are in place. */
static void extract(EntryList *entries, const char *base) {
  char *created = xcalloc(entries->count, 1);
  for (size_t i = 0; i < entries->count; i++) {
    Entry *e = &entries->items[i];
    if (!*e->path)
      continue;
    path_parents(base, e->path, 1);
    char *path = path_join(base, e->path);
    struct stat st;
    int exists = !lstat(path, &st);
    struct timespec t = {e->mtime, 0};
    if (S_ISDIR(e->mode)) {
      if (exists && !S_ISDIR(st.st_mode))
        die("payload directory collides with a file: /%s", e->path);
      if (!exists) {
        if (mkdir(path, 0700))
          die("mkdir %s: %s", path, strerror(errno));
        if (tx.live)
          journal_add(path);
        apply_ownership(path, e->uid, e->gid, 0);
        created[i] = 1;
      }
    } else if (exists)
      die("payload would replace an existing file: /%s", e->path);
    else if (S_ISLNK(e->mode)) {
      if (symlink(e->link, path))
        die("symlink %s: %s", path, strerror(errno));
      if (tx.live)
        journal_add(path);
      apply_ownership(path, e->uid, e->gid, 1);
      set_times(path, t, t, 1);
    } else {
      file_write(path, e->data, e->mode);
      apply_ownership(path, e->uid, e->gid, 0);
      set_times(path, t, t, 0);
    }
    free(path);
  }
  for (size_t i = entries->count; i > 0; i--) {
    Entry *e = &entries->items[i - 1];
    if (!created[i - 1])
      continue;
    char *path = path_join(base, e->path);
    struct timespec t = {e->mtime, 0};
    if (chmod(path, e->mode & 07777))
      die("chmod %s: %s", path, strerror(errno));
    set_times(path, t, t, 0);
    free(path);
  }
  free(created);
}

/* Packaged symlinks may not lead out of the root, even through a chain of
 * other links; checked on the staged tree, before anything is published. */
static void check_payload_symlinks(Component *c) {
  for (size_t i = 0; i < c->payload.count; i++) {
    Entry *e = &c->payload.items[i];
    if (!e->link)
      continue;
    char *parent = path_parent(e->path), *target = path_join(parent, e->link);
    free(resolve_beneath(base_dir(), target, 1));
    free(parent);
    free(target);
  }
}

/* Runs one hook through the runner:
 *   runner SCRIPT WORKDIR PACKAGE TARGET STAGED_ROOT
 * TARGET is the install location inside the staged root: what Apple passes
 * as $2 when installing to another volume. */
static void run_hook(Component *c, int hook, const char *runner,
                     const char *workdir, const char *package) {
  if (!c->hooks[hook])
    return;
  char *script = path_join(workdir, c->hooks[hook]),
       *target = path_join(base_dir(), c->location);
  if (!runner && access(script, X_OK))
    die("%s %s is not executable", c->identifier, hook_names[hook]);
  fprintf(stderr, "mdpkg: running %s %s\n", c->identifier, hook_names[hook]);
  fflush(NULL);
  pid_t pid = fork();
  if (pid < 0)
    die("fork: %s", strerror(errno));
  if (!pid) {
    if (!runner) {
      /* No runner: the running root is the root, so the script runs as
       * Apple's installer runs it: itself, with a fixed environment, and
       * PACKAGE TARGET VOLUME. */
      char *env[7] = {0};
      const char *const pairs[6][2] = {
          {"PATH", "/usr/bin:/bin:/usr/sbin:/sbin"},
          {"COMMAND_LINE_INSTALL", "1"},
          {"PACKAGE_PATH", package},
          {"DSTVOLUME", tx.root},
          {"DSTROOT", target},
          {"INSTALLER_TEMP", workdir}};
      for (int i = 0; i < 6; i++) {
        size_t n = strlen(pairs[i][0]) + strlen(pairs[i][1]) + 2;
        env[i] = xcalloc(n, 1);
        snprintf(env[i], n, "%s=%s", pairs[i][0], pairs[i][1]);
      }
      size_t tn = strlen(workdir) + 8;
      char *tmp = xcalloc(tn, 1);
      snprintf(tmp, tn, "TMPDIR=%s", workdir);
      env[6] = tmp;
      char *envp[8] = {env[0], env[1], env[2], env[3], env[4], env[5], env[6]};
      char *argv[] = {script, (char *)package, target, tx.root, NULL};
      if (chdir(workdir))
        _exit(126);
      execve(script, argv, envp);
      _exit(127);
    }
    if (chdir(workdir) || setenv("COMMAND_LINE_INSTALL", "1", 1) ||
        setenv("PACKAGE_PATH", package, 1) ||
        setenv("DSTVOLUME", base_dir(), 1) || setenv("DSTROOT", target, 1) ||
        setenv("INSTALLER_TEMP", workdir, 1) || setenv("TMPDIR", workdir, 1))
      _exit(126);
    execl(runner, runner, script, workdir, package, target, base_dir(),
          (char *)NULL);
    _exit(127);
  }
  int status;
  while (waitpid(pid, &status, 0) < 0)
    if (errno != EINTR)
      die("waitpid: %s", strerror(errno));
  if (!WIFEXITED(status) || WEXITSTATUS(status))
    die("%s %s failed (%s %d)", c->identifier, hook_names[hook],
        WIFEXITED(status) ? "exit status" : "signal",
        WIFEXITED(status) ? WEXITSTATUS(status) : WTERMSIG(status));
  free(script);
  free(target);
}

static int any_hook(Component *c, int first, int last) {
  for (int h = first; h <= last; h++)
    if (c->hooks[h])
      return 1;
  return 0;
}

static void install_component(Package *pkg, Component *c, const char *runner,
                              const char *scripts) {
  fprintf(stderr, "mdpkg: installing %s %s (%zu entries) at /%s\n",
          c->identifier, c->version, c->payload.count, c->location);
  char *workdir = path_join(scripts, c->identifier);
  if (mkdir(workdir, 0700))
    die("mkdir %s: %s", workdir, strerror(errno));
  extract(&c->scripts, workdir);

  /* Script effects are found by comparing snapshots, and only taken when
   * there are scripts: hashing the whole root is not free. */
  EntryList changes = {0}, before = {0}, after = {0};
  if (any_hook(c, HOOK_PREFLIGHT, HOOK_PREINSTALL)) {
    /* No snapshots of a live root: it is the whole running system. */
    if (!tx.live)
      snapshot_tree(&before, tx.stage);
    run_hook(c, HOOK_PREFLIGHT, runner, workdir, pkg->path);
    run_hook(c, HOOK_PREINSTALL, runner, workdir, pkg->path);
    if (!tx.live) {
      snapshot_tree(&after, tx.stage);
      script_changes(&changes, &before, &after);
    }
    entries_free(&before);
    entries_free(&after);
  }
  extract(&c->payload, base_dir());
  check_payload_symlinks(c);
  if (any_hook(c, HOOK_POSTINSTALL, HOOK_POSTFLIGHT)) {
    if (!tx.live)
      snapshot_tree(&before, tx.stage);
    run_hook(c, HOOK_POSTINSTALL, runner, workdir, pkg->path);
    run_hook(c, HOOK_POSTFLIGHT, runner, workdir, pkg->path);
    if (!tx.live) {
      snapshot_tree(&after, tx.stage);
      script_changes(&changes, &before, &after);
    }
    entries_free(&before);
    entries_free(&after);
  }
  receipts_write(base_dir(), pkg, c, &changes);
  entries_free(&changes);
  free(workdir);
}

static void publish(void) {
  sync_dir(tx.stage);
  sync_dir(tx.dir);
  if (rename(tx.root, tx.original))
    die("move %s aside: %s", tx.root, strerror(errno));
  sync_dir(tx.parent);
  sync_dir(tx.dir);
  if (rename(tx.stage, tx.root))
    die("publish %s: %s", tx.root, strerror(errno));
  tx.published = 1;
  sync_dir(tx.parent);
  sync_dir(tx.dir);
  if (remove_tree(tx.dir, 0))
    fprintf(stderr, "mdpkg: installed, but could not remove %s\n", tx.dir);
  die_hook = NULL;
}

static int same_directory(const char *a, const char *b) {
  struct stat x, y;
  return !lstat(a, &x) && !lstat(b, &y) && S_ISDIR(x.st_mode) &&
         S_ISDIR(y.st_mode) && x.st_dev == y.st_dev && x.st_ino == y.st_ino;
}

/* ROOT names the running root if it is "/" (by identity, so "/." and "//"
 * count, and a symlink to it does not). MDPKG_TEST_LIVE_ROOT names one more
 * directory to treat that way, for tests: a live install of the real root is
 * not something a test may do. */
int is_running_root(const char *root) {
  const char *test = getenv("MDPKG_TEST_LIVE_ROOT");
  return same_directory(root, "/") || (test && same_directory(root, test));
}

/* Inspection needs neither a writable parent nor a lock/recovery operation. */
char *inspect_target(const char *requested) {
  struct stat st;
  char resolved[PATH_MAX];
  if (lstat(requested, &st) || !S_ISDIR(st.st_mode) ||
      !realpath(requested, resolved) || access(resolved, R_OK | X_OK))
    die("target must be a real, readable directory: %s", requested);
  return xstrdup(resolved);
}

static void live_lock(void) {
  char *rel = path_join(INVENTORY_DIR, ".lock");
  path_parents(tx.root, rel, 1);
  char *lock = path_join(tx.root, rel);
  int fd = open(lock, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
  struct stat st;
  if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) ||
      st.st_uid != geteuid() || st.st_nlink != 1)
    die("unsafe lock file %s", lock);
  if (flock(fd, LOCK_EX | LOCK_NB))
    die("%s is locked by another mdpkg", tx.root);
  free(lock);
  free(rel);
}

static void rollback_live(void) {
  journal_undo();
  if (live_tmp && remove_tree(live_tmp, 0))
    fprintf(stderr, "mdpkg: could not remove %s\n", live_tmp);
  fputs("mdpkg: removed what this install had created; scripts' own changes "
        "are not undone\n", stderr);
}

static void install_live(Package *pkg, const char *root, const char *runner) {
  char resolved[PATH_MAX];
  tx.live = 1;
  tx.root = xstrdup(realpath(root, resolved) ? resolved : root);
  if (!getenv("MDPKG_TEST_LIVE_ROOT") && geteuid())
    die("installing into the running root requires root");
  package_resolve(pkg, tx.root, 1);
  live_lock();
  preflight(pkg, runner);

  /* Scripts are unpacked outside the root: it is not ours to fill. */
  const char *dirs[] = {getenv("TMPDIR"), "/private/var/tmp", "/tmp"};
  for (size_t i = 0; i < 3 && !live_tmp; i++) {
    struct stat st;
    if (!dirs[i] || *dirs[i] != '/' || stat(dirs[i], &st) ||
        !S_ISDIR(st.st_mode))
      continue;
    char *tmpl = path_join(dirs[i], "mdpkg.XXXXXX");
    live_tmp = mkdtemp(tmpl);
    if (!live_tmp)
      free(tmpl);
  }
  if (!live_tmp)
    die("no usable temporary directory for scripts");
  die_hook = rollback_live;
  create_hook = journal_add;
  for (size_t i = 0; i < pkg->count; i++)
    install_component(pkg, &pkg->components[i], runner, live_tmp);
  create_hook = NULL;
  die_hook = NULL;
  if (remove_tree(live_tmp, 0))
    fprintf(stderr, "mdpkg: could not remove %s\n", live_tmp);
  sync();
  printf("Installed %zu package(s) into %s\n", pkg->count, tx.root);
}

void install_package(Package *pkg, const char *root, const char *runner) {
  if (is_running_root(root)) {
    install_live(pkg, root, runner);
    return;
  }
  lock_and_recover(root);
  package_resolve(pkg, tx.root, 0);
  preflight(pkg, runner);

  if (mkdir(tx.dir, 0700))
    die("mkdir %s: %s", tx.dir, strerror(errno));
  die_hook = rollback;
  char *marker = path_join(tx.dir, "target");
  file_write(marker, (Bytes){(unsigned char *)tx.root, strlen(tx.root)}, 0600);
  free(marker);
  sync_dir(tx.parent);
  stage_copy(tx.root, tx.stage, "", 0);

  char *scripts = path_join(tx.stage, SCRIPTS_DIR);
  if (mkdir(scripts, 0700))
    die("mkdir %s: %s", scripts, strerror(errno));
  for (size_t i = 0; i < pkg->count; i++)
    install_component(pkg, &pkg->components[i], runner, scripts);
  remove_or_die(scripts);
  free(scripts);
  restore_base_directories();
  publish();
  printf("Installed %zu package(s) into %s\n", pkg->count, tx.root);
}
