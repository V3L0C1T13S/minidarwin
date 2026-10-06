#include "job.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <cstdlib>
#include <ctime>
#include <dirent.h>
#include <fcntl.h>
#include <iostream>
#include <libproc.h>
#include <memory>
#include <signal.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/proc.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

namespace md {
namespace {
void log(const std::string& message) { std::cerr << "minidarwin launchd: " << message << '\n'; }
struct Options {
  bool foreground = false;
  std::string socket = defaultSocket;
  std::string overrides = defaultOverrides;
  std::vector<std::string> directories;
};
Options options(int argc, char** argv) {
  Options result;
  bool socketSet = false, overridesSet = false;
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--foreground") result.foreground = true;
    else if (arg == "--socket" && i + 1 < argc) { result.socket = argv[++i]; socketSet = true; }
    else if (arg == "--jobs-dir" && i + 1 < argc) result.directories.emplace_back(argv[++i]);
    else if (arg == "--overrides" && i + 1 < argc) { result.overrides = argv[++i]; overridesSet = true; }
    else throw Error("usage: launchd [--foreground --socket PATH --jobs-dir PATH ... [--overrides PATH]]");
  }
  if (overridesSet && !result.foreground) throw Error("custom paths require foreground mode");
  if (result.foreground) {
    // Without --overrides a development instance has no database at all.
    if (!overridesSet) result.overrides.clear();
    else if (result.overrides.empty() || result.overrides.front() != '/') throw Error("overrides path must be absolute");
    else if (result.overrides == defaultOverrides) throw Error("foreground mode requires a private overrides path");
  }
  if (result.foreground) {
    if (!socketSet || result.directories.empty()) throw Error("foreground mode requires --socket and --jobs-dir");
    if (result.socket.empty() || result.socket.front() != '/') throw Error("socket path must be absolute");
    auto slash = result.socket.find_last_of('/');
    auto name = result.socket.substr(slash + 1);
    if (name.empty() || name == "." || name == "..") throw Error("invalid socket filename");
    auto parent = result.socket.substr(0, slash);
    char* resolvedParent = realpath(parent.empty() ? "/" : parent.c_str(), nullptr);
    if (!resolvedParent) systemError("resolve socket directory");
    std::unique_ptr<char, decltype(&std::free)> ownedParent(resolvedParent, std::free);
    result.socket = std::string(ownedParent.get()) + "/" + name;
    if (result.socket == defaultSocket) throw Error("foreground mode requires a private socket path");
    for (auto& path : result.directories) {
      char* resolved = realpath(path.c_str(), nullptr);
      if (!resolved) systemError("resolve job directory");
      std::unique_ptr<char, decltype(&std::free)> owned(resolved, std::free);
      path = owned.get();
      if (path == "/System/Library/LaunchDaemons" || path == "/Library/LaunchDaemons")
        throw Error("foreground mode cannot load system job directories");
    }
  } else {
    if (getpid() != 1) throw Error("normal invocation requires PID 1; use explicit foreground mode for development");
    if (socketSet || !result.directories.empty()) throw Error("custom paths require foreground mode");
    result.directories = {"/System/Library/LaunchDaemons", "/Library/LaunchDaemons"};
  }
  if (result.socket.empty() || result.socket.front() != '/' || result.socket.size() >= sizeof(sockaddr_un::sun_path))
    throw Error("socket path must be absolute and fit sockaddr_un");
  for (const auto& path : result.directories)
    if (path.empty() || path.front() != '/') throw Error("job directory must be absolute");
  return result;
}

// Keeps the lock inode in place. Unlinking a lock file allows two independent
// locks on different inodes, so only the socket is removed on destruction.
class Endpoint {
  std::string path_;
  dev_t device_ = 0;
  ino_t inode_ = 0;
  bool owned_ = false;
public:
  Fd lock, socket;
  explicit Endpoint(const Options& opts) : path_(opts.socket) {
    auto parent = path_.substr(0, path_.find_last_of('/'));
    if (!opts.foreground && mkdir(parent.c_str(), 0700) < 0 && errno != EEXIST) systemError("mkdir socket directory");
    struct stat st{};
    if (lstat(parent.c_str(), &st) < 0) systemError("stat socket directory");
    if (!S_ISDIR(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & 0022))
      throw Error("socket directory must be owned by launchd's UID and not group/world writable");
    lock = checkedFd(open((path_ + ".lock").c_str(), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600), "open singleton lock");
    if (fstat(lock.get(), &st) < 0) systemError("stat singleton lock");
    if (!S_ISREG(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & 0077) || st.st_nlink != 1)
      throw Error("unsafe singleton lock");
    if (flock(lock.get(), LOCK_EX | LOCK_NB) < 0) throw Error("another launchd owns this endpoint");
    if (lstat(path_.c_str(), &st) == 0) {
      if (!S_ISSOCK(st.st_mode) || st.st_uid != geteuid()) throw Error("refusing to replace unsafe socket path");
      if (unlink(path_.c_str()) < 0) systemError("remove stale socket");
    } else if (errno != ENOENT) systemError("stat socket");
    socket = checkedFd(::socket(AF_UNIX, SOCK_STREAM, 0), "socket");
    closeOnExec(socket.get()); nonblocking(socket.get());
    sockaddr_un address{}; address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path_.c_str(), path_.size() + 1);
    if (bind(socket.get(), reinterpret_cast<sockaddr*>(&address), sizeof address) < 0) systemError("bind");
    // Record ownership before later fallible setup, with constructor cleanup.
    try {
      if (lstat(path_.c_str(), &st) < 0) systemError("stat bound socket");
      device_ = st.st_dev; inode_ = st.st_ino; owned_ = true;
      if (chmod(path_.c_str(), 0600) < 0 || listen(socket.get(), 32) < 0) systemError("initialize control socket");
    } catch (...) { cleanup(); throw; }
  }
  void cleanup() noexcept {
    struct stat st{};
    if (owned_ && lstat(path_.c_str(), &st) == 0 && st.st_dev == device_ && st.st_ino == inode_)
      (void)unlink(path_.c_str());
    owned_ = false;
  }
  ~Endpoint() noexcept { cleanup(); }
};
struct Client {
  Fd fd;
  std::string input, output;
  std::size_t sent = 0;
  Clock::time_point deadline = Clock::now() + ioTimeout;
  uintptr_t generation;
  Client(Fd value, uintptr_t token) : fd(std::move(value)), generation(token) {}
};
class Supervisor {
  Options options_;
  Endpoint endpoint_;
  Fd queue_;
  std::map<std::string, Job> jobs_;
  std::map<int, Client> clients_;
  // Label -> disabled, as `launchctl enable/disable` last recorded it.
  std::map<std::string, bool> overrides_;
  bool shuttingDown_ = false;
  std::time_t shutdownWall_ = 0;
  Clock::time_point stillAlive_{};
  int rebootFlags_ = RB_AUTOBOOT;
  uintptr_t nextClient_ = 1;

