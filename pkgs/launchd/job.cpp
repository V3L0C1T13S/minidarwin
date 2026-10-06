#include "job.hpp"
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <grp.h>
#include <limits>
#include <set>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace md {
namespace {
std::string scalarString(const Value& value) {
  auto result = value.as<std::string>();
  if (result.find('\0') != std::string::npos) throw Error("embedded NUL in string");
  return result;
}
std::string absolutePath(const Value& value) {
  auto result = scalarString(value);
  if (result.empty() || result.front() != '/') throw Error("path must be absolute");
  return result;
}
std::int64_t integer(const Value& value, std::int64_t limit) {
  auto number = value.as<std::int64_t>();
  if (number < 0 || number > limit) throw Error("integer out of range");
  return number;
}
Fd stdioFile(const std::string& path, bool input) {
  auto fd = checkedFd(open(path.c_str(), (input ? O_RDONLY : O_WRONLY | O_CREAT | O_APPEND) |
                         O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600), "open stdio " + path);
  struct stat st{};
  if (fstat(fd.get(), &st) < 0) systemError("fstat stdio");
  if (!S_ISREG(st.st_mode) && !(S_ISCHR(st.st_mode) && (path == "/dev/null" || path == "/dev/console")))
    throw Error("stdio must be a regular file, /dev/null or /dev/console");
  int flags = fcntl(fd.get(), F_GETFL);
  if (flags < 0 || fcntl(fd.get(), F_SETFL, flags & ~O_NONBLOCK) < 0) systemError("fcntl stdio");
  return fd;
}
} // namespace
bool validIdentifier(const std::string& value) {
  if (value.empty() || value.size() > 255) return false;
  for (unsigned char c : value)
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'))
      return false;
  return true;
}
namespace {
// Apple's per-socket keys, restricted to what a Unix stream listener needs.
SocketConfig socketConfig(const std::string& name, const Value& value) {
  static const std::set<std::string> keys = {"SockPathName", "SockPathMode", "SockType", "SockFamily", "SockPassive"};
  const auto& dict = value.as<Value::Dict>();
  for (const auto& [key, unused] : dict) if (!keys.contains(key)) throw Error("unsupported socket key: " + key);
  SocketConfig result;
  result.name = name;
  result.path = absolutePath(required(dict, "SockPathName"));
  if (result.path.size() >= sizeof(sockaddr_un::sun_path)) throw Error("SockPathName is too long");
  if (auto it = dict.find("SockPathMode"); it != dict.end()) result.mode = static_cast<mode_t>(integer(it->second, 0777));
  if (auto it = dict.find("SockType"); it != dict.end() && scalarString(it->second) != "stream")
    throw Error("only stream sockets are supported");
  if (auto it = dict.find("SockFamily"); it != dict.end() && scalarString(it->second) != "Unix")
    throw Error("only Unix sockets are supported");
  if (auto it = dict.find("SockPassive"); it != dict.end() && !it->second.as<bool>())
    throw Error("only passive (listening) sockets are supported");
  return result;
}
[[noreturn]] void childFailure(int fd, int error) noexcept {
  const char* bytes = reinterpret_cast<const char*>(&error);
  std::size_t offset = 0;
  while (offset < sizeof error) {
    auto n = write(fd, bytes + offset, sizeof error - offset);
    if (n > 0) offset += static_cast<std::size_t>(n);
    else if (n < 0 && errno == EINTR) continue;
    else break;
  }
  _exit(127);
}
} // namespace

