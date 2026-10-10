/* QuickJS embedding only: no quickjs-libc modules, loaders, or subprocesses. */
#include "installer-js.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

static int interrupted(JSRuntime *runtime, void *opaque) {
  (void)runtime;
  InstallerJS *js = opaque;
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now))
    return 1;
  return now.tv_sec > js->deadline.tv_sec ||
         (now.tv_sec == js->deadline.tv_sec && now.tv_nsec >= js->deadline.tv_nsec);
}

static JSModuleDef *no_module(JSContext *ctx, const char *name, void *opaque) {
  (void)opaque;
  JS_ThrowTypeError(ctx, "Installer JS module loading is unsupported: %s", name);
  return NULL;
}

void installer_js_require(InstallerJS *js, JSValueConst value, const char *label) {
  if (!JS_IsException(value))
    return;
  JSValue error = JS_GetException(js->context);
  const char *message = JS_ToCString(js->context, error);
  die("Installer JS %s: %s", label, message ? message : "exception (possibly memory limit)");
}

static const char *string_argument(JSContext *ctx, JSValueConst value) {
  size_t len;
  const char *s = JS_ToCStringLen(ctx, &len, value);
  if (s && (memchr(s, 0, len) || len > LIMIT_XML)) {
    JS_FreeCString(ctx, s);
    JS_ThrowTypeError(ctx, "Installer JS string contains NUL or exceeds limit");
    return NULL;
  }
  return s;
}

static char *read_path(InstallerJS *js, const char *requested) {
  char *rel = path_normalize(requested, 1), *absolute = path_join("/", rel);
  free(rel);
  /* Recognize aliases of ancestors (macOS /tmp and /var), before resolving
   * any symlink inside an offline target. realpath of the full path first
   * would let an escaping target symlink masquerade as an ordinary host read. */
  if (js->root && strcmp(js->root, "/")) {
    for (char *p = absolute + 1;; p++) {
      if (*p && *p != '/')
        continue;
      char saved = *p, resolved[4096];
      *p = 0;
      int match = realpath(absolute, resolved) && !strcmp(resolved, js->root);
      *p = saved;
      if (match) {
        char *confined = resolve_target_path(js->root, p + !!saved, 1, js->live);
        free(absolute);
        absolute = path_join(js->root, confined);
        free(confined);
        return absolute;
      }
      if (!saved)
        break;
    }
  }
  if (js->root && (!strcmp(js->root, "/") || path_has_prefix(absolute, js->root))) {
    const char *suffix = absolute + (!strcmp(js->root, "/") ? 1 : strlen(js->root));
    while (*suffix == '/')
      suffix++;
    char *resolved = resolve_target_path(js->root, suffix, 1, js->live);
    free(absolute);
    absolute = path_join(js->root, resolved);
    free(resolved);
  } else {
    /* Resolve host symlinks before the O_NOFOLLOW regular-file read. */
    char resolved[4096];
    if (realpath(absolute, resolved)) {
      free(absolute);
      absolute = xstrdup(resolved);
      /* A host alias into the target must not bypass target confinement. */
      if (js->root && path_has_prefix(absolute, js->root)) {
        char *suffix = xstrdup(absolute + strlen(js->root));
        char *confined = resolve_target_path(js->root, suffix, 1, js->live);
        free(absolute);
        absolute = path_join(js->root, confined);
        free(suffix);
        free(confined);
      }
    }
  }
  return absolute;
}

static JSValue target_plist(InstallerJS *js, const char *rel) {
  char *resolved = resolve_target_path(js->root, rel, 1, js->live);
  char *path = path_join(js->root, resolved);
  JSValue value = js_plist_read(js->context, path);
  free(path);
  free(resolved);
  return value;
}

static int valid_version(const char *s) {
  if (!*s)
    return 0;
  for (;;) {
    if (*s < '0' || *s > '9')
      return 0;
    while (*s >= '0' && *s <= '9')
      s++;
    if (!*s)
      return 1;
    if (*s++ != '.')
      return 0;
  }
}

