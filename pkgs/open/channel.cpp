#include "channel.hpp"

#include <array>
#include <cerrno>
#include <cstring>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace md::open {
bool ready(int fd, short events, Clock::time_point deadline) {
  for (;;) {
    int timeout = -1;
    if (deadline != noDeadline) {
      auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
      if (remaining <= 0) return false;
      timeout = static_cast<int>(std::min<long long>(remaining, 1 << 30));
    }
    pollfd item{fd, events, 0};
    int result = poll(&item, 1, timeout);
    if (result < 0) { if (errno == EINTR) continue; systemError("poll"); }
    if (!result) return false;
    // POLLHUP still lets a reader drain what is buffered.
    return true;
  }
}

void sendFrame(int fd, const Value& value, const std::vector<int>& descriptors, Clock::time_point deadline) {
  if (descriptors.size() > maxDescriptors) throw Error("too many descriptors");
  auto bytes = frame(value);
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    if (!ready(fd, POLLOUT, deadline)) throw Error("timed out sending to the open service");
    iovec vector{bytes.data() + offset, bytes.size() - offset};
    msghdr message{};
    message.msg_iov = &vector; message.msg_iovlen = 1;
    alignas(cmsghdr) std::array<char, CMSG_SPACE(sizeof(int) * maxDescriptors)> control{};
    if (!offset && !descriptors.empty()) {
      message.msg_control = control.data();
      message.msg_controllen = static_cast<socklen_t>(CMSG_SPACE(sizeof(int) * descriptors.size()));
      auto* header = CMSG_FIRSTHDR(&message);
      header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS;
      header->cmsg_len = static_cast<socklen_t>(CMSG_LEN(sizeof(int) * descriptors.size()));
      std::memcpy(CMSG_DATA(header), descriptors.data(), sizeof(int) * descriptors.size());
    }
    auto count = sendmsg(fd, &message, 0);
    if (count < 0) {
      if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
      systemError("send");
    }
    offset += static_cast<std::size_t>(count);
  }
}

namespace {
// Reads exactly `size` bytes; returns false on EOF before the first byte.
bool receiveExactly(int fd, char* buffer, std::size_t size, Clock::time_point deadline,
                    std::vector<Fd>* descriptors, bool first) {
  std::size_t offset = 0;
  while (offset < size) {
    if (!ready(fd, POLLIN, deadline)) throw Error("timed out waiting for the open service");
    iovec vector{buffer + offset, size - offset};
    msghdr message{};
    message.msg_iov = &vector; message.msg_iovlen = 1;
    alignas(cmsghdr) std::array<char, CMSG_SPACE(sizeof(int) * maxDescriptors)> control{};
    message.msg_control = control.data();
    message.msg_controllen = static_cast<socklen_t>(control.size());
    auto count = recvmsg(fd, &message, 0);
    if (count < 0) {
      if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
      systemError("receive");
    }
    // Take ownership of anything that arrived before judging it.
    std::vector<Fd> received;
    for (auto* header = CMSG_FIRSTHDR(&message); header; header = CMSG_NXTHDR(&message, header)) {
      if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) continue;
      auto bytes = header->cmsg_len - CMSG_LEN(0);
      for (std::size_t i = 0; i < bytes / sizeof(int); ++i) {
        int raw;
        std::memcpy(&raw, CMSG_DATA(header) + i * sizeof(int), sizeof raw);
        received.emplace_back(raw);
        closeOnExec(raw);
      }
    }
    if (message.msg_flags & MSG_CTRUNC) throw Error("too many descriptors");
    if (!received.empty()) {
      if (!descriptors || !first || offset) throw Error("unexpected descriptors");
      for (auto& item : received) descriptors->push_back(std::move(item));
    }
    if (!count) {
      if (!offset && first) return false;
      throw Error("the open service closed the connection");
    }
    offset += static_cast<std::size_t>(count);
  }
  return true;
}
} // namespace

std::optional<Value> receiveFrame(int fd, Clock::time_point deadline, std::vector<Fd>* descriptors) {
  char header[4];
  if (!receiveExactly(fd, header, sizeof header, deadline, descriptors, true)) return std::nullopt;
  auto size = frameSize(header);
  if (!size || size > maxMessage) throw Error("invalid frame length");
  std::string bytes(size, '\0');
  receiveExactly(fd, bytes.data(), bytes.size(), deadline, nullptr, false);
  auto value = parsePlist(bytes);
  if (!value) throw Error("invalid message: " + value.error());
  return std::move(*value);
}

Fd connectTo(const std::string& path, Clock::time_point deadline) {
  if (path.empty() || path.front() != '/' || path.size() >= sizeof(sockaddr_un::sun_path))
    throw Error("invalid socket path " + path);
  auto socket = checkedFd(::socket(AF_UNIX, SOCK_STREAM, 0), "socket");
  closeOnExec(socket.get()); nonblocking(socket.get());
  sockaddr_un address{}; address.sun_family = AF_UNIX;
  std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  if (connect(socket.get(), reinterpret_cast<sockaddr*>(&address), sizeof address) < 0) {
    if (errno != EINPROGRESS) systemError("connect " + path);
    if (!ready(socket.get(), POLLOUT, deadline)) throw Error("timed out connecting to " + path);
    int error = 0; socklen_t size = sizeof error;
    if (getsockopt(socket.get(), SOL_SOCKET, SO_ERROR, &error, &size) < 0) systemError("connect status");
    if (error) { errno = error; systemError("connect " + path); }
  }
  return socket;
}

const Value::Dict& dict(const Value& value) { return value.as<Value::Dict>(); }
std::optional<std::string> optionalString(const Value::Dict& dict, const std::string& key) {
  auto it = dict.find(key);
  if (it == dict.end()) return std::nullopt;
  auto result = it->second.as<std::string>();
  if (result.find('\0') != std::string::npos) throw Error("embedded NUL in " + key);
  return result;
}
bool flag(const Value::Dict& dict, const std::string& key) {
  auto it = dict.find(key);
  return it != dict.end() && it->second.as<bool>();
}
} // namespace md::open
