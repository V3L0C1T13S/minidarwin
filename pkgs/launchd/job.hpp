#pragma once
#include "common.hpp"
#include <optional>
#include <sys/types.h>

namespace md {
// One `Sockets` entry: a passive AF_UNIX stream socket launchd owns.
struct SocketConfig {
  std::string name, path;
  mode_t mode = 0600;
};
struct Config {
  std::string label, program;
  std::vector<std::string> arguments;
  std::map<std::string, std::string> environment;
  std::string directory, input = "/dev/null", output = "/dev/null", error = "/dev/null";
  bool runAtLoad = false, keepAlive = false, disabled = false;
  unsigned throttle = 10, exitTimeout = 20;
  std::optional<uid_t> uid;
  std::optional<gid_t> gid;
  std::vector<gid_t> groups;
  std::vector<SocketConfig> sockets;
};
// Labels and socket names: 1-255 of [A-Za-z0-9._-].
bool validIdentifier(const std::string& value);
std::expected<Config, std::string> parseConfig(const Value& value, bool foreground);

// A bound, listening socket. Unlinks its path on destruction only if the
// path still names the inode it bound.
class Listener {
  std::string path_;
  dev_t device_ = 0;
  ino_t inode_ = 0;
public:
  std::string name;
  Fd fd;
  explicit Listener(const SocketConfig& config);
  Listener(Listener&& other) noexcept;
  Listener& operator=(Listener&&) = delete;
  ~Listener() noexcept;
};

enum class State { idle, waiting, launching, running, stopping };
struct Job {
  Config config;
  State state = State::idle;
  pid_t pid = 0;
  bool enabled = true, remove = false, attempted = false;
  Clock::time_point lastAttempt{}, stopDeadline{};
  std::optional<int> exitStatus, exitSignal;
  std::string launchError;
  Fd execError;
  std::string execBytes;
  std::vector<Listener> listeners;
  explicit Job(Config value) : config(std::move(value)) {}
};
const char* stateName(State state) noexcept;
void spawn(Job& job);
void drainExecError(Job& job);
Value jobStatus(const Job& job);
} // namespace md
