#include "common.hpp"

#include <libxml/parser.h>
#include <libxml/tree.h>
#include <charconv>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <sys/stat.h>
#include <unistd.h>

namespace md {
Fd::~Fd() noexcept { reset(); }
Fd::Fd(Fd&& other) noexcept : value_(other.release()) {}
Fd& Fd::operator=(Fd&& other) noexcept {
  if (this != &other) reset(other.release());
  return *this;
}
int Fd::release() noexcept { int result = value_; value_ = -1; return result; }
void Fd::reset(int value) noexcept {
  // Never retry close: EINTR does not safely identify an open descriptor.
  if (value_ >= 0) ::close(value_);
  value_ = value;
}
void systemError(const std::string& operation) {
  int error = errno;
  throw Error(operation + ": " + std::strerror(error));
}
Fd checkedFd(int value, const std::string& operation) {
  if (value < 0) systemError(operation);
  return Fd(value);
}
void closeOnExec(int fd) {
  int flags = fcntl(fd, F_GETFD);
  if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) systemError("fcntl CLOEXEC");
}
void nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) systemError("fcntl NONBLOCK");
}

namespace {
using Doc = std::unique_ptr<xmlDoc, decltype(&xmlFreeDoc)>;
bool named(xmlNode* node, const char* name) { return xmlStrEqual(node->name, BAD_CAST name); }
std::vector<xmlNode*> elements(xmlNode* parent) {
  std::vector<xmlNode*> result;
  for (auto* node = parent->children; node; node = node->next) {
    if (node->type == XML_ELEMENT_NODE) result.push_back(node);
    else if (node->type == XML_COMMENT_NODE) continue;
    else if (node->type == XML_TEXT_NODE && xmlIsBlankNode(node)) continue;
    else throw Error("unexpected XML content");
  }
  return result;
}
std::string text(xmlNode* node) {
  std::string result;
  for (auto* child = node->children; child; child = child->next) {
    if (child->type != XML_TEXT_NODE && child->type != XML_CDATA_SECTION_NODE)
      throw Error("nested elements or entities in scalar value");
    if (child->content) result += reinterpret_cast<const char*>(child->content);
  }
  return result;
}
Value parse(xmlNode* node, unsigned depth, std::size_t& count) {
  if (depth > 32 || ++count > 16384) throw Error("plist exceeds structural limits");
  if (node->properties || node->ns || node->nsDef) throw Error("attributes and namespaces are not allowed on plist values");
  if (named(node, "string")) return Value(text(node));
  if (named(node, "integer")) {
    auto value = text(node);
    std::int64_t number;
    auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), number);
    if (error != std::errc{} || end != value.data() + value.size()) throw Error("invalid integer");
    return Value(number);
  }
  if (named(node, "true") || named(node, "false")) {
    if (node->children) throw Error("boolean must be empty");
    return Value(named(node, "true"));
  }
  auto children = elements(node);
  if (named(node, "array")) {
    Value::Array result;
    for (auto* child : children) result.push_back(parse(child, depth + 1, count));
    return Value(std::move(result));
  }
  if (named(node, "dict")) {
    if (children.size() % 2) throw Error("dictionary has an unmatched key");
    Value::Dict result;
    for (std::size_t i = 0; i < children.size(); i += 2) {
      if (!named(children[i], "key") || children[i]->properties) throw Error("expected dictionary key");
      auto key = text(children[i]);
      if (!result.emplace(key, parse(children[i + 1], depth + 1, count)).second)
        throw Error("duplicate plist key: " + key);
    }
    return Value(std::move(result));
  }
  throw Error("unsupported plist value");
}
std::string escape(const std::string& value) {
  std::string result;
  for (unsigned char c : value) {
    switch (c) {
      case '&': result += "&amp;"; break;
      case '<': result += "&lt;"; break;
      case '>': result += "&gt;"; break;
      default:
        if (c < 32 && c != '\n' && c != '\r' && c != '\t') throw Error("invalid XML character");
        result += static_cast<char>(c);
    }
  }
  return result;
}
std::string encode(const Value& value) {
  return std::visit([](const auto& item) -> std::string {
    using T = std::decay_t<decltype(item)>;
    if constexpr (std::is_same_v<T, std::string>) return "<string>" + escape(item) + "</string>";
    else if constexpr (std::is_same_v<T, std::int64_t>) return "<integer>" + std::to_string(item) + "</integer>";
    else if constexpr (std::is_same_v<T, bool>) return item ? "<true/>" : "<false/>";
    else {
      std::string result;
      if constexpr (std::is_same_v<T, Value::Array>) {
        result = "<array>";
        for (const auto& child : item) result += encode(child);
        result += "</array>";
      } else {
        result = "<dict>";
        for (const auto& [key, child] : item) result += "<key>" + escape(key) + "</key>" + encode(child);
        result += "</dict>";
      }
      if (result.size() > maxMessage) throw Error("plist exceeds size limit");
      return result;
    }
  }, value.data);
}
} // namespace