static int compare_versions(const char *a, const char *b) {
  while (*a || *b) {
    size_t an = strcspn(a, "."), bn = strcspn(b, ".");
    const char *ae = a + an, *be = b + bn;
    while (a < ae && *a == '0')
      a++;
    while (b < be && *b == '0')
      b++;
    size_t al = (size_t)(ae - a), bl = (size_t)(be - b);
    if (al != bl)
      return al < bl ? -1 : 1;
    int cmp = memcmp(a, b, al);
    if (cmp)
      return cmp < 0 ? -1 : 1;
    a = ae + !!*ae;
    b = be + !!*be;
  }
  return 0;
}

enum { API_LOG, API_COMPARE, API_PROPERTIES, API_SYSCTL,
       API_EXISTS, API_PLIST, API_BUNDLE, API_RECEIPT,
       API_HOST_VERSION, API_TARGET_VERSION, API_SPACE };

static JSValue native_api(JSContext *ctx, JSValueConst this_value, int argc,
                           JSValueConst *argv, int api) {
  (void)this_value;
  InstallerJS *js = JS_GetContextOpaque(ctx);
  if (interrupted(js->runtime, js))
    return JS_ThrowInternalError(ctx, "Installer JS evaluation time limit");
  if (api == API_HOST_VERSION && opt_system_version) {
    JSValue object = JS_NewObject(ctx);
    if (JS_SetPropertyStr(ctx, object, "ProductVersion",
                          JS_NewString(ctx, opt_system_version)) < 0) {
      JS_FreeValue(ctx, object);
      return JS_EXCEPTION;
    }
    return object;
  }
  if (api == API_HOST_VERSION) {
    char *path = read_path(js, "/System/Library/CoreServices/SystemVersion.plist");
    JSValue result = js_plist_read(ctx, path);
    free(path);
    return result;
  }
  if (api == API_TARGET_VERSION) {
    JSValue plist = target_plist(js, "System/Library/CoreServices/SystemVersion.plist");
    if (JS_IsNull(plist) || JS_IsException(plist))
      return plist;
    JSValue result = JS_GetPropertyStr(ctx, plist, "ProductVersion");
    JS_FreeValue(ctx, plist);
    if (JS_IsUndefined(result))
      return JS_NULL;
    if (!JS_IsString(result) && !JS_IsException(result)) {
      JS_FreeValue(ctx, result);
      return JS_ThrowTypeError(ctx, "my.target.systemVersion: ProductVersion must be a string");
    }
    return result;
  }
  if (api == API_SPACE) {
    struct statfs fs;
    if (statfs(js->root, &fs))
      return JS_ThrowInternalError(ctx, "my.target.availableKilobytes: %s", strerror(errno));
    return JS_NewFloat64(ctx, (double)fs.f_bavail * (double)fs.f_bsize / 1024.0);
  }
  if (argc < (api == API_COMPARE ? 2 : 1))
    return JS_ThrowTypeError(ctx, "missing Installer JS argument");
  if (api == API_PROPERTIES) {
    JSPropertyEnum *props;
    uint32_t count;
    if (JS_GetOwnPropertyNames(ctx, &props, &count, argv[0],
                              JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0)
      return JS_EXCEPTION;
    JSValue result = JS_NewArray(ctx);
    for (uint32_t i = 0; i < count; i++) {
      JSValue name = JS_AtomToString(ctx, props[i].atom);
      JS_FreeAtom(ctx, props[i].atom);
      if (JS_SetPropertyUint32(ctx, result, i, name) < 0) {
        for (uint32_t j = i + 1; j < count; j++)
          JS_FreeAtom(ctx, props[j].atom);
        js_free(ctx, props);
        JS_FreeValue(ctx, result);
        return JS_EXCEPTION;
      }
    }
    js_free(ctx, props);
    return result;
  }
  const char *arg = string_argument(ctx, argv[0]);
  if (!arg)
    return JS_EXCEPTION;
  JSValue result;
  if (api == API_LOG) {
    fprintf(stderr, "mdpkg: JS: %s\n", arg);
    result = JS_UNDEFINED;
  } else if (api == API_COMPARE) {
    const char *other = string_argument(ctx, argv[1]);
    result = !other ? JS_EXCEPTION
             : !valid_version(arg) || !valid_version(other)
                 ? JS_ThrowTypeError(ctx, "system.compareVersions supports numeric dotted versions")
                 : JS_NewInt32(ctx, compare_versions(arg, other));
    JS_FreeCString(ctx, other);
  } else if (api == API_SYSCTL) {
    int text = !strcmp(arg, "hw.machine") || !strcmp(arg, "hw.model") ||
               !strcmp(arg, "kern.osrelease") || !strcmp(arg, "kern.osversion");
    int integer = !strcmp(arg, "hw.ncpu") || !strncmp(arg, "hw.optional.", 12);
    int wide = !strcmp(arg, "hw.memsize");
    union { char text[4096]; int32_t integer; uint64_t wide; } value;
    size_t len = text ? sizeof(value.text) : wide ? sizeof(value.wide) : sizeof(value.integer);
    if (!text && !integer && !wide)
      result = JS_ThrowTypeError(ctx, "unsupported system.sysctl selector: %s", arg);
    else if (sysctlbyname(arg, &value, &len, NULL, 0))
      result = JS_ThrowInternalError(ctx, "system.sysctl %s: %s", arg, strerror(errno));
    else if (text)
      result = JS_NewStringLen(ctx, value.text, len && !value.text[len - 1] ? len - 1 : len);
    else if (wide && len == sizeof(value.wide))
      result = JS_NewFloat64(ctx, (double)value.wide);
    else if (integer && len == sizeof(value.integer))
      result = JS_NewInt32(ctx, value.integer);
    else
      result = JS_ThrowTypeError(ctx, "unsupported system.sysctl value type: %s", arg);
  } else if (api == API_RECEIPT) {
    int valid = *arg && strlen(arg) <= 200 && strcmp(arg, ".") && strcmp(arg, "..");
    for (const char *p = arg; *p; p++)
      if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
            (*p >= '0' && *p <= '9') || *p == '.' || *p == '-' || *p == '_'))
        valid = 0;
    if (!valid)
      result = JS_ThrowTypeError(ctx, "invalid receipt identifier: %s", arg);
    else {
      char rel[512];
      snprintf(rel, sizeof(rel), "%s/%s.plist", RECEIPTS_DIR, arg);
      result = target_plist(js, rel);
    }
  } else {
    char *path = read_path(js, arg);
    if (api == API_EXISTS) {
      struct stat st;
      if (!stat(path, &st))
        result = JS_TRUE;
      else if (errno == ENOENT || errno == ENOTDIR)
        result = JS_FALSE;
      else
        result = JS_ThrowInternalError(ctx, "system.files.fileExistsAtPath %s: %s", arg, strerror(errno));
    } else if (api == API_BUNDLE) {
      char *info = path_join(path, "Contents/Info.plist");
      char *resolved = read_path(js, info);
      result = js_plist_read(ctx, resolved);
      free(resolved);
      free(info);
      if (JS_IsNull(result)) {
        info = path_join(path, "Info.plist");
        resolved = read_path(js, info);
        result = js_plist_read(ctx, resolved);
        free(resolved);
        free(info);
      }
    } else
      result = js_plist_read(ctx, path);
    free(path);
  }
  JS_FreeCString(ctx, arg);
  return result;
}

