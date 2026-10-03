/* Installer read-only XML plists. Package XML deliberately has stricter DTD
 * rules: ordinary Apple plists have a DOCTYPE, but never need its contents. */
#include "installer-js.h"

#include <libxml/parser.h>
#include <libxml/tree.h>
#include <openssl/evp.h>
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int plain_children(xmlNode *node) {
  for (xmlNode *n = node->children; n; n = n->next)
    if (n->type != XML_TEXT_NODE && n->type != XML_CDATA_SECTION_NODE &&
        n->type != XML_COMMENT_NODE)
      return 0;
  return 1;
}

static xmlNode *next_value(xmlNode *node) {
  for (; node; node = node->next)
    if (node->type != XML_COMMENT_NODE &&
        !(node->type == XML_TEXT_NODE && xmlIsBlankNode(node)))
      return node;
  return NULL;
}

static JSValue plist_date(JSContext *ctx, const char *text) {
  int year, month, day, hour, minute, second;
  if (strlen(text) != 20 ||
      sscanf(text, "%4d-%2d-%2dT%2d:%2d:%2dZ", &year, &month, &day,
             &hour, &minute, &second) != 6 ||
      text[4] != '-' || text[7] != '-' || text[10] != 'T' ||
      text[13] != ':' || text[16] != ':' || text[19] != 'Z' ||
      month < 1 || month > 12 || day < 1 || day > 31 || hour < 0 || hour > 23 ||
      minute < 0 || minute > 59 || second < 0 || second > 59)
    return JS_ThrowTypeError(ctx, "invalid plist date");
  for (size_t i = 0; i < 20; i++)
    if (i != 4 && i != 7 && i != 10 && i != 13 && i != 16 && i != 19 &&
        (text[i] < '0' || text[i] > '9'))
      return JS_ThrowTypeError(ctx, "invalid plist date");
  /* timegm normalizes dates; check the normalized result below. */
  struct tm tm = {.tm_year = year - 1900, .tm_mon = month - 1, .tm_mday = day,
                  .tm_hour = hour, .tm_min = minute, .tm_sec = second};
  time_t epoch = timegm(&tm);
  if (tm.tm_year != year - 1900 || tm.tm_mon != month - 1 || tm.tm_mday != day)
    return JS_ThrowTypeError(ctx, "invalid plist date");
  return JS_NewDate(ctx, (double)epoch * 1000.0);
}

