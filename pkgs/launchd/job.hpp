#pragma once
#include "common.hpp"
#include <optional>
#include <sys/types.h>

namespace md {
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
};
std::expected<Config, std::string> parseConfig(const Value& value, bool foreground);

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
  explicit Job(Config value) : config(std::move(value)) {}
};
const char* stateName(State state) noexcept;
void spawn(Job& job);
void drainExecError(Job& job);
Value jobStatus(const Job& job);
} // namespace md