  void watch(int fd, short filter, uintptr_t generation = 0) {
    struct kevent change{};
    EV_SET(&change, static_cast<uintptr_t>(fd), filter, EV_ADD | EV_ONESHOT, 0, 0, reinterpret_cast<void*>(generation));
    if (kevent(queue_.get(), &change, 1, nullptr, 0, nullptr) < 0) systemError("kevent register");
  }
  // job_stop: SIGTERM once, then SIGKILL after ExitTimeOut. As in Apple's
  // launchd, an ExitTimeOut of zero is infinite: the job is never escalated.
  void stop(Job& job) {
    job.enabled = false;
    if (!job.pid) { job.state = State::idle; return; }
    if (job.state == State::stopping) return;
    job.state = State::stopping;
    job.stopDeadline = job.config.exitTimeout ? Clock::now() + std::chrono::seconds(job.config.exitTimeout)
                                              : Clock::time_point::max();
    if (!job.config.exitTimeout) log(job.config.label + ": this job has an infinite exit timeout");
    if (kill(-job.pid, SIGTERM) < 0 && errno != ESRCH) log("SIGTERM " + job.config.label + ": " + std::strerror(errno));
  }
  // job_kill, and the exit_timeout timer that follows it: a group still alive
  // LAUNCHD_SIGKILL_TIMER seconds after SIGKILL is treated as exited, so that
  // one wedged process cannot hold shutdown (or a restart) forever. Its zombie
  // is reaped as an unmanaged child whenever it finally dies.
  static constexpr auto sigkillTimer = std::chrono::seconds(4);
  void escalate(Job& job, Clock::time_point now) {
    if (job.state != State::stopping) return;
    if (!job.killed && now >= job.stopDeadline) {
      log(job.config.label + ": exit timeout elapsed (" + std::to_string(job.config.exitTimeout) + " seconds); killing");
      if (kill(-job.pid, SIGKILL) < 0 && errno != ESRCH) log("SIGKILL failed: " + job.config.label);
      job.killed = true; job.killDeadline = now + sigkillTimer;
    } else if (job.killed && now >= job.killDeadline) {
      log(job.config.label + ": has not died after being killed " + std::to_string(sigkillTimer.count()) +
          " seconds ago; simulating exit");
      exited(job);
      job.launchError = "simulated exit: PID did not die after SIGKILL";
    }
  }
  // The bookkeeping half of job_reap/job_dispatch, shared with simulated exit.
  void exited(Job& job) {
    job.pid = 0; job.killed = false; job.execError.reset();
    job.exitStatus.reset(); job.exitSignal.reset();
    job.state = job.enabled && job.config.keepAlive && !shuttingDown_ ? State::waiting : State::idle;
  }
  void start(Job& job) {
    if (job.remove || job.state == State::stopping) throw Error("job is stopping");
    job.enabled = true;
    if (!job.pid) job.state = State::waiting;
  }
  void load(const std::string& path) {
    auto value = parsePlist(readFile(path, !options_.foreground));
    if (!value) throw Error(value.error());
    auto config = parseConfig(*value, options_.foreground);
    if (!config) throw Error(config.error());
    // As in Apple's launchd, a recorded override beats the plist's Disabled.
    bool disabled = config->disabled;
    if (auto it = overrides_.find(config->label); it != overrides_.end()) disabled = it->second;
    if (disabled) throw Error(config->disabled && !overrides_.contains(config->label) ? "job is Disabled" : "job is disabled by override");
    if (jobs_.contains(config->label)) throw Error("duplicate job label: " + config->label);
    for (const auto& socket : config->sockets)
      for (const auto& [other, job] : jobs_)
        for (const auto& existing : job.config.sockets)
          if (existing.path == socket.path) throw Error("socket " + socket.path + " is already owned by " + other);
    std::string label = config->label;
    Job job(std::move(*config));
    for (const auto& socket : job.config.sockets) job.listeners.emplace_back(socket);
    if (job.config.runAtLoad || job.config.keepAlive) job.state = State::waiting;
    jobs_.emplace(std::move(label), std::move(job));
  }
  void readOverrides() {
    if (options_.overrides.empty()) return;
    struct stat st{};
    if (lstat(options_.overrides.c_str(), &st) < 0 && errno == ENOENT) return;
    try {
      auto value = parsePlist(readFile(options_.overrides, !options_.foreground));
      if (!value) throw Error(value.error());
      for (const auto& [label, item] : value->as<Value::Dict>()) overrides_[label] = item.as<bool>();
    } catch (const std::exception& error) { overrides_.clear(); log(options_.overrides + ": " + error.what()); }
  }
  void setOverride(std::string label, bool disabled) {
    if (options_.overrides.empty()) throw Error("this launchd has no overrides database");
    if (label.starts_with("system/")) label.erase(0, 7);
    if (!validIdentifier(label)) throw Error("invalid label");
    auto updated = overrides_;
    updated[label] = disabled;
    Value::Dict dict;
    for (const auto& [name, value] : updated) dict.emplace(name, Value(value));
    auto bytes = writePlist(Value(std::move(dict)));
    auto directory = options_.overrides.substr(0, options_.overrides.find_last_of('/'));
    if (!options_.foreground && mkdir(directory.c_str(), 0755) < 0 && errno != EEXIST) systemError("mkdir " + directory);
    // Write a sibling, then rename over the database: readers see old or new.
    auto temporary = options_.overrides + ".new";
    (void)unlink(temporary.c_str());
    {
      auto fd = checkedFd(open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644), "create " + temporary);
      if (fchmod(fd.get(), 0644) < 0) systemError("chmod " + temporary);
      std::size_t offset = 0;
      while (offset < bytes.size()) {
        auto count = write(fd.get(), bytes.data() + offset, bytes.size() - offset);
        if (count < 0) { if (errno == EINTR) continue; systemError("write " + temporary); }
        offset += static_cast<std::size_t>(count);
      }
      if (fsync(fd.get()) < 0) systemError("fsync " + temporary);
    }
    if (rename(temporary.c_str(), options_.overrides.c_str()) < 0) systemError("rename " + temporary);
    overrides_ = std::move(updated);
  }
  // Termination follows Apple's launchd (launchd_shutdown, jobmgr_shutdown,
  // jobmgr_do_garbage_collection and jobmgr_remove in core.c), less the Mach,
  // shutdown-monitor and dirty-at-shutdown machinery this launchd does not have.
  static std::string date(std::time_t when) {
    std::tm parts{};
    char text[32];
    if (!localtime_r(&when, &parts) || !std::strftime(text, sizeof text, "%a %b %e %H:%M:%S %Y", &parts)) return "?";
    return text;
  }
  static constexpr auto stillAliveInterval = std::chrono::seconds(5);
  // launchd_shutdown. Idempotent, but a later reboot request still sets the
  // flags used at the end, as reboot2() does.
  void shutdown() {
    if (shuttingDown_) return;
    shuttingDown_ = true;
    log(options_.foreground ? "launchd termination began" : "system shutdown began");
    shutdownWall_ = std::time(nullptr);
    log("userspace shutdown begun at: " + date(shutdownWall_));
    stillAlive_ = Clock::now() + stillAliveInterval;
    (void)collectGarbage();
  }
  // jobmgr_do_garbage_collection: a job with no process is removed outright,
  // which closes and unlinks its sockets; every other job is stopped. Run
  // after each reap while shutting down. True once no job is left.
  bool collectGarbage() {
    for (auto it = jobs_.begin(); it != jobs_.end();) {
      if (!it->second.pid) { it = jobs_.erase(it); continue; }
      stop(it->second);
      ++it;
    }
    return jobs_.empty();
  }
  // jobmgr_still_alive_with_check, on its 5-second timer.
  void reportStillAlive(Clock::time_point now) {
    if (now < stillAlive_) return;
    stillAlive_ = now + stillAliveInterval;
    log("still alive with " + std::to_string(jobs_.size()) + " children");
    for (const auto& [label, job] : jobs_)
      log(label + ": PID " + std::to_string(job.pid) + " is still valid (sent SIGTERM" + (job.killed ? " and SIGKILL)" : ")"));
  }
  // jobmgr_kill_stray_children: whatever is left belongs to no job. Each gets
  // SIGTERM without waiting, since SIGKILLing helpers that back kernel state
  // can lose data (rdar://problem/6562592). Our own zombies are reaped.
  void terminateStrays() {
    int count = proc_listallpids(nullptr, 0);
    if (count <= 0) { log("cannot list processes: " + std::string(std::strerror(errno))); return; }
    std::vector<pid_t> pids(static_cast<std::size_t>(count) + 64);
    count = proc_listallpids(pids.data(), static_cast<int>(pids.size() * sizeof(pid_t)));
    if (count <= 0) { log("cannot list processes: " + std::string(std::strerror(errno))); return; }
    for (int i = 0; i < count && i < static_cast<int>(pids.size()); ++i) {
      pid_t pid = pids[static_cast<std::size_t>(i)];
      if (pid <= 1 || pid == getpid()) continue;
      proc_bsdshortinfo info{};
      if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 1, &info, PROC_PIDT_SHORTBSDINFO_SIZE) <= 0) continue;
      bool zombie = info.pbsi_status == SZOMB;
      log(std::string("stray ") + (zombie ? "zombie " : "") + "process at shutdown: PID " + std::to_string(pid) +
          " PPID " + std::to_string(info.pbsi_ppid) + " PGID " + std::to_string(info.pbsi_pgid) + " " +
          std::string(info.pbsi_comm, strnlen(info.pbsi_comm, sizeof info.pbsi_comm)));
      if (zombie && static_cast<pid_t>(info.pbsi_ppid) == getpid()) { (void)waitpid(pid, nullptr, WNOHANG); continue; }
      log("sending SIGTERM to PID " + std::to_string(pid) + " and continuing");
      if (kill(pid, SIGTERM) < 0 && errno != ESRCH) log("SIGTERM " + std::to_string(pid) + ": " + std::strerror(errno));
    }
  }
  // jobmgr_remove for the root manager. A development instance exits; PID 1
  // terminates the strays and calls reboot(2). Returning means it failed.
  void finishShutdown() {
    auto now = std::time(nullptr);
    auto delta = now - shutdownWall_;
    log("userspace shutdown finished at: " + date(now));
    log("userspace shutdown took approximately " + std::to_string(delta) + " second" + (delta != 1 ? "s" : ""));
    if (options_.foreground) return;
    terminateStrays();
    log(std::string("about to call: reboot(") + (rebootFlags_ & RB_HALT ? "RB_HALT" : "RB_AUTOBOOT") + ")");
    std::cerr.flush();
    if (reboot(rebootFlags_) < 0) log("reboot failed: " + std::string(std::strerror(errno)));
  }
  // On-demand jobs: idle, enabled, and owning listeners waiting for a client.
  static bool activatable(const Job& job) {
    return !job.listeners.empty() && !job.pid && job.state == State::idle && job.enabled && !job.remove;
  }
  void loadDirectories() {
    for (const auto& path : options_.directories) {
      struct stat st{};
      if (lstat(path.c_str(), &st) < 0) { if (errno != ENOENT) log("cannot inspect " + path); continue; }
      if (!S_ISDIR(st.st_mode) || (!options_.foreground && (st.st_uid != 0 || (st.st_mode & 0022)))) {
        log("unsafe job directory: " + path); continue;
      }
      std::unique_ptr<DIR, decltype(&closedir)> dir(opendir(path.c_str()), closedir);
      if (!dir) { log("cannot read " + path); continue; }
      std::vector<std::string> files;
      errno = 0;
      while (auto* entry = readdir(dir.get())) {
        std::string name = entry->d_name;
        if (name.ends_with(".plist")) files.push_back(path + "/" + name);
      }
      if (errno) log("incomplete directory listing: " + path);
      std::sort(files.begin(), files.end());
      for (const auto& file : files) {
        try { load(file); } catch (const std::exception& error) { log(file + ": " + error.what()); }
      }
    }
  }
  Value request(const std::string& bytes) {
    try {
      auto value = parsePlist(bytes);
      if (!value) throw Error(value.error());
      const auto& dict = value->as<Value::Dict>();
      for (const auto& [key, unused] : dict)
        if (key != "Version" && key != "Command" && key != "Argument") throw Error("unknown request field");
      if (required(dict, "Version").as<std::int64_t>() != 1) throw Error("unsupported protocol version");
      auto command = stringField(dict, "Command");
      auto argument = stringField(dict, "Argument");
      if (command == "list") {
        Value::Array result;
        if (!argument.empty()) {
          auto it = jobs_.find(argument);
          if (it == jobs_.end()) throw Error("unknown job label");
          result.push_back(jobStatus(it->second));
        } else for (const auto& [label, job] : jobs_) result.push_back(jobStatus(job));
        return reply(true, "", std::move(result));
      }
      // reboot2(): record how to end, then begin (or continue) shutdown.
      if (command == "reboot") {
        if (argument == "halt") rebootFlags_ = RB_HALT;
        else if (argument == "system") rebootFlags_ = RB_AUTOBOOT;
        else throw Error("reboot takes system or halt");
        shutdown();
        return reply(true, "shutting down");
      }
      if (shuttingDown_) throw Error("launchd is shutting down");
      if (argument.empty()) throw Error("command requires an argument");
      if (command == "load") { load(argument); return reply(true, "loaded"); }
      // Recorded for the next load; neither affects a job already loaded.
      if (command == "disable") { setOverride(argument, true); return reply(true, "disabled"); }
      if (command == "enable") { setOverride(argument, false); return reply(true, "enabled"); }
      auto it = jobs_.find(argument);
      if (it == jobs_.end()) throw Error("unknown job label");
      if (command == "start") start(it->second);
      else if (command == "stop") stop(it->second);
      else if (command == "unload") { it->second.remove = true; stop(it->second); }
      else throw Error("unknown command");
      return reply(true, "accepted");
    } catch (const std::exception& error) { return reply(false, error.what()); }
  }
  void acceptClients() {
    // Bound work per iteration as well as the number of open clients.
    for (unsigned i = 0; i < 32; ++i) {
      int raw = accept(endpoint_.socket.get(), nullptr, nullptr);
      if (raw < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return;
        if (errno == EINTR) continue;
        log("accept failed: " + std::string(std::strerror(errno))); return;
      }
      Fd fd(raw);
      uid_t uid; gid_t gid;
      if (clients_.size() >= 32 || getpeereid(fd.get(), &uid, &gid) < 0 || uid != geteuid()) continue;
      try {
        closeOnExec(fd.get()); nonblocking(fd.get());
        clients_.emplace(raw, Client(std::move(fd), nextClient_++));
      } catch (const std::exception& error) { log(error.what()); }
    }
  }
  bool service(Client& client) {
    if (Clock::now() >= client.deadline) return false;
    if (client.output.empty()) {
      std::array<char, 4096> buffer{};
      // One read per iteration ensures a busy client cannot starve supervision.
      auto count = read(client.fd.get(), buffer.data(), buffer.size());
      if (!count) return false;
      if (count < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
      client.input.append(buffer.data(), static_cast<std::size_t>(count));
      if (client.input.size() >= 4) {
        std::size_t size = frameSize(client.input.data());
        if (!size || size > maxMessage) return false;
        if (client.input.size() > size + 4) return false;
        if (client.input.size() == size + 4) {
          client.output = frame(request(client.input.substr(4)));
          client.deadline = Clock::now() + ioTimeout;
        }
      }
    }
    if (!client.output.empty()) {
      auto count = send(client.fd.get(), client.output.data() + client.sent, client.output.size() - client.sent, 0);
      if (count > 0) client.sent += static_cast<std::size_t>(count);
      else if (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) return false;
      return client.sent < client.output.size();
    }
    return true;
  }
  void reap() {
    for (;;) {
      siginfo_t info{};
      if (waitid(P_ALL, 0, &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
        if (errno == EINTR) continue;
        if (errno != ECHILD) systemError("waitid");
        return;
      }
      if (!info.si_pid) return;
      Job* managed = nullptr;
      for (auto& [label, job] : jobs_) if (job.pid == info.si_pid) { managed = &job; break; }
      if (managed) {
        drainExecError(*managed);
        // Keep the leader's zombie until its group has been signaled. Its PID
        // cannot be reused for an unrelated group while we perform cleanup.
        // XNU reports EPERM, not ESRCH, when that zombie is all that is left.
        if (kill(-info.si_pid, SIGKILL) < 0 && errno != ESRCH && errno != EPERM)
          log("group cleanup failed: " + std::string(std::strerror(errno)));
      }
      int status = 0;
      pid_t result;
      do { result = waitpid(info.si_pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
      if (result != info.si_pid) { if (result < 0) systemError("waitpid"); return; }
      if (managed) {
        exited(*managed);
        if (WIFEXITED(status)) managed->exitStatus = WEXITSTATUS(status);
        if (WIFSIGNALED(status)) managed->exitSignal = WTERMSIG(status);
      }
    }
  }
  void tick() {
    reap();
    auto now = Clock::now();
    for (auto it = jobs_.begin(); it != jobs_.end();) {
      auto& job = it->second;
      if (job.remove && !job.pid) { it = jobs_.erase(it); continue; }
      if (job.pid) {
        drainExecError(job);
        escalate(job, now);
      } else if (job.state == State::waiting && !shuttingDown_ &&
                 (!job.attempted || now >= job.lastAttempt + std::chrono::seconds(job.config.throttle))) {
        try { spawn(job); }
        catch (const std::exception& error) {
          job.launchError = error.what();
          log(job.config.label + ": " + job.launchError);
          job.state = job.enabled && job.config.keepAlive ? State::waiting : State::idle;
        }
      }
      ++it;
    }
  }
public:
  explicit Supervisor(Options opts) : options_(std::move(opts)), endpoint_(options_), queue_(checkedFd(kqueue(), "kqueue")) {
    closeOnExec(queue_.get());
    sigset_t signals; sigemptyset(&signals);
    for (int signal : {SIGCHLD, SIGTERM, SIGINT, SIGHUP}) sigaddset(&signals, signal);
    if (sigprocmask(SIG_BLOCK, &signals, nullptr) < 0) systemError("block signals");
    struct sigaction ignore{}; ignore.sa_handler = SIG_IGN; sigemptyset(&ignore.sa_mask);
    if (sigaction(SIGPIPE, &ignore, nullptr) < 0) systemError("ignore SIGPIPE");
    for (int signal : {SIGCHLD, SIGTERM, SIGINT, SIGHUP}) {
      struct kevent change{};
      EV_SET(&change, static_cast<uintptr_t>(signal), EVFILT_SIGNAL, EV_ADD, 0, 0, nullptr);
      if (kevent(queue_.get(), &change, 1, nullptr, 0, nullptr) < 0) systemError("register signal");
    }
    readOverrides();
    loadDirectories();
  }
  // Returns once shutdown is complete: a development instance then exits, and
  // PID 1 only gets here if reboot(2) failed.
  void run() {
    for (;;) {
      tick();
      if (shuttingDown_) {
        if (collectGarbage()) { finishShutdown(); return; }
        reportStillAlive(Clock::now());
      }
      watch(endpoint_.socket.get(), EVFILT_READ);
      for (const auto& [label, job] : jobs_)
        if (activatable(job) && !shuttingDown_)
          for (const auto& listener : job.listeners) watch(listener.fd.get(), EVFILT_READ);
      for (auto it = clients_.begin(); it != clients_.end();) {
        if (Clock::now() >= it->second.deadline) { it = clients_.erase(it); continue; }
        watch(it->first, it->second.output.empty() ? EVFILT_READ : EVFILT_WRITE, it->second.generation);
        ++it;
      }
      // Also wake for deadlines and setup-pipe progress. No handler performs
      // allocation, logging, or process management.
      std::array<struct kevent, 64> events{};
      timespec timeout{0, 100000000};
      int count = kevent(queue_.get(), nullptr, 0, events.data(), static_cast<int>(events.size()), &timeout);
      if (count < 0) { if (errno == EINTR) continue; systemError("kevent wait"); }
      // Process shutdown signals before accepting any new commands. Apple's
      // launchd ignores SIGINT; only a development instance treats it as SIGTERM.
      for (int i = 0; i < count; ++i) {
        const auto& event = events[static_cast<std::size_t>(i)];
        if (event.filter == EVFILT_SIGNAL && (event.ident == SIGTERM || (event.ident == SIGINT && options_.foreground)))
          shutdown();
      }
      for (int i = 0; i < count; ++i) {
        const auto& event = events[static_cast<std::size_t>(i)];
        if (event.filter == EVFILT_SIGNAL) continue;
        int fd = static_cast<int>(event.ident);
        if (fd == endpoint_.socket.get()) { acceptClients(); continue; }
        // A pending connection on an idle job's listener launches the job; the
        // connection stays queued for it. Stale events on a running job are ignored.
        bool activation = false;
        for (auto& [label, job] : jobs_)
          for (const auto& listener : job.listeners)
            if (listener.fd.get() == fd) {
              activation = true;
              if (activatable(job) && !shuttingDown_) job.state = State::waiting;
            }
        if (activation) continue;
        auto it = clients_.find(fd);
        // A closed descriptor can be reused while older events remain in this
        // returned batch. Only the matching connection generation may consume it.
        if (it != clients_.end() && reinterpret_cast<uintptr_t>(event.udata) == it->second.generation) {
          try {
            if ((event.flags & EV_ERROR) || !service(it->second)) clients_.erase(it);
          } catch (const std::exception& error) { log(error.what()); clients_.erase(fd); }
        }
      }
    }
  }
  // Called on exceptional loop failure while the supervisor still owns jobs.
  // Drain them before the endpoint and job objects are destroyed.
  void emergencyStop() noexcept {
    for (auto& [label, job] : jobs_) if (job.pid) (void)kill(-job.pid, SIGKILL);
    for (auto& [label, job] : jobs_) if (job.pid) {
      int status;
      while (waitpid(job.pid, &status, 0) < 0 && errno == EINTR) {}
      job.pid = 0;
    }
  }
};
} // namespace
} // namespace md

// PID 1 must never exit. Retain child reaping; recovery belongs to later work.
[[noreturn]] static void reapForever() {
  for (;;) {
    while (waitpid(-1, nullptr, WNOHANG) > 0) {}
    timespec delay{1, 0}; nanosleep(&delay, nullptr);
  }
}

int main(int argc, char** argv) {
  // Ensure internally allocated descriptors can never occupy stdio slots.
  // PID 1 starts with none; give it the console so its diagnostics are seen.
  for (int fd = 0; fd < 3; ++fd) if (fcntl(fd, F_GETFD) < 0 && errno == EBADF) {
    int opened = getpid() == 1 ? open("/dev/console", O_RDWR | O_NOCTTY) : -1;
    if (opened < 0) opened = open("/dev/null", O_RDWR);
    if (opened < 0) return 1;
    if (opened != fd) { if (dup2(opened, fd) < 0) return 1; close(opened); }
  }
  umask(0077);
  try {
    md::Supervisor supervisor(md::options(argc, argv));
    try { supervisor.run(); }
    catch (...) { supervisor.emergencyStop(); throw; }
  } catch (const std::exception& error) {
    std::cerr << "minidarwin launchd: " << error.what() << '\n';
    if (getpid() != 1) return 1;
  }
  // Reached by PID 1 only after a failed startup or a failed reboot(2).
  if (getpid() == 1) reapForever();
  return 0;
}
