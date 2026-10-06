#include "common.hpp"
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <iostream>
#include <memory>
#include <cstdlib>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace {
using namespace md;
void ready(int fd, short events, Clock::time_point deadline) {
  for (;;) {
    auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
    if (remaining <= 0) throw Error("control request timed out");
    pollfd item{fd, events, 0};
    int result = poll(&item, 1, static_cast<int>(remaining));
    if (result < 0) { if (errno == EINTR) continue; systemError("poll"); }
    if (!result) throw Error("control request timed out");
    if (item.revents & events) return;
    throw Error("control socket disconnected");
  }
}
void transfer(int fd, char* bytes, std::size_t size, bool output, Clock::time_point deadline) {
  std::size_t offset = 0;
  while (offset < size) {
    ready(fd, output ? POLLOUT : POLLIN, deadline);
    auto count = output ? send(fd, bytes + offset, size - offset, 0) : read(fd, bytes + offset, size - offset);
    if (count > 0) offset += static_cast<std::size_t>(count);
    else if (!count) throw Error("control socket disconnected");
    else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) systemError("control I/O");
  }
}
} // namespace

int main(int argc, char** argv) {
  using namespace md;
  try {
    std::string path = defaultSocket;
    int i = 1;
    if (i < argc && std::string(argv[i]) == "--socket") {
      if (++i >= argc) throw Error("--socket requires a path");
      path = argv[i++];
    }
    if (i >= argc) throw Error("usage: launchctl [--socket PATH] load|unload|list|start|stop|enable|disable|reboot [ARGUMENT]");
    std::string command = argv[i++], argument;
    if (i < argc) argument = argv[i++];
    // `reboot` alone is Apple's `reboot system`.
    if (command == "reboot" && argument.empty()) argument = "system";
    if (i != argc || (command != "list" && command != "load" && command != "unload" && command != "start" && command != "stop" &&
         command != "enable" && command != "disable" && command != "reboot") ||
        (command != "list" && argument.empty())) throw Error("invalid command or argument count");
    if (path.empty() || path.front() != '/' || path.size() >= sizeof(sockaddr_un::sun_path)) throw Error("invalid socket path");
    if (command == "load") {
      if (argument.front() != '/') {
        char* raw = realpath(argument.c_str(), nullptr);
        if (!raw) systemError("resolve plist path");
        std::unique_ptr<char, decltype(&std::free)> owned(raw, std::free);
        argument = owned.get();
      }
    }
    struct sigaction ignore{}; ignore.sa_handler = SIG_IGN; sigemptyset(&ignore.sa_mask);
    if (sigaction(SIGPIPE, &ignore, nullptr) < 0) systemError("ignore SIGPIPE");
    auto socket = checkedFd(::socket(AF_UNIX, SOCK_STREAM, 0), "socket");
    closeOnExec(socket.get()); nonblocking(socket.get());
    sockaddr_un address{}; address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    auto deadline = Clock::now() + ioTimeout;
    if (connect(socket.get(), reinterpret_cast<sockaddr*>(&address), sizeof address) < 0) {
      if (errno != EINPROGRESS) systemError("connect");
      ready(socket.get(), POLLOUT, deadline);
      int error = 0; socklen_t size = sizeof error;
      if (getsockopt(socket.get(), SOL_SOCKET, SO_ERROR, &error, &size) < 0) systemError("connect status");
      if (error) { errno = error; systemError("connect"); }
    }
    auto request = frame(Value(Value::Dict{{"Version", Value(std::int64_t(1))},
      {"Command", Value(command)}, {"Argument", Value(argument)}}));
    transfer(socket.get(), request.data(), request.size(), true, deadline);
    char header[4]; transfer(socket.get(), header, sizeof header, false, deadline);
    auto size = frameSize(header);
    if (!size || size > maxMessage) throw Error("invalid response length");
    std::string bytes(size, '\0'); transfer(socket.get(), bytes.data(), bytes.size(), false, deadline);
    auto value = parsePlist(bytes);
    if (!value) throw Error("invalid response: " + value.error());
    const auto& dict = value->as<Value::Dict>();
    if (required(dict, "Version").as<std::int64_t>() != 1) throw Error("unsupported response version");
    if (!required(dict, "OK").as<bool>()) throw Error(stringField(dict, "Message"));
    if (command == "list") {
      std::cout << "PID\tSTATE\tEXIT\tLABEL\tLAUNCH ERROR\n";
      for (const auto& item : required(dict, "Jobs").as<Value::Array>()) {
        const auto& job = item.as<Value::Dict>();
        std::string exit = "-";
        if (auto it = job.find("ExitStatus"); it != job.end()) exit = std::to_string(it->second.as<std::int64_t>());
        if (auto it = job.find("ExitSignal"); it != job.end()) exit = "signal:" + std::to_string(it->second.as<std::int64_t>());
        std::cout << required(job, "PID").as<std::int64_t>() << '\t' << stringField(job, "State") << '\t'
                  << exit << '\t' << stringField(job, "Label") << '\t' << stringField(job, "LaunchError") << '\n';
      }
    } else std::cout << stringField(dict, "Message") << '\n';
    return 0;
  } catch (const std::exception& error) { std::cerr << "launchctl: " << error.what() << '\n'; return 1; }
}