static JSValue unsupported(JSContext *ctx, JSValueConst this_value, int argc,
                            JSValueConst *argv, int magic, JSValue *data) {
  (void)this_value; (void)argc; (void)argv; (void)magic;
  const char *name = JS_ToCString(ctx, data[0]);
  JSValue result = JS_ThrowTypeError(ctx, "unsupported Installer JS API: %s", name ? name : "unknown");
  JS_FreeCString(ctx, name);
  return result;
}

static void put(InstallerJS *js, JSValueConst object, const char *key, JSValue value) {
  installer_js_require(js, value, key);
  if (JS_SetPropertyStr(js->context, object, key, value) < 0)
    installer_js_require(js, JS_EXCEPTION, key);
}

static void method(InstallerJS *js, JSValueConst object, const char *key, int api) {
  put(js, object, key, JS_NewCFunctionMagic(js->context, native_api, key, 1,
                                         JS_CFUNC_generic_magic, api));
}

static void getter(InstallerJS *js, JSValueConst object, const char *key, int api) {
  JSAtom atom = JS_NewAtom(js->context, key);
  JSValue get = JS_NewCFunctionMagic(js->context, native_api, key, 0,
                                   JS_CFUNC_generic_magic, api);
  if (JS_DefinePropertyGetSet(js->context, object, atom, get, JS_UNDEFINED,
                              JS_PROP_ENUMERABLE) < 0)
    installer_js_require(js, JS_EXCEPTION, key);
  JS_FreeAtom(js->context, atom);
}

