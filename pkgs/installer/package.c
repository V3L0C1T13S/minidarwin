/* From a XAR to a list of components: either one bare component package, or
 * a product archive whose Distribution statically selects embedded ones.
 * Anything that would need JavaScript, the network or the running system to
 * decide is refused here, before a root is touched. */
#include "mdpkg.h"

#include <libxml/tree.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

const char *const hook_names[HOOK_COUNT] = {"preflight", "preinstall",
                                            "postinstall", "postflight"};

static int one_of(const char *s, const char *const *list) {
  for (; *list; list++)
    if (!strcmp(s, *list))
      return 1;
  return 0;
}

static void check_identifier(const char *s) {
  if (!*s || strlen(s) > 200 || !strcmp(s, ".") || !strcmp(s, ".."))
    die("invalid package identifier: %s", s);
  for (const char *p = s; *p; p++)
    if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
          (*p >= '0' && *p <= '9') || *p == '.' || *p == '-' || *p == '_'))
      die("invalid package identifier: %s", s);
}

static Bytes component_member(Package *pkg, const char *dir, const char *name,
                              int required) {
  char *path = path_join(dir, name);
  Bytes b = xar_member(&pkg->xar, path, required);
  free(path);
  return b;
}

/* Bundle upgrade/relocation elements only matter when a bundle with the same
 * identifier is already installed somewhere on the volume. mdpkg refuses
 * reinstalls and has no bundle database to search, so they are accepted and
 * the payload is installed where it says. */
static const char *const packageinfo_elements[] = {
    "payload",           "scripts",  "bundle-version", "upgrade-bundle",
    "update-bundle",     "atomic-update-bundle",       "strict-identifier",
    "relocate",          "bundle",   NULL};

static void read_scripts(Component *c, xmlNode *scripts) {
  for (xmlNode *n = xml_elements(scripts); n;
       n = xml_next_element(n)) {
    int hook = -1;
    for (int i = 0; i < HOOK_COUNT; i++)
      if (xml_is(n, hook_names[i]))
        hook = i;
    if (hook < 0 || c->hooks[hook])
      die("unsupported or duplicate install script: %s", xml_name(n));
    char *file = xml_attr(n, "file", NULL);
    c->hooks[hook] = path_normalize(file, 0);
    free(file);
    Entry *e = entries_find(&c->scripts, c->hooks[hook]);
    if (!e || !S_ISREG(e->mode) || !(e->mode & 0111))
      die("install script missing or not executable: %s", c->hooks[hook]);
  }
}

static void load_component(Package *pkg, const char *dir,
                           const char *expected_id) {
  for (size_t i = 0; i < pkg->count; i++)
    if (!strcmp(pkg->components[i].xar_dir, dir))
      return;
  if (pkg->count >= 1024)
    die("component limit");
  Component c = {.xar_dir = xstrdup(dir)};
  xmlDoc *doc = xml_parse(component_member(pkg, dir, "PackageInfo", 1));
  xmlNode *info = xml_root(doc, "pkg-info");
  char *format = xml_attr(info, "format-version", NULL);
  if (strcmp(format, "2"))
    die("unsupported PackageInfo format-version: %s", format);
  free(format);
  c.identifier = xml_attr(info, "identifier", NULL);
  check_identifier(c.identifier);
  if (expected_id && strcmp(c.identifier, expected_id))
    die("Distribution names %s, but PackageInfo says %s", expected_id,
        c.identifier);
  for (size_t i = 0; i < pkg->count; i++)
    if (!strcmp(pkg->components[i].identifier, c.identifier))
      die("duplicate component identifier: %s", c.identifier);
  c.version = xml_attr(info, "version", NULL);
  char *location = xml_attr(info, "install-location", "/");
  c.location = path_normalize(location, 1);
  free(location);
  for (xmlNode *n = xml_elements(info); n;
       n = xml_next_element(n))
    if (!one_of(xml_name(n), packageinfo_elements))
      die("unsupported PackageInfo element: %s", xml_name(n));

  Bytes payload = component_member(pkg, dir, "Payload", 0),
        scripts = component_member(pkg, dir, "Scripts", 0);
  if (payload.data)
    cpio_parse(payload, &c.payload);
  if (scripts.data)
    cpio_parse(scripts, &c.scripts);
  c.bom = component_member(pkg, dir, "Bom", 1);
  if (c.bom.len < 32 || memcmp(c.bom.data, "BOMStore", 8))
    die("invalid BOM");
  xmlNode *count = xml_child(info, "payload");
  if (count) {
    char *n = xml_attr(count, "numberOfFiles", NULL);
    if (parse_uint(n, 10) != c.payload.count)
      die("PackageInfo numberOfFiles does not match the payload");
    free(n);
  }
  read_scripts(&c, xml_child(info, "scripts"));
  xml_free(doc);

  for (size_t i = 0; i < c.payload.count; i++) {
    Entry *e = &c.payload.items[i];
    char *placed = path_join(c.location, e->path);
    free(e->path);
    e->path = placed;
    if (e->link)
      symlink_check_lexical(e->path, e->link);
  }
  pkg->components = xrealloc(pkg->components, pkg->count + 1, sizeof(Component));
  pkg->components[pkg->count++] = c;
}

/* "#Some%20Name.pkg" -> "Some Name.pkg". Anything but an embedded reference
 * (a URL, a file: path, a sibling file) is refused. */
static char *embedded_reference(const char *ref) {
  if (*ref != '#')
    die("external package reference: %s", ref);
  char *decoded = xcalloc(strlen(ref), 1), *out = decoded;
  for (const char *p = ref + 1; *p; p++) {
    if (*p == '%' && p[1] && p[2]) {
      char hex[3] = {p[1], p[2], 0};
      if (!(*out++ = (char)parse_uint(hex, 16)))
        die("invalid package reference: %s", ref);
      p += 2;
    } else
      *out++ = *p;
  }
  char *path = path_normalize(decoded, 0);
  free(decoded);
  if (!*path)
    die("empty package reference");
  return path;
}

