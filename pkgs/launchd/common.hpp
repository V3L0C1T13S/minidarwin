#pragma once

#include <chrono>
#include <cstdint>
#include <expected>
#include <map>
#include <stdexcept>
#include <string>
#include <variant>
#include <vector>

namespace md {
using Clock = std::chrono::steady_clock;
constexpr std::size_t maxMessage = 1024 * 1024;
constexpr auto ioTimeout = std::chrono::seconds(5);

// A descriptor has exactly one owner; move transfers that ownership.
class Fd {
  int value_ = -1;
public:
  explicit Fd(int value = -1) noexcept : value_(value) {}
  ~Fd() noexcept;
  Fd(const Fd&) = delete;
  Fd& operator=(const Fd&) = delete;
  Fd(Fd&& other) noexcept;
  Fd& operator=(Fd&& other) noexcept;
  int get() const noexcept { return value_; }
  int release() noexcept;
  void reset(int value = -1) noexcept;
};

struct Error : std::runtime_error { using std::runtime_error::runtime_error; };
[[noreturn]] void systemError(const std::string& operation);
Fd checkedFd(int value, const std::string& operation);
void nonblocking(int fd);
void closeOnExec(int fd);

struct Value {
  using Array = std::vector<Value>;
  using Dict = std::map<std::string, Value>;
  std::variant<std::string, std::int64_t, bool, Array, Dict> data;
  Value() : data(Dict{}) {}
  template<class T> explicit Value(T value) : data(std::move(value)) {}
  template<class T> const T& as() const {
    auto* value = std::get_if<T>(&data);
    if (!value) throw Error("incorrect plist value type");
    return *value;
  }
};
// lenient also accepts <real>, <date> and <data>, as their text.
std::expected<Value, std::string> parsePlist(const std::string& bytes, bool lenient = false);
std::string writePlist(const Value& value);
std::string readFile(const std::string& path, bool trusted);
std::string frame(const Value& value);
std::uint32_t frameSize(const char* bytes) noexcept;
const Value& required(const Value::Dict& dict, const std::string& key);
std::string stringField(const Value::Dict& dict, const std::string& key);
Value reply(bool ok, const std::string& message, Value::Array jobs = {});

constexpr const char* defaultSocket = "/private/var/run/minidarwin-launchd/control.sock";
constexpr const char* defaultOverrides = "/private/var/db/minidarwin-launchd/disabled.plist";
// Activated jobs find their listening sockets here: "Name=3 Other=4".
constexpr const char* socketsVariable = "MINIDARWIN_LAUNCHD_SOCKETS";
} // namespace md