std::expected<Config, std::string> parseConfig(const Value& value, bool foreground) {
  try {
    const auto& dict = value.as<Value::Dict>();
    static const std::set<std::string> keys = {"Label", "Program", "ProgramArguments", "RunAtLoad",
      "KeepAlive", "Disabled", "ThrottleInterval", "ExitTimeOut", "EnvironmentVariables", "WorkingDirectory",
      "StandardInPath", "StandardOutPath", "StandardErrorPath", "UserID", "GroupID", "SupplementaryGroups", "Sockets"};
    for (const auto& [key, unused] : dict) if (!keys.contains(key)) throw Error("unsupported job key: " + key);
    Config config;
    config.label = scalarString(required(dict, "Label"));
    if (config.label.empty() || config.label.size() > 255) throw Error("Label must have 1 to 255 characters");
    if (!validIdentifier(config.label)) throw Error("Label contains invalid characters");
    if (auto it = dict.find("ProgramArguments"); it != dict.end()) {
      for (const auto& arg : it->second.as<Value::Array>()) config.arguments.push_back(scalarString(arg));
      if (config.arguments.empty() || config.arguments.front().empty()) throw Error("ProgramArguments must be nonempty");
    }
    if (auto it = dict.find("Program"); it != dict.end()) config.program = absolutePath(it->second);
    else if (!config.arguments.empty()) config.program = absolutePath(Value(config.arguments.front()));
    else throw Error("Program or ProgramArguments is required");
    if (config.arguments.empty()) config.arguments.push_back(config.program);
    auto boolean = [&](const char* key, bool& result) { if (auto it = dict.find(key); it != dict.end()) result = it->second.as<bool>(); };
    boolean("RunAtLoad", config.runAtLoad); boolean("KeepAlive", config.keepAlive); boolean("Disabled", config.disabled);
    if (auto it = dict.find("ThrottleInterval"); it != dict.end()) config.throttle = static_cast<unsigned>(integer(it->second, 86400));
    if (auto it = dict.find("ExitTimeOut"); it != dict.end()) config.exitTimeout = static_cast<unsigned>(integer(it->second, 86400));
    // Prevent zero-delay crash loops, including configurations requesting zero.
    if (!config.throttle) config.throttle = 1;
    if (auto it = dict.find("WorkingDirectory"); it != dict.end()) config.directory = absolutePath(it->second);
    if (auto it = dict.find("StandardInPath"); it != dict.end()) config.input = absolutePath(it->second);
    if (auto it = dict.find("StandardOutPath"); it != dict.end()) config.output = absolutePath(it->second);
    if (auto it = dict.find("StandardErrorPath"); it != dict.end()) config.error = absolutePath(it->second);
    if (auto it = dict.find("EnvironmentVariables"); it != dict.end()) {
      for (const auto& [name, item] : it->second.as<Value::Dict>()) {
        if (name.empty() || name.find('=') != std::string::npos || name.find('\0') != std::string::npos)
          throw Error("invalid environment name");
        config.environment.emplace(name, scalarString(item));
      }
    }
    if (auto it = dict.find("UserID"); it != dict.end()) config.uid = static_cast<uid_t>(integer(it->second, std::numeric_limits<uid_t>::max() - 1ULL));
    if (auto it = dict.find("GroupID"); it != dict.end()) config.gid = static_cast<gid_t>(integer(it->second, std::numeric_limits<gid_t>::max() - 1ULL));
    if (config.uid.has_value() != config.gid.has_value()) throw Error("UserID and GroupID must be supplied together");
    if (auto it = dict.find("SupplementaryGroups"); it != dict.end()) {
      if (!config.uid) throw Error("SupplementaryGroups requires UserID and GroupID");
      for (const auto& item : it->second.as<Value::Array>())
        config.groups.push_back(static_cast<gid_t>(integer(item, std::numeric_limits<gid_t>::max() - 1ULL)));
      if (config.groups.size() > 16) throw Error("at most 16 supplementary groups supported");
    }
    if (auto it = dict.find("Sockets"); it != dict.end()) {
      const auto& sockets = it->second.as<Value::Dict>();
      if (sockets.empty() || sockets.size() > 16) throw Error("Sockets must name 1 to 16 sockets");
      std::set<std::string> paths;
      for (const auto& [name, item] : sockets) {
        if (!validIdentifier(name)) throw Error("invalid socket name: " + name);
        config.sockets.push_back(socketConfig(name, item));
        if (!paths.insert(config.sockets.back().path).second) throw Error("duplicate SockPathName");
      }
    }
    if (foreground && config.uid) throw Error("identity changes are unavailable in foreground mode");
    if (config.uid && geteuid() != 0) throw Error("identity changes require root");
    return config;
  } catch (const std::exception& error) { return std::unexpected(std::string(error.what())); }
}
Listener::Listener(const SocketConfig& config) : path_(config.path), name(config.name) {
  struct stat st{};
  // A stale socket from an earlier boot is replaced; anything else is not.
  if (lstat(path_.c_str(), &st) == 0) {
    if (!S_ISSOCK(st.st_mode)) throw Error("refusing to replace non-socket " + path_);
    if (unlink(path_.c_str()) < 0) systemError("remove stale socket " + path_);
  } else if (errno != ENOENT) systemError("stat " + path_);
  fd = checkedFd(::socket(AF_UNIX, SOCK_STREAM, 0), "socket");
  closeOnExec(fd.get());
  sockaddr_un address{}; address.sun_family = AF_UNIX;
  std::memcpy(address.sun_path, path_.c_str(), path_.size() + 1);
  if (bind(fd.get(), reinterpret_cast<sockaddr*>(&address), sizeof address) < 0) systemError("bind " + path_);
  if (lstat(path_.c_str(), &st) < 0) { int saved = errno; (void)unlink(path_.c_str()); errno = saved; systemError("stat " + path_); }
  device_ = st.st_dev; inode_ = st.st_ino;
  if (chmod(path_.c_str(), config.mode) < 0 || listen(fd.get(), 128) < 0) {
    int saved = errno; (void)unlink(path_.c_str()); path_.clear(); errno = saved;
    systemError("initialize " + config.path);
  }
}
Listener::Listener(Listener&& other) noexcept
    : path_(std::move(other.path_)), device_(other.device_), inode_(other.inode_),
      name(std::move(other.name)), fd(std::move(other.fd)) { other.path_.clear(); }