static int static_boolean(xmlNode *n, const char *key) {
  char *v = xml_attr(n, key, "true");
  int result = !strcmp(v, "true");
  if (!result && strcmp(v, "false"))
    die("Distribution needs JavaScript to decide %s=\"%s\"", key, v);
  free(v);
  return result;
}

/* Elements whose content is presentation or static metadata. Scripts,
 * installation-check, volume-check, allowed-os-versions and the like are
 * deliberately absent: they must be evaluated, and there is nothing to
 * evaluate them against. */
static const char *const distribution_elements[] = {
    "installer-script", "installer-gui-script", "title",   "options",
    "domains",          "background",           "background-darkAqua",
    "welcome",          "readme",               "license", "conclusion",
    "product",          "choices-outline",      "line",    "choice",
    "pkg-ref",          "bundle-version",       "bundle",  "must-close",
    "app",              NULL};
static const char *const boolean_attributes[] = {
    "selected", "enabled", "visible", "start_selected", "start_enabled",
    "start_visible", "active", NULL};

static void validate_distribution(Package *pkg, xmlNode *n, int depth) {
  if (depth > LIMIT_DEPTH)
    die("Distribution nesting limit");
  for (; n; n = xml_next_element(n)) {
    if (!one_of(xml_name(n), distribution_elements))
      die("unsupported Distribution element: %s", xml_name(n));
    for (xmlAttr *a = n->properties; a; a = a->next)
      if (one_of((const char *)a->name, boolean_attributes))
        (void)static_boolean(n, (const char *)a->name);
    if (xml_is(n, "options") && !pkg->host_architectures) {
      char *arch = xml_attr(n, "hostArchitectures", "");
      if (*arch)
        pkg->host_architectures = arch;
      else
        free(arch);
    }
    validate_distribution(pkg, xml_elements(n), depth + 1);
  }
}

static xmlNode *find_choice(xmlNode *dist, const char *id) {
  xmlNode *found = NULL;
  for (xmlNode *n = xml_elements(dist); n;
       n = xml_next_element(n)) {
    if (!xml_is(n, "choice"))
      continue;
    char *cid = xml_attr(n, "id", NULL);
    if (!strcmp(cid, id)) {
      if (found)
        die("duplicate choice: %s", id);
      found = n;
    }
    free(cid);
  }
  if (!found)
    die("unresolved choice: %s", id);
  return found;
}

/* A pkg-ref id may appear several times; exactly one carries the location. */
static char *find_reference(xmlNode *dist, const char *id) {
  char *path = NULL;
  for (xmlNode *n = xml_elements(dist); n;
       n = xml_next_element(n)) {
    if (!xml_is(n, "pkg-ref"))
      continue;
    char *nid = xml_attr(n, "id", NULL);
    if (!strcmp(nid, id) && static_boolean(n, "active"))
      for (xmlNode *t = n->children; t; t = t->next)
        if (t->type == XML_TEXT_NODE) {
          char *text = xml_text(t);
          if (*text) {
            if (path)
              die("pkg-ref %s has several locations", id);
            path = embedded_reference(text);
          }
          free(text);
        }
    free(nid);
  }
  if (!path)
    die("unresolved pkg-ref: %s", id);
  return path;
}

static void select_lines(Package *pkg, xmlNode *dist, xmlNode *line,
                         int depth) {
  if (depth > LIMIT_DEPTH)
    die("choices-outline nesting limit");
  for (; line; line = xml_next_element(line)) {
    if (!xml_is(line, "line"))
      die("unsupported choices-outline element: %s", xml_name(line));
    char *id = xml_attr(line, "choice", NULL);
    xmlNode *choice = find_choice(dist, id);
    free(id);
    if (static_boolean(choice, "start_selected") &&
        static_boolean(choice, "selected"))
      for (xmlNode *ref = xml_elements(choice); ref;
           ref = xml_next_element(ref)) {
        if (!xml_is(ref, "pkg-ref"))
          die("unsupported choice content: %s", xml_name(ref));
        char *pid = xml_attr(ref, "id", NULL), *path = find_reference(dist, pid);
        load_component(pkg, path, pid);
        free(path);
        free(pid);
      }
    select_lines(pkg, dist, xml_elements(line), depth + 1);
  }
}

void package_load(Package *pkg, const char *path) {
  *pkg = (Package){.path = path};
  xar_open(&pkg->xar, path);
  Bytes distribution = xar_member(&pkg->xar, "Distribution", 0);
  if (!distribution.data)
    load_component(pkg, "", NULL);
  else {
    xmlDoc *doc = xml_parse(distribution);
    xmlNode *dist = xmlDocGetRootElement(doc);
    if (!xml_is(dist, "installer-script") &&
        !xml_is(dist, "installer-gui-script"))
      die("unsupported Distribution root");
    validate_distribution(pkg, dist, 0);
    xmlNode *outline = xml_child(dist, "choices-outline");
    if (!outline)
      die("Distribution without a choices-outline");
    select_lines(pkg, dist, xml_elements(outline), 0);
    xml_free(doc);
  }
  if (!pkg->count)
    die("no package selected");
  /* Components may share directories, never anything else. */
  EntryList all = {0};
  for (size_t i = 0; i < pkg->count; i++)
    for (size_t j = 0; j < pkg->components[i].payload.count; j++)
      entries_append(&all, pkg->components[i].payload.items[j]);
  entries_check_paths(&all, 1);
  free(all.items);
}