static void unavailable(InstallerJS *js, JSValueConst object,
                         const char *key, const char *name) {
  JSValue data = JS_NewString(js->context, name);
  JSValue get = JS_NewCFunctionData(js->context, unsupported, 0, 0, 1, &data);
  JS_FreeValue(js->context, data);
  JSAtom atom = JS_NewAtom(js->context, key);
  if (JS_DefinePropertyGetSet(js->context, object, atom, get, JS_UNDEFINED,
                              JS_PROP_ENUMERABLE) < 0)
    installer_js_require(js, JS_EXCEPTION, name);
  JS_FreeAtom(js->context, atom);
}

InstallerJS *installer_js_new(const char *root, int live) {
  InstallerJS *js = xcalloc(1, sizeof(*js));
  js->root = root ? xstrdup(root) : NULL;
  js->live = live;
  if (clock_gettime(CLOCK_MONOTONIC, &js->deadline))
    die("Installer JS monotonic clock unavailable");
  js->deadline.tv_sec += 5;
  js->runtime = JS_NewRuntime();
  if (!js->runtime)
    die("cannot create Installer JS runtime");
  JS_SetMemoryLimit(js->runtime, 64u * 1024u * 1024u);
  JS_SetMaxStackSize(js->runtime, 1024u * 1024u);
  JS_SetInterruptHandler(js->runtime, interrupted, js);
  JS_SetModuleLoaderFunc(js->runtime, NULL, no_module, NULL);
  js->context = JS_NewContext(js->runtime);
  if (!js->context)
    die("cannot create Installer JS context");
  JS_SetContextOpaque(js->context, js);
  js->global = JS_GetGlobalObject(js->context);
  js->target = JS_NewObject(js->context);
  js->result = JS_NewObject(js->context);
  js->choices = JS_NewObjectProto(js->context, JS_NULL);
  JSValue system = JS_NewObject(js->context), files = JS_NewObject(js->context);
  method(js, system, "log", API_LOG);
  method(js, system, "compareVersions", API_COMPARE);
  method(js, system, "propertiesOf", API_PROPERTIES);
  method(js, system, "sysctl", API_SYSCTL);
  getter(js, system, "version", API_HOST_VERSION);
  method(js, files, "fileExistsAtPath", API_EXISTS);
  method(js, files, "plistAtPath", API_PLIST);
  method(js, files, "bundleAtPath", API_BUNDLE);
  put(js, system, "files", files);
  const char *names[] = {"run", "runOnce", "localizedString", "localizedStringWithFormat",
      "localizedStandardString", "localizedStandardStringWithFormat", "applications",
      "ioregistry", "defaults", "users", "gestalt", NULL};
  for (const char **name = names; *name; name++) {
    char label[128];
    snprintf(label, sizeof(label), "system.%s", *name);
    unavailable(js, system, *name, label);
  }
  put(js, js->global, "system", system);
  put(js, js->global, "choices", JS_DupValue(js->context, js->choices));
  if (root) {
    put(js, js->target, "mountpoint", JS_NewString(js->context, root));
    getter(js, js->target, "availableKilobytes", API_SPACE);
    getter(js, js->target, "systemVersion", API_TARGET_VERSION);
    method(js, js->target, "receiptForIdentifier", API_RECEIPT);
  }
  installer_js_my(js, JS_UNDEFINED);
  return js;
}

void installer_js_my(InstallerJS *js, JSValueConst choice) {
  JSValue my = JS_IsUndefined(choice) ? JS_NewObject(js->context)
                                     : JS_DupValue(js->context, choice);
  put(js, my, "target", JS_DupValue(js->context, js->target));
  put(js, my, "result", JS_DupValue(js->context, js->result));
  put(js, js->global, "my", my);
}

