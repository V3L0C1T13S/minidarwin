/* libxml2 access for the TOC, PackageInfo and Distribution. Documents with a
 * DTD are refused outright, so no entity is ever expanded or fetched. */
#include "mdpkg.h"

#include <libxml/parser.h>
#include <libxml/tree.h>
#include <stdlib.h>
#include <string.h>

xmlDoc *xml_parse(Bytes b) {
  if (!b.len || b.len > LIMIT_XML || memchr(b.data, 0, b.len))
    die("invalid XML document");
  xmlDoc *doc = xmlReadMemory((const char *)b.data, (int)b.len, "package.xml",
                              NULL, XML_PARSE_NONET | XML_PARSE_NOBLANKS);
  if (!doc || doc->intSubset || doc->extSubset || !xmlDocGetRootElement(doc))
    die("invalid XML, or XML with a DTD");
  return doc;
}

void xml_free(xmlDoc *doc) { xmlFreeDoc(doc); }

xmlNode *xml_root(xmlDoc *doc, const char *expected_name) {
  xmlNode *root = xmlDocGetRootElement(doc);
  if (!xml_is(root, expected_name))
    die("expected XML root <%s>", expected_name);
  return root;
}

int xml_is(xmlNode *n, const char *name) {
  return n && n->type == XML_ELEMENT_NODE &&
         !xmlStrcmp(n->name, BAD_CAST name);
}

xmlNode *xml_first_element(xmlNode *n) {
  while (n && n->type != XML_ELEMENT_NODE)
    n = n->next;
  return n;
}

/* The first element child of PARENT (which may be NULL). */
xmlNode *xml_elements(xmlNode *parent) {
  return xml_first_element(parent ? parent->children : NULL);
}

xmlNode *xml_next_element(xmlNode *n) {
  return xml_first_element(n ? n->next : NULL);
}

xmlNode *xml_child(xmlNode *parent, const char *name) {
  for (xmlNode *n = xml_elements(parent); n;
       n = xml_next_element(n))
    if (xml_is(n, name))
      return n;
  return NULL;
}

const char *xml_name(xmlNode *n) { return (const char *)n->name; }

char *xml_text(xmlNode *n) {
  xmlChar *x = n ? xmlNodeGetContent(n) : NULL;
  if (!x)
    die("missing XML value");
  char *s = xstrdup((char *)x);
  xmlFree(x);
  return s;
}

/* Returns a copy of attribute KEY, FALLBACK if absent, or dies if there is no
 * fallback. */
char *xml_attr(xmlNode *n, const char *key, const char *fallback) {
  xmlChar *x = n ? xmlGetProp(n, BAD_CAST key) : NULL;
  if (!x) {
    if (!fallback)
      die("missing XML attribute %s", key);
    return xstrdup(fallback);
  }
  char *s = xstrdup((char *)x);
  xmlFree(x);
  return s;
}

uint64_t xml_child_uint(xmlNode *parent, const char *name) {
  char *s = xml_text(xml_child(parent, name));
  uint64_t v = parse_uint(s, 10);
  free(s);
  return v;
}