Listener::~Listener() noexcept {
  struct stat st{};
  if (!path_.empty() && lstat(path_.c_str(), &st) == 0 && st.st_dev == device_ && st.st_ino == inode_)
    (void)unlink(path_.c_str());
}
const char* stateName(State state) noexcept {
  switch (state) {
    case State::idle: return "idle";
    case State::waiting: return "waiting";
    case State::launching: return "launching";
    case State::running: return "running";
    case State::stopping: return "stopping";
  }
  return "unknown";
}
void spawn(Job& job) {
  job.lastAttempt = Clock::now(); job.attempted = true; job.launchError.clear(); job.execBytes.clear();
  const auto& config = job.config;
  auto input = stdioFile(config.input, true), output = stdioFile(config.output, false), error = stdioFile(config.error, false);
  int descriptors[2];
  if (pipe(descriptors) < 0) systemError("pipe");
  Fd reader(descriptors[0]), writer(descriptors[1]);
  closeOnExec(reader.get()); closeOnExec(writer.get()); nonblocking(reader.get());
  std::vector<char*> arguments;
  for (const auto& item : config.arguments) arguments.push_back(const_cast<char*>(item.c_str()));
  arguments.push_back(nullptr);
  auto environment = config.environment;
  environment.try_emplace("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
  // Listeners become descriptors 3, 4, ... in the child, named by one variable.
  const int socketCount = static_cast<int>(job.listeners.size());
  std::vector<int> sources, staging(job.listeners.size(), -1);
  if (socketCount) {
    std::string names;
    for (int i = 0; i < socketCount; ++i) {
      const auto& listener = job.listeners[static_cast<std::size_t>(i)];
      sources.push_back(listener.fd.get());
      names += (i ? " " : "") + listener.name + "=" + std::to_string(3 + i);
    }
    environment[socketsVariable] = names;
  } else environment.erase(socketsVariable);
  std::vector<std::string> entries;
  for (const auto& [name, item] : environment) entries.push_back(name + "=" + item);
  std::vector<char*> env;
  for (auto& item : entries) env.push_back(item.data());
  env.push_back(nullptr);
  sigset_t empty;
  sigemptyset(&empty);
  struct sigaction action{};
  action.sa_handler = SIG_DFL; sigemptyset(&action.sa_mask);
  const int descriptorLimit = getdtablesize();
  if (descriptorLimit <= 0) systemError("getdtablesize");
  pid_t pid = fork();
  if (pid < 0) systemError("fork");
  if (!pid) {
    int pipeFd = writer.get();
    // No C++ allocation, exceptions, destructor execution, or library parsing
    // after fork. close-on-exec descriptors prevent unrelated FD inheritance.
    if (setpgid(0, 0) < 0 || sigprocmask(SIG_SETMASK, &empty, nullptr) < 0) childFailure(pipeFd, errno);
    for (int signal = 1; signal < NSIG; ++signal) {
      if (signal == SIGKILL || signal == SIGSTOP) continue;
      if (sigaction(signal, &action, nullptr) < 0 && errno != EINVAL) childFailure(pipeFd, errno);
    }
    if (dup2(input.get(), 0) < 0 || dup2(output.get(), 1) < 0 || dup2(error.get(), 2) < 0) childFailure(pipeFd, errno);
    if (socketCount) {
      // Move everything clear of 3..3+n first: any source or the error pipe
      // may already occupy a target slot. dup2 leaves the targets inheritable.
      int moved = fcntl(pipeFd, F_DUPFD_CLOEXEC, 3 + socketCount);
      if (moved < 0) childFailure(pipeFd, errno);
      pipeFd = moved;
      for (int i = 0; i < socketCount; ++i)
        if ((staging[static_cast<std::size_t>(i)] = fcntl(sources[static_cast<std::size_t>(i)], F_DUPFD_CLOEXEC, 3 + socketCount)) < 0)
          childFailure(pipeFd, errno);
      for (int i = 0; i < socketCount; ++i)
        if (dup2(staging[static_cast<std::size_t>(i)], 3 + i) < 0) childFailure(pipeFd, errno);
    }
    if (!config.directory.empty() && chdir(config.directory.c_str()) < 0) childFailure(pipeFd, errno);
    if (config.uid && (setgroups(static_cast<int>(config.groups.size()), config.groups.data()) < 0 ||
                       setgid(*config.gid) < 0 || setuid(*config.uid) < 0)) childFailure(pipeFd, errno);
    for (int fd = 3 + socketCount; fd < descriptorLimit; ++fd) if (fd != pipeFd) (void)close(fd);
    execve(config.program.c_str(), arguments.data(), env.data());
    childFailure(pipeFd, errno);
  }
  // Everything after fork is nonthrowing: ownership is recorded immediately.
  job.pid = pid; job.state = State::launching; job.execError = std::move(reader);
  // The child also calls setpgid. ESRCH/EACCES mean it already exited/execed.
  (void)setpgid(pid, pid);
}
void drainExecError(Job& job) {
  if (job.execError.get() < 0) return;
  char bytes[sizeof(int)];
  for (;;) {
    auto count = read(job.execError.get(), bytes, sizeof bytes);
    if (count > 0) {
      job.execBytes.append(bytes, static_cast<std::size_t>(count));
      if (job.execBytes.size() > sizeof(int)) { job.launchError = "invalid child setup response"; job.execError.reset(); return; }
    } else if (!count) {
      if (!job.execBytes.empty()) {
        if (job.execBytes.size() == sizeof(int)) {
          int error; std::memcpy(&error, job.execBytes.data(), sizeof error);
          job.launchError = std::strerror(error);
        } else job.launchError = "incomplete child setup response";
      } else if (job.state == State::launching) job.state = State::running;
      job.execError.reset(); return;
    } else if (errno == EINTR) continue;
    else if (errno == EAGAIN || errno == EWOULDBLOCK) return;
    else { job.launchError = "cannot read child setup response"; job.execError.reset(); return; }
  }
}
Value jobStatus(const Job& job) {
  Value::Dict result{{"Label", Value(job.config.label)}, {"State", Value(std::string(stateName(job.state)))},
    {"PID", Value(std::int64_t(job.pid))}, {"LaunchError", Value(job.launchError)}, {"Enabled", Value(job.enabled)}};
  if (job.exitStatus) result.emplace("ExitStatus", Value(std::int64_t(*job.exitStatus)));
  if (job.exitSignal) result.emplace("ExitSignal", Value(std::int64_t(*job.exitSignal)));
  return Value(std::move(result));
}
} // namespace md