static JSValue plist_value(JSContext *ctx, xmlNode *node, int depth,
                           size_t *count) {
  if (!node || depth > LIMIT_DEPTH || ++*count > LIMIT_ENTRIES)
    return JS_ThrowTypeError(ctx, "plist nesting or entry limit");
  if (xml_is(node, "dict") || xml_is(node, "array")) {
    int dict = xml_is(node, "dict");
    JSValue result = dict ? JS_NewObjectProto(ctx, JS_NULL) : JS_NewArray(ctx);
    if (JS_IsException(result))
      return result;
    uint32_t index = 0;
    for (xmlNode *n = node->children; n; n = n->next) {
      if (n->type == XML_COMMENT_NODE)
        continue;
      if (n->type == XML_TEXT_NODE && xmlIsBlankNode(n))
        continue;
      if (n->type != XML_ELEMENT_NODE)
        goto invalid_container;
      char *key = NULL;
      if (dict) {
        if (!xml_is(n, "key") || !plain_children(n))
          goto invalid_container;
        key = xml_text(n);
        n = next_value(n->next);
        if (!n || n->type != XML_ELEMENT_NODE) {
          free(key);
          goto invalid_container;
        }
        JSAtom atom = JS_NewAtom(ctx, key);
        JSPropertyDescriptor desc;
        int has = JS_GetOwnProperty(ctx, &desc, result, atom);
        JS_FreeAtom(ctx, atom);
        if (has > 0) {
          JS_FreeValue(ctx, desc.value);
          JS_FreeValue(ctx, desc.getter);
          JS_FreeValue(ctx, desc.setter);
        }
        if (has != 0) {
          free(key);
          goto invalid_container;
        }
      }
      JSValue value = plist_value(ctx, n, depth + 1, count);
      if (JS_IsException(value)) {
        free(key);
        JS_FreeValue(ctx, result);
        return value;
      }
      int status = dict ? JS_SetPropertyStr(ctx, result, key, value)
                        : JS_SetPropertyUint32(ctx, result, index++, value);
      free(key);
      if (status < 0) {
        JS_FreeValue(ctx, result);
        return JS_EXCEPTION;
      }
    }
    return result;
invalid_container:
    JS_FreeValue(ctx, result);
    return JS_ThrowTypeError(ctx, "malformed plist %s", xml_name(node));
  }
  if (!plain_children(node))
    return JS_ThrowTypeError(ctx, "plist entities or nested scalar elements are unsupported");
  char *text = xml_text(node), *end;
  JSValue result;
  if (xml_is(node, "string"))
    result = JS_NewString(ctx, text);
  else if (xml_is(node, "true") || xml_is(node, "false")) {
    result = *text ? JS_ThrowTypeError(ctx, "malformed plist Boolean")
                   : JS_NewBool(ctx, xml_is(node, "true"));
  } else if (xml_is(node, "integer")) {
    errno = 0;
    long long value = strtoll(text, &end, 10);
    result = errno || end == text || *end
                 ? JS_ThrowTypeError(ctx, "invalid plist integer")
                 : JS_NewInt64(ctx, value);
  } else if (xml_is(node, "real")) {
    errno = 0;
    double value = strtod(text, &end);
    result = errno || end == text || *end || !isfinite(value)
                 ? JS_ThrowTypeError(ctx, "invalid plist real")
                 : JS_NewFloat64(ctx, value);
  } else if (xml_is(node, "date"))
    result = plist_date(ctx, text);
  else if (xml_is(node, "data")) {
    size_t len = 0;
    for (char *p = text; *p; p++)
      if (!isspace((unsigned char)*p))
        text[len++] = *p;
    text[len] = 0;
    unsigned char *data = xcalloc(len + 1, 1);
    int valid = len % 4 == 0;
    size_t padding = len && text[len - 1] == '=' ? 1 : 0;
    if (len > 1 && text[len - 2] == '=')
      padding++;
    for (size_t i = 0; i < len - padding; i++)
      if (!(isalnum((unsigned char)text[i]) || text[i] == '+' || text[i] == '/'))
        valid = 0;
    int decoded = valid ? EVP_DecodeBlock(data, (unsigned char *)text, (int)len) : -1;
    if (decoded < 0 || (size_t)decoded < padding)
      result = JS_ThrowTypeError(ctx, "invalid plist base64 data");
    else {
      JSValue buffer = JS_NewArrayBufferCopy(ctx, data, (size_t)decoded - padding);
      JSValue args[] = {buffer, JS_UNDEFINED, JS_UNDEFINED};
      result = JS_IsException(buffer) ? JS_EXCEPTION
                                      : JS_NewTypedArray(ctx, 3, args, JS_TYPED_ARRAY_UINT8);
      JS_FreeValue(ctx, buffer);
    }
    free(data);
  } else
    result = JS_ThrowTypeError(ctx, "unsupported plist element: %s", xml_name(node));
  free(text);
  return result;
}

JSValue js_plist_read(JSContext *ctx, const char *path) {
  struct stat st;
  if (lstat(path, &st)) {
    if (errno == ENOENT || errno == ENOTDIR)
      return JS_NULL;
    return JS_ThrowInternalError(ctx, "plist %s: %s", path, strerror(errno));
  }
  if (!S_ISREG(st.st_mode))
    return JS_ThrowTypeError(ctx, "plist is not a regular file: %s", path);
  Bytes b = file_read(path, LIMIT_XML);
  if (b.len >= 6 && !memcmp(b.data, "bplist", 6)) {
    free(b.data);
    return JS_ThrowTypeError(ctx, "binary plists are unsupported: %s", path);
  }
  if (!b.len || memchr(b.data, 0, b.len)) {
    free(b.data);
    return JS_ThrowTypeError(ctx, "invalid XML plist: %s", path);
  }
  xmlDoc *doc = xmlReadMemory((const char *)b.data, (int)b.len, path, NULL,
                             XML_PARSE_NONET | XML_PARSE_NOBLANKS);
  free(b.data);
  xmlDtd *dtd = doc ? doc->intSubset : NULL;
  int safe_dtd = !dtd ||
      (!dtd->children && !xmlStrcmp(dtd->name, BAD_CAST "plist") &&
       !xmlStrcmp(dtd->ExternalID, BAD_CAST "-//Apple//DTD PLIST 1.0//EN") &&
       !xmlStrcmp(dtd->SystemID, BAD_CAST "http://www.apple.com/DTDs/PropertyList-1.0.dtd"));
  if (!doc || doc->extSubset || !safe_dtd ||
      !xml_is(xmlDocGetRootElement(doc), "plist")) {
    if (doc)
      xmlFreeDoc(doc);
    return JS_ThrowTypeError(ctx, "invalid XML plist or unsafe DTD: %s", path);
  }
  xmlNode *value = next_value(xmlDocGetRootElement(doc)->children);
  size_t count = 0;
  JSValue result = !value || value->type != XML_ELEMENT_NODE || next_value(value->next)
                       ? JS_ThrowTypeError(ctx, "plist requires exactly one value: %s", path)
                       : plist_value(ctx, value, 0, &count);
  xmlFreeDoc(doc);
  return result;
}