std::expected<Value, std::string> parsePlist(const std::string& bytes) {
  try {
    if (bytes.empty() || bytes.size() > maxMessage || bytes.find('\0') != std::string::npos)
      throw Error("invalid plist size or embedded NUL");
    // No NOENT, DTDLOAD, validation, recovery, or network access. Reject internal
    // declarations before parsing, including parameter entities. UTF-8 only.
    if (bytes.find("<!ENTITY") != std::string::npos || bytes.find("<![") != std::string::npos)
      throw Error("entity declarations and CDATA are unsupported");
    Doc doc(xmlReadMemory(bytes.data(), static_cast<int>(bytes.size()), "job.plist", "UTF-8",
                          XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING), xmlFreeDoc);
    if (!doc) throw Error("invalid XML plist");
    if (doc->intSubset && doc->intSubset->children) throw Error("internal DTD declarations are unsupported");
    auto* root = xmlDocGetRootElement(doc.get());
    if (!root || !named(root, "plist") || root->ns || root->nsDef) throw Error("expected plist root");
    for (auto* attr = root->properties; attr; attr = attr->next) {
      if (!xmlStrEqual(attr->name, BAD_CAST "version") || attr->ns) throw Error("unsupported plist attribute");
      if (!attr->children || attr->children->next || attr->children->type != XML_TEXT_NODE ||
          !xmlStrEqual(attr->children->content, BAD_CAST "1.0")) throw Error("unsupported plist version");
    }
    auto children = elements(root);
    if (children.size() != 1) throw Error("plist must contain exactly one value");
    std::size_t count = 0;
    return parse(children[0], 0, count);
  } catch (const std::exception& error) { return std::unexpected(std::string(error.what())); }
}
std::string writePlist(const Value& value) {
  auto bytes = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\">" + encode(value) + "</plist>";
  if (bytes.size() > maxMessage) throw Error("plist exceeds size limit");
  return bytes;
}
std::string readFile(const std::string& path, bool trusted) {
  auto fd = checkedFd(open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK), "open " + path);
  struct stat st{};
  if (fstat(fd.get(), &st) < 0) systemError("fstat");
  if (!S_ISREG(st.st_mode) || st.st_size < 0 || static_cast<std::uint64_t>(st.st_size) > maxMessage)
    throw Error("plist must be a regular file of at most 1 MiB");
  if (trusted && (st.st_uid != 0 || (st.st_mode & 0022))) throw Error("system plist must be root-owned and not group/world writable");
  std::string bytes;
  char buffer[4096];
  for (;;) {
    auto count = read(fd.get(), buffer, sizeof buffer);
    if (count < 0) { if (errno == EINTR) continue; systemError("read plist"); }
    if (!count) break;
    bytes.append(buffer, static_cast<std::size_t>(count));
    if (bytes.size() > maxMessage) throw Error("plist exceeds size limit");
  }
  return bytes;
}
std::uint32_t frameSize(const char* bytes) noexcept {
  auto* p = reinterpret_cast<const unsigned char*>(bytes);
  return (std::uint32_t(p[0]) << 24) | (std::uint32_t(p[1]) << 16) | (std::uint32_t(p[2]) << 8) | p[3];
}
std::string frame(const Value& value) {
  auto bytes = writePlist(value);
  auto size = static_cast<std::uint32_t>(bytes.size());
  std::string result;
  for (int shift : {24, 16, 8, 0}) result += static_cast<char>((size >> shift) & 255);
  return result + bytes;
}
const Value& required(const Value::Dict& dict, const std::string& key) {
  auto it = dict.find(key);
  if (it == dict.end()) throw Error("missing field: " + key);
  return it->second;
}
std::string stringField(const Value::Dict& dict, const std::string& key) { return required(dict, key).as<std::string>(); }
Value reply(bool ok, const std::string& message, Value::Array jobs) {
  return Value(Value::Dict{{"Version", Value(std::int64_t(1))}, {"OK", Value(ok)},
                          {"Message", Value(message)}, {"Jobs", Value(std::move(jobs))}});
}
} // namespace md