static JSValue evaluate(InstallerJS *js, const char *source, const char *label,
                         int expression, int compile) {
  if (interrupted(js->runtime, js))
    die("Installer JS %s: evaluation time limit", label);
  size_t len = strlen(source);
  char *wrapped = NULL;
  if (expression) {
    wrapped = xcalloc(len + 5, 1);
    snprintf(wrapped, len + 5, "(%s\n)", source);
    source = wrapped;
    len = strlen(source);
  }
  JSValue value = JS_Eval(js->context, source, len, label,
                         JS_EVAL_TYPE_GLOBAL | (compile ? JS_EVAL_FLAG_COMPILE_ONLY : 0));
  free(wrapped);
  installer_js_require(js, value, label);
  if (!compile && JS_IsJobPending(js->runtime))
    die("Installer JS %s: asynchronous jobs are unsupported", label);
  return value;
}

void installer_js_compile(InstallerJS *js, const char *source,
                          const char *label, int expression) {
  JS_FreeValue(js->context, evaluate(js, source, label, expression, 1));
}

JSValue installer_js_eval(InstallerJS *js, const char *source,
                          const char *label, int expression) {
  return evaluate(js, source, label, expression, 0);
}

int installer_js_boolean(InstallerJS *js, const char *source, const char *label) {
  JSValue value = installer_js_eval(js, source, label, 1);
  if (JS_IsObject(value))
    die("Installer JS %s: expected synchronous Boolean expression", label);
  int result = JS_ToBool(js->context, value);
  JS_FreeValue(js->context, value);
  return result;
}

void installer_js_check(InstallerJS *js, xmlNode *node) {
  if (!node)
    return;
  const char *keys[] = {"type", "title", "message"};
  for (size_t i = 0; i < 3; i++)
    put(js, js->result, keys[i], JS_NewString(js->context, ""));
  installer_js_my(js, JS_UNDEFINED);
  char *source = xml_attr(node, "script", NULL);
  /* Evaluated as a script, not wrapped as an expression: Apple's checks are
   * commonly statements (`script="InstallationCheck();"`), and a script's
   * completion value is that of its last expression statement. */
  JSValue verdict = installer_js_eval(js, source, xml_name(node), 0);
  if (JS_IsObject(verdict))
    die("Installer JS %s: expected synchronous Boolean expression", xml_name(node));
  int allowed = JS_ToBool(js->context, verdict);
  JS_FreeValue(js->context, verdict);
  free(source);
  JSValue type = JS_GetPropertyStr(js->context, js->result, "type");
  JSValue title = JS_GetPropertyStr(js->context, js->result, "title");
  JSValue message = JS_GetPropertyStr(js->context, js->result, "message");
  const char *t = JS_ToCString(js->context, type), *heading = JS_ToCString(js->context, title),
             *detail = JS_ToCString(js->context, message);
  if (!t || !heading || !detail)
    installer_js_require(js, JS_EXCEPTION, xml_name(node));
  if (!allowed) {
    if (strcmp(t, "Warn"))
      die("Installer JS %s failed (%s): %s%s%s", xml_name(node), *t ? t : "Fatal",
          heading, *heading && *detail ? ": " : "", detail);
    fprintf(stderr, "mdpkg: Installer JS %s warning: %s%s%s\n", xml_name(node),
            heading, *heading && *detail ? ": " : "", detail);
  }
  JS_FreeCString(js->context, t);
  JS_FreeCString(js->context, heading);
  JS_FreeCString(js->context, detail);
  JS_FreeValue(js->context, type);
  JS_FreeValue(js->context, title);
  JS_FreeValue(js->context, message);
}

void installer_js_free(InstallerJS *js) {
  JS_FreeValue(js->context, js->choices);
  JS_FreeValue(js->context, js->result);
  JS_FreeValue(js->context, js->target);
  JS_FreeValue(js->context, js->global);
  JS_FreeContext(js->context);
  JS_FreeRuntime(js->runtime);
  free(js->root);
  free(js);
}
