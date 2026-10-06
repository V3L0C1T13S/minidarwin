#pragma once
// The open protocol's transport (docs/open-protocol.md): a connected AF_UNIX
// stream socket carrying big-endian uint32 length-prefixed XML plists, the
// framing launchd's control socket uses. Descriptors travel as SCM_RIGHTS on
// the first frame only.
#include "../launchd/common.hpp"

#include <optional>
#include <vector>

namespace md::open {
constexpr const char* defaultSocket = "/private/var/run/org.minidarwin.open.sock";
// Client-side override, for tests and alternative daemons.
constexpr const char* socketVariable = "MINIDARWIN_OPEN_SOCKET";
constexpr std::int64_t protocolVersion = 1;
constexpr std::size_t maxDescriptors = 6;
constexpr auto replyTimeout = std::chrono::seconds(30);
constexpr auto noDeadline = Clock::time_point::max();

// Waits for `events` on fd; false on timeout. Throws on poll failure.
bool ready(int fd, short events, Clock::time_point deadline);
void sendFrame(int fd, const Value& value, const std::vector<int>& descriptors, Clock::time_point deadline);
// Reads one frame. With `descriptors` null, any received descriptor is an
// error (and is closed). nullopt means a clean EOF before the frame began.
std::optional<Value> receiveFrame(int fd, Clock::time_point deadline, std::vector<Fd>* descriptors = nullptr);
// Connects to an AF_UNIX stream socket path.
Fd connectTo(const std::string& path, Clock::time_point deadline);

// Typed accessors with protocol-error messages.
const Value::Dict& dict(const Value& value);
std::optional<std::string> optionalString(const Value::Dict& dict, const std::string& key);
bool flag(const Value::Dict& dict, const std::string& key);
} // namespace md::open
