// /usr/libexec/opend: MiniDarwin's default open service. launchd hands it the
// listening socket on demand; each connection is served by a forked worker
// that takes the caller's credentials before reading anything, resolves the
// items through the handler tables and bundles, launches, and optionally
// waits. Another daemon can replace this one behind the same protocol
// (docs/open-protocol.md).
#include "channel.hpp"

#include <algorithm>
#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <grp.h>
#include <iostream>
#include <memory>
#include <poll.h>
#include <set>
#include <sstream>
#include <sys/event.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/ucred.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {
using namespace md;
using namespace md::open;

void log(const std::string& message) { std::cerr << "opend: " << message << '\n'; }
std::string lower(std::string value) {
  for (auto& c : value) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return value;
}
std::string basename(const std::string& path) {
  auto slash = path.find_last_of('/');
  return slash == std::string::npos ? path : path.substr(slash + 1);
}
std::string dirname(const std::string& path) {
  auto slash = path.find_last_of('/');
  if (slash == std::string::npos) return ".";
  return slash ? path.substr(0, slash) : "/";
}

struct Settings {
  std::string systemHandlers = "/private/etc/open/handlers";
  std::vector<std::string> applications = {"/Applications", "/Applications/Utilities",
                                           "/System/Applications", "/System/Applications/Utilities"};
  bool applicationsSet = false;
  std::optional<std::string> socket;
  unsigned idleSeconds = 30;
  uid_t trustedOwner = 0;
};

// ---- handler tables -------------------------------------------------------
// One line per handler:  selector[,selector...] ; command words ; flag ; ...
// Selectors: ext:EXT type:{directory,executable,text,file} scheme:SCHEME
// app:NAME bundle:ID role:editor. Command words split on blanks; a word that
// is exactly %s becomes the items, else items follow the --args arguments.
// Flags: needsterminal (the caller's terminal, and an implicit wait), single
// (one process per item rather than one for all).
struct Handler {
  std::vector<std::string> command;
  bool terminal = false, single = false, bundle = false;
  std::string origin;
};
struct Table {
  std::vector<std::pair<std::set<std::string>, Handler>> entries;
  const Handler* find(const std::string& selector) const {
    for (const auto& [selectors, handler] : entries) if (selectors.contains(selector)) return &handler;
    return nullptr;
  }
};
std::string trim(const std::string& value) {
  auto first = value.find_first_not_of(" \t");
  if (first == std::string::npos) return "";
  return value.substr(first, value.find_last_not_of(" \t") - first + 1);
}
std::vector<std::string> split(const std::string& value, char separator) {
  std::vector<std::string> result;
  std::string item;
  std::istringstream stream(value);
  while (std::getline(stream, item, separator)) result.push_back(trim(item));
  return result;
}
// Missing tables are empty. A table someone else could have written is
// ignored with a warning: its commands would run as the caller.
Table readTable(const std::string& path, uid_t owner, std::vector<std::string>& warnings) {
  Table table;
  std::string bytes;
  try {
    struct stat st{};
    if (lstat(path.c_str(), &st) < 0) {
      if (errno != ENOENT && errno != ENOTDIR) warnings.push_back("open: " + path + ": " + std::strerror(errno));
      return table;
    }
    if (!S_ISREG(st.st_mode) || st.st_uid != owner || (st.st_mode & 0022)) {
      warnings.push_back("open: ignoring " + path + ": it must be a regular file owned by uid " +
                         std::to_string(owner) + " and not group/world writable");
      return table;
    }
    bytes = readFile(path, false);
  } catch (const std::exception& error) {
    warnings.push_back("open: " + path + ": " + error.what());
    return table;
  }
  std::istringstream lines(bytes);
  std::string line;
  for (unsigned number = 1; std::getline(lines, line); ++number) {
    auto where = path + ":" + std::to_string(number);
    if (auto hash = line.find('#'); hash != std::string::npos && trim(line.substr(0, hash)).empty()) continue;
    if (trim(line).empty()) continue;
    auto fields = split(line, ';');
    if (fields.size() < 2 || fields[0].empty() || fields[1].empty()) {
      warnings.push_back("open: " + where + ": expected 'selectors ; command [; flags]'");
      continue;
    }
    std::set<std::string> selectors;
    bool valid = true;
    std::string kind;
    // "ext:txt,md" is ext:txt and ext:md: a bare value keeps the last kind.
    for (const auto& selector : split(fields[0], ',')) {
      static const std::set<std::string> kinds = {"ext", "type", "scheme", "app", "bundle", "role"};
      auto colon = selector.find(':');
      std::string value = selector;
      if (colon != std::string::npos && kinds.contains(selector.substr(0, colon))) {
        kind = selector.substr(0, colon);
        value = selector.substr(colon + 1);
      }
      if (kind.empty() || value.empty()) {
        warnings.push_back("open: " + where + ": invalid selector '" + selector + "'");
        valid = false;
        break;
      }
      selectors.insert(kind + ":" + lower(value));
    }
    Handler handler;
    handler.origin = where;
    std::istringstream words(fields[1]);
    for (std::string word; words >> word;) handler.command.push_back(word);
    for (std::size_t i = 2; i < fields.size() && valid; ++i) {
      if (fields[i] == "needsterminal") handler.terminal = true;
      else if (fields[i] == "single") handler.single = true;
      else if (!fields[i].empty()) {
        warnings.push_back("open: " + where + ": unknown flag '" + fields[i] + "'");
        valid = false;
      }
    }
    if (valid) table.entries.emplace_back(std::move(selectors), std::move(handler));
  }
  return table;
}

// ---- bundles --------------------------------------------------------------
// Without CoreServices, a bundle is its Info.plist: identifier, name,
// executable, and the extensions and URL schemes it claims. Documents reach
// the executable through argv, not Apple Events.
struct Bundle {
  std::string path, identifier, name, executable;
  std::set<std::string> extensions, schemes;
};
std::optional<Bundle> readBundle(const std::string& path, std::string* error = nullptr) {
  auto fail = [&](const std::string& message) -> std::optional<Bundle> { if (error) *error = message; return std::nullopt; };
  std::string bytes;
  try { bytes = readFile(path + "/Contents/Info.plist", false); }
  catch (const std::exception& problem) { return fail(path + ": " + problem.what()); }
  if (bytes.starts_with("bplist")) return fail(path + ": binary Info.plist files are not supported");
  auto value = parsePlist(bytes, true);
  if (!value) return fail(path + ": " + value.error());
  try {
    const auto& info = value->as<Value::Dict>();
    Bundle bundle;
    bundle.path = path;
    bundle.identifier = optionalString(info, "CFBundleIdentifier").value_or("");
    auto file = basename(path);
    bundle.name = optionalString(info, "CFBundleName").value_or(file.substr(0, file.size() - 4));
    bundle.executable = optionalString(info, "CFBundleExecutable").value_or(file.substr(0, file.size() - 4));
    if (bundle.executable.empty() || bundle.executable.find('/') != std::string::npos)
      return fail(path + ": invalid CFBundleExecutable");
    if (auto it = info.find("CFBundleDocumentTypes"); it != info.end())
      for (const auto& type : it->second.as<Value::Array>()) {
        const auto& entry = type.as<Value::Dict>();
        if (auto ext = entry.find("CFBundleTypeExtensions"); ext != entry.end())
          for (const auto& item : ext->second.as<Value::Array>())
            if (item.as<std::string>() != "*") bundle.extensions.insert(lower(item.as<std::string>()));
      }
    if (auto it = info.find("CFBundleURLTypes"); it != info.end())
      for (const auto& type : it->second.as<Value::Array>()) {
        const auto& entry = type.as<Value::Dict>();
        if (auto schemes = entry.find("CFBundleURLSchemes"); schemes != entry.end())
          for (const auto& item : schemes->second.as<Value::Array>()) bundle.schemes.insert(lower(item.as<std::string>()));
      }
    return bundle;
  } catch (const std::exception& problem) { return fail(path + ": " + problem.what()); }
}
bool isBundle(const std::string& path) {
  struct stat st{};
  return lower(path).ends_with(".app") && stat((path + "/Contents/Info.plist").c_str(), &st) == 0 && S_ISREG(st.st_mode);
}
Handler bundleHandler(const Bundle& bundle) {
  Handler handler;
  handler.command = {bundle.path + "/Contents/MacOS/" + bundle.executable};
  handler.bundle = true;
  handler.origin = bundle.path;
  return handler;
}

// ---- requests -------------------------------------------------------------
struct Item { bool url; std::string value; };
struct Launch { Handler handler; std::vector<std::string> items; };
struct Failure : Error { using Error::Error; };

class Resolver {
  const Settings& settings_;
  std::vector<Table> tables_;  // user, then system
  std::optional<std::vector<Bundle>> bundles_;
  std::string home_;
  std::vector<Handler> owned_;
public:
  Resolver(const Settings& settings, const std::string& home, uid_t caller, std::vector<std::string>& warnings)
      : settings_(settings), home_(home) {
    if (!home.empty() && home.front() == '/')
      tables_.push_back(readTable(home + "/.config/open/handlers", caller, warnings));
    tables_.push_back(readTable(settings.systemHandlers, settings.trustedOwner, warnings));
    owned_.reserve(64);
  }
  const std::vector<Bundle>& bundles() {
    if (bundles_) return *bundles_;
    bundles_.emplace();
    auto directories = settings_.applications;
    if (!settings_.applicationsSet && !home_.empty() && home_.front() == '/') directories.push_back(home_ + "/Applications");
    for (const auto& directory : directories) {
      std::unique_ptr<DIR, decltype(&closedir)> dir(opendir(directory.c_str()), closedir);
      if (!dir) continue;
      std::vector<std::string> names;
      while (auto* entry = readdir(dir.get())) names.emplace_back(entry->d_name);
      std::sort(names.begin(), names.end());
      for (const auto& name : names)
        if (isBundle(directory + "/" + name))
          if (auto bundle = readBundle(directory + "/" + name)) bundles_->push_back(std::move(*bundle));
    }
    return *bundles_;
  }
  const Handler* keep(Handler handler) { owned_.push_back(std::move(handler)); return &owned_.back(); }
  // Tables first, so an administrator's or user's choice beats a bundle's claim.
  const Handler* lookup(const std::string& selector) {
    for (const auto& table : tables_) if (auto* handler = table.find(selector)) return handler;
    auto colon = selector.find(':');
    auto kind = selector.substr(0, colon), key = selector.substr(colon + 1);
    if (kind != "ext" && kind != "scheme") return nullptr;
    for (const auto& bundle : bundles()) {
      if ((kind == "ext" && bundle.extensions.contains(key)) || (kind == "scheme" && bundle.schemes.contains(key)))
        return keep(bundleHandler(bundle));
    }
    return nullptr;
  }
  const Handler* application(const Value::Dict& request) {
    const auto& selection = dict(required(request, "Application"));
    if (selection.size() != 1) throw Error("Application must have exactly one key");
    if (auto path = optionalString(selection, "Path")) {
      if (path->empty() || path->front() != '/') throw Error("Application Path must be absolute");
      if (isBundle(*path)) {
        std::string error;
        auto bundle = readBundle(*path, &error);
        if (!bundle) throw Failure("Unable to launch " + *path + ": " + error);
        return keep(bundleHandler(*bundle));
      }
      struct stat st{};
      if (stat(path->c_str(), &st) == 0 && S_ISREG(st.st_mode) && !access(path->c_str(), X_OK)) {
        // Like an unbundled executable on macOS, which opens in Terminal.
        Handler handler;
        handler.command = {*path};
        handler.terminal = true;
        handler.origin = *path;
        return keep(std::move(handler));
      }
      throw Failure("Unable to find application named '" + *path + "'");
    }
    if (auto name = optionalString(selection, "Name")) {
      auto key = lower(*name);
      if (key.ends_with(".app")) key.resize(key.size() - 4);
      if (auto* handler = lookup("app:" + key)) return handler;
      for (const auto& bundle : bundles())
        if (lower(basename(bundle.path)) == key + ".app" || lower(bundle.name) == key) return keep(bundleHandler(bundle));
      throw Failure("Unable to find application named '" + *name + "'");
    }
    if (auto identifier = optionalString(selection, "BundleIdentifier")) {
      if (auto* handler = lookup("bundle:" + lower(*identifier))) return handler;
      for (const auto& bundle : bundles())
        if (lower(bundle.identifier) == lower(*identifier)) return keep(bundleHandler(bundle));
      throw Failure("Unable to find application with bundle identifier " + *identifier);
    }
    throw Error("Application needs Path, Name or BundleIdentifier");
  }
  // macOS's order: bundles launch themselves; then the item's own type.
  const Handler* item(const Item& item) {
    if (item.url) {
      auto scheme = lower(item.value.substr(0, item.value.find(':')));
      if (auto* handler = lookup("scheme:" + scheme)) return handler;
      throw Failure("No application knows how to open URL " + item.value + ".");
    }
    struct stat st{};
    if (stat(item.value.c_str(), &st) < 0) throw Failure("The file " + item.value + " does not exist.");
    if (S_ISDIR(st.st_mode)) {
      if (isBundle(item.value)) {
        std::string error;
        auto bundle = readBundle(item.value, &error);
        if (!bundle) throw Failure("Unable to launch " + item.value + ": " + error);
        auto handler = bundleHandler(*bundle);
        handler.origin = "self";
        return keep(std::move(handler));
      }
      if (auto* handler = lookup("type:directory")) return handler;
    } else if (S_ISREG(st.st_mode)) {
      auto name = basename(item.value);
      auto dot = name.find_last_of('.');
      if (dot != std::string::npos && dot && dot + 1 < name.size())
        if (auto* handler = lookup("ext:" + lower(name.substr(dot + 1)))) return handler;
      if ((st.st_mode & 0111) && !access(item.value.c_str(), X_OK))
        if (auto* handler = lookup("type:executable")) return handler;
      if (text(item.value))
        if (auto* handler = lookup("type:text")) return handler;
      if (auto* handler = lookup("type:file")) return handler;
    }
    throw Failure("No application knows how to open " + item.value + ".");
  }
  // Text: the first 4 KiB has no NUL and is valid UTF-8.
  static bool text(const std::string& path) {
    Fd fd(::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK));
    if (fd.get() < 0) return false;
    unsigned char buffer[4096];
    auto count = read(fd.get(), buffer, sizeof buffer);
    if (count < 0) return false;
    for (ssize_t i = 0; i < count;) {
      unsigned char c = buffer[i];
      if (!c) return false;
      int extra = c < 0x80 ? 0 : (c & 0xe0) == 0xc0 ? 1 : (c & 0xf0) == 0xe0 ? 2 : (c & 0xf8) == 0xf0 ? 3 : -1;
      if (extra < 0) return false;
      for (int j = 1; j <= extra; ++j)
        if (i + j < count && (buffer[i + j] & 0xc0) != 0x80) return false;  // a split final character is fine
      i += extra + 1;
    }
    return true;
  }
};

std::string searchPath(const std::string& program, const std::map<std::string, std::string>& environment) {
  if (program.find('/') != std::string::npos) return program;
  auto it = environment.find("PATH");
  std::string path = it != environment.end() ? it->second : "/usr/bin:/bin:/usr/sbin:/sbin";
  for (const auto& directory : split(path, ':')) {
    if (directory.empty()) continue;
    auto candidate = directory + "/" + program;
    if (!access(candidate.c_str(), X_OK)) return candidate;
  }
  throw Failure("Unable to launch " + program + ": No such file or directory");
}

struct Process { pid_t pid; std::string program; bool terminal; };

// The handler outlives this worker and opend itself, as an application
// outlives LaunchServices. It runs in a new session whose leader is a small
// holder process (the reported PID and process group) that waits for it and
// exits the same way. A process that is not a session leader can never
// acquire a controlling terminal: a handler given the caller's terminal must
// not take it over, or its exit would revoke it from the caller's shell.
// Exec failure arrives on a CLOEXEC pipe.
Process spawn(const Launch& launch, const std::vector<std::string>& arguments,
              const std::map<std::string, std::string>& environment, const std::string& directory,
              const std::map<std::string, Fd>& streams) {
  std::vector<std::string> argv;
  bool placed = false;
  for (const auto& word : launch.handler.command) {
    if (word == "%s") { argv.insert(argv.end(), launch.items.begin(), launch.items.end()); placed = true; }
    else argv.push_back(word);
  }
  argv.insert(argv.end(), arguments.begin(), arguments.end());
  if (!placed) argv.insert(argv.end(), launch.items.begin(), launch.items.end());
  if (argv.empty()) throw Failure("Unable to launch " + launch.handler.origin + ": empty command");
  auto program = searchPath(argv.front(), environment);

  auto stream = [&](const char* explicitName, const char* callerName) -> int {
    if (auto it = streams.find(explicitName); it != streams.end()) return it->second.get();
    if (launch.handler.terminal)
      if (auto it = streams.find(callerName); it != streams.end()) return it->second.get();
    return -1;
  };
  Fd null(::open("/dev/null", O_RDWR | O_CLOEXEC));
  if (null.get() < 0) systemError("open /dev/null");
  int in = stream("stdin", "caller-stdin"), out = stream("stdout", "caller-stdout"), err = stream("stderr", "caller-stderr");
  if (in < 0) in = null.get();
  if (out < 0) out = null.get();
  if (err < 0) err = null.get();

  std::vector<char*> args;
  for (auto& word : argv) args.push_back(word.data());
  args.push_back(nullptr);
  std::vector<std::string> entries;
  for (const auto& [name, value] : environment) entries.push_back(name + "=" + value);
  std::vector<char*> env;
  for (auto& entry : entries) env.push_back(entry.data());
  env.push_back(nullptr);
  int pipeFds[2];
  if (pipe(pipeFds) < 0) systemError("pipe");
  Fd reader(pipeFds[0]), writer(pipeFds[1]);
  closeOnExec(reader.get()); closeOnExec(writer.get());
  const int limit = getdtablesize();
  sigset_t empty; sigemptyset(&empty);

  pid_t pid = fork();
  if (pid < 0) systemError("fork");
  if (!pid) {
    auto failChild = [&](int error) {
      (void)!write(writer.get(), &error, sizeof error);
      _exit(127);
    };
    // The holder: signals the caller forwards to the group are the handler's.
    struct sigaction action{}; action.sa_handler = SIG_DFL; sigemptyset(&action.sa_mask);
    for (int signal = 1; signal < NSIG; ++signal)
      if (signal != SIGKILL && signal != SIGSTOP) (void)sigaction(signal, &action, nullptr);
    struct sigaction ignore{}; ignore.sa_handler = SIG_IGN; sigemptyset(&ignore.sa_mask);
    const int forwarded[] = {SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGTSTP, SIGTTIN, SIGTTOU};
    for (int signal : forwarded) (void)sigaction(signal, &ignore, nullptr);
    if (setsid() < 0 || sigprocmask(SIG_SETMASK, &empty, nullptr) < 0) failChild(errno);
    pid_t handler = fork();
    if (handler < 0) failChild(errno);
    if (!handler) {
      for (int signal : forwarded) (void)sigaction(signal, &action, nullptr);
      // Lift the three streams clear of 0..2 first; one may already sit there.
      int moved[3] = {fcntl(in, F_DUPFD_CLOEXEC, 3), fcntl(out, F_DUPFD_CLOEXEC, 3), fcntl(err, F_DUPFD_CLOEXEC, 3)};
      for (int i = 0; i < 3; ++i) if (moved[i] < 0 || dup2(moved[i], i) < 0) failChild(errno);
      if (chdir(directory.c_str()) < 0 && chdir("/") < 0) failChild(errno);
      umask(022);
      for (int fd = 3; fd < limit; ++fd) if (fd != writer.get()) (void)close(fd);
      execve(program.c_str(), args.data(), env.data());
      failChild(errno);
    }
    // Hold nothing open: not the terminal, not the exec-status pipe.
    for (int fd = 0; fd < limit; ++fd) (void)close(fd);
    int status;
    while (waitpid(handler, &status, 0) < 0)
      if (errno != EINTR) _exit(127);
    if (WIFEXITED(status)) _exit(WEXITSTATUS(status));
    int signal = WTERMSIG(status);
    (void)sigaction(signal, &action, nullptr);
    sigset_t only; sigemptyset(&only); sigaddset(&only, signal);
    (void)sigprocmask(SIG_UNBLOCK, &only, nullptr);
    (void)kill(getpid(), signal);
    _exit(128 + signal);
  }
  writer.reset();
  int error = 0;
  std::size_t received = 0;
  while (received < sizeof error) {
    auto count = read(reader.get(), reinterpret_cast<char*>(&error) + received, sizeof error - received);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) break;
    received += static_cast<std::size_t>(count);
  }
  if (received) {
    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    throw Failure("Unable to launch " + program + ": " + std::strerror(error));
  }
  return {pid, program, launch.handler.terminal};
}

Value response(bool ok, const std::string& message, const std::vector<std::string>& warnings,
               const std::vector<Process>& launched, bool waiting, bool terminal) {
  Value::Array warningValues, launchedValues;
  for (const auto& warning : warnings) warningValues.push_back(Value(warning));
  for (const auto& process : launched)
    launchedValues.push_back(Value(Value::Dict{{"PID", Value(std::int64_t(process.pid))}, {"Program", Value(process.program)}}));
  return Value(Value::Dict{{"Version", Value(protocolVersion)}, {"OK", Value(ok)}, {"Message", Value(message)},
    {"Warnings", Value(std::move(warningValues))}, {"Launched", Value(std::move(launchedValues))},
    {"Waiting", Value(waiting)}, {"Terminal", Value(terminal)}});
}

// Runs in the worker, already as the caller.
void serve(int connection, const Settings& settings, std::vector<Fd> descriptors, const Value& requestValue) {
  std::vector<std::string> warnings;
  std::vector<Process> launched;
  bool wait = false, terminal = false;
  auto deadline = Clock::now() + ioTimeout;
  try {
    const auto& request = dict(requestValue);
    if (required(request, "Version").as<std::int64_t>() != protocolVersion) throw Error("unsupported protocol version");

    std::map<std::string, Fd> streams;
    static const std::set<std::string> streamNames = {"stdin", "stdout", "stderr", "caller-stdin", "caller-stdout", "caller-stderr"};
    std::vector<std::string> names;
    if (auto it = request.find("Descriptors"); it != request.end())
      for (const auto& name : it->second.as<Value::Array>()) names.push_back(name.as<std::string>());
    if (names.size() != descriptors.size()) throw Error("Descriptors does not match the descriptors sent");
    for (std::size_t i = 0; i < names.size(); ++i) {
      if (!streamNames.contains(names[i]) || streams.contains(names[i])) throw Error("invalid descriptor name " + names[i]);
      streams.emplace(names[i], std::move(descriptors[i]));
    }

    std::map<std::string, std::string> environment;
    if (auto it = request.find("Environment"); it != request.end())
      for (const auto& [name, value] : it->second.as<Value::Dict>()) environment[name] = value.as<std::string>();
    if (auto it = request.find("EnvironmentOverrides"); it != request.end())
      for (const auto& [name, value] : it->second.as<Value::Dict>()) environment[name] = value.as<std::string>();
    for (const auto& [name, value] : environment)
      if (name.empty() || name.find('=') != std::string::npos || name.find('\0') != std::string::npos ||
          value.find('\0') != std::string::npos) throw Error("invalid environment entry");
    std::vector<std::string> arguments;
    if (auto it = request.find("Arguments"); it != request.end())
      for (const auto& argument : it->second.as<Value::Array>()) arguments.push_back(argument.as<std::string>());
    std::string directory = optionalString(request, "WorkingDirectory").value_or("/");
    if (directory.empty() || directory.front() != '/') directory = "/";

    Value::Dict noOptions;
    const auto& options = request.contains("Options") ? dict(request.at("Options")) : noOptions;
    wait = flag(options, "Wait");
    // Nothing here tracks instances, so every launch is already a new one.
    for (const auto& [key, text] : std::vector<std::pair<std::string, std::string>>{
           {"Background", "-g"}, {"Hide", "-j"}, {"Fresh", "-F"}})
      if (flag(options, key)) warnings.push_back("open: " + text + " has no effect: MiniDarwin has no window server");
    if (optionalString(options, "Architecture")) warnings.push_back("open: --arch is ignored");

    std::vector<Item> items;
    if (auto it = request.find("Items"); it != request.end())
      for (const auto& value : it->second.as<Value::Array>()) {
        const auto& entry = dict(value);
        auto type = stringField(entry, "Type");
        auto text = stringField(entry, "Value");
        if (type == "file") {
          if (text.empty() || text.front() != '/') throw Error("file items must be absolute paths");
          items.push_back({false, text});
        } else if (type == "url") {
          auto colon = text.find(':');
          if (colon == std::string::npos || !colon) throw Error("invalid URL " + text);
          items.push_back({true, text});
        } else throw Error("unknown item type " + type);
      }
    if (flag(options, "Reveal")) {
      warnings.push_back("open: -R cannot select items; opening the enclosing folder instead");
      std::vector<Item> folders;
      for (const auto& item : items) {
        if (item.url) throw Failure("open: -R cannot reveal URL " + item.value);
        auto folder = dirname(item.value);
        if (std::none_of(folders.begin(), folders.end(), [&](const Item& seen) { return seen.value == folder; }))
          folders.push_back({false, folder});
      }
      items = std::move(folders);
    }

    Resolver resolver(settings, environment.contains("HOME") ? environment["HOME"] : "", getuid(), warnings);
    std::vector<Launch> launches;
    auto add = [&](const Handler* handler, std::optional<std::string> value) {
      if (!handler->single)
        for (auto& launch : launches)
          if (launch.handler.origin == handler->origin && launch.handler.command == handler->command) {
            if (value) launch.items.push_back(*value);
            return;
          }
      Launch launch{*handler, {}};
      if (value) launch.items.push_back(*value);
      launches.push_back(std::move(launch));
    };
    if (request.contains("Application") || optionalString(request, "Role")) {
      const Handler* handler = nullptr;
      if (request.contains("Application")) handler = resolver.application(request);
      else if (*optionalString(request, "Role") == "TextEditor") {
        handler = resolver.lookup("role:editor");
        if (!handler) throw Failure("No default text editor is configured.");
      } else throw Error("unknown Role");
      if (items.empty()) add(handler, std::nullopt);
      for (const auto& item : items) add(handler, item.value);
    } else {
      if (items.empty()) throw Error("nothing to open");
      // Resolve everything before launching anything: one unknown item fails
      // the request, as on macOS.
      std::vector<std::pair<const Handler*, std::string>> resolved;
      for (const auto& item : items) {
        auto* handler = resolver.item(item);
        // An .app opened as an item launches itself, with no documents.
        resolved.emplace_back(handler, handler->origin == "self" ? "" : item.value);
      }
      for (const auto& [handler, value] : resolved)
        add(handler, value.empty() ? std::nullopt : std::optional<std::string>(value));
    }
    for (const auto& launch : launches) {
      launched.push_back(spawn(launch, arguments, environment, directory, streams));
      terminal = terminal || launch.handler.terminal;
    }
  } catch (const Failure& failure) {
    sendFrame(connection, response(false, failure.what(), warnings, launched, false, false), {}, deadline);
    return;
  } catch (const std::exception& error) {
    sendFrame(connection, response(false, std::string("open: invalid request: ") + error.what(), warnings, launched, false, false), {}, deadline);
    return;
  }

  bool waiting = wait || terminal;
  sendFrame(connection, response(true, "", warnings, launched, waiting, terminal), {}, deadline);
  if (!waiting) return;

  // Wait for every launched process, or for the caller to give up. A caller
  // that leaves takes its terminal with it: hang up the terminal handlers.
  std::map<pid_t, Value::Dict> results;
  while (results.size() < launched.size()) {
    for (const auto& process : launched) {
      if (results.contains(process.pid)) continue;
      int status;
      pid_t result = waitpid(process.pid, &status, WNOHANG);
      if (result == process.pid) {
        Value::Dict entry{{"PID", Value(std::int64_t(process.pid))}};
        if (WIFEXITED(status)) entry.emplace("ExitStatus", Value(std::int64_t(WEXITSTATUS(status))));
        if (WIFSIGNALED(status)) entry.emplace("ExitSignal", Value(std::int64_t(WTERMSIG(status))));
        results.emplace(process.pid, std::move(entry));
      } else if (result < 0 && errno != EINTR) results.emplace(process.pid, Value::Dict{{"PID", Value(std::int64_t(process.pid))}});
    }
    if (results.size() == launched.size()) break;
    pollfd item{connection, POLLIN, 0};
    if (poll(&item, 1, 100) > 0) {
      for (const auto& process : launched)
        if (process.terminal && !results.contains(process.pid)) (void)kill(-process.pid, SIGHUP);
      return;
    }
  }
  Value::Array values;
  for (auto& [pid, entry] : results) values.push_back(Value(std::move(entry)));
  sendFrame(connection, Value(Value::Dict{{"Version", Value(protocolVersion)}, {"Event", Value(std::string("exited"))},
                                          {"Results", Value(std::move(values))}}), {}, ioTimeout + Clock::now());
}

// The worker: become the caller, then serve one request. Never returns.
[[noreturn]] void worker(Fd connection, const Settings& settings) {
  int code = 0;
  try {
    nonblocking(connection.get());
    xucred credentials{};
    socklen_t size = sizeof credentials;
    if (getsockopt(connection.get(), SOL_LOCAL, LOCAL_PEERCRED, &credentials, &size) < 0) systemError("LOCAL_PEERCRED");
    if (credentials.cr_version != XUCRED_VERSION || credentials.cr_ngroups < 1) throw Error("unexpected peer credentials");
    if (geteuid() == 0) {
      // cr_groups[0] is the caller's effective group.
      if (setgroups(credentials.cr_ngroups, credentials.cr_groups) < 0 || setgid(credentials.cr_groups[0]) < 0 ||
          setuid(credentials.cr_uid) < 0) systemError("assume caller credentials");
    } else if (credentials.cr_uid != geteuid()) {
      sendFrame(connection.get(), response(false, "open: the open service cannot act for this user", {}, {}, false, false),
                {}, Clock::now() + ioTimeout);
      _exit(1);
    }
    std::vector<Fd> descriptors;
    auto request = receiveFrame(connection.get(), Clock::now() + ioTimeout, &descriptors);
    if (request) serve(connection.get(), settings, std::move(descriptors), *request);
  } catch (const std::exception& error) {
    log(error.what());
    code = 1;
  }
  std::cerr.flush();
  _exit(code);
}

constexpr std::size_t maxWorkers = 64;

int listenerFromLaunchd() {
  const char* sockets = std::getenv(socketsVariable);
  if (!sockets) throw Error(std::string("not started by launchd (no ") + socketsVariable + "); use --socket for development");
  std::istringstream entries(sockets);
  for (std::string entry; entries >> entry;) {
    if (!entry.starts_with("Listener=")) continue;
    int fd = std::stoi(entry.substr(9));
    struct stat st{};
    if (fstat(fd, &st) < 0 || !S_ISSOCK(st.st_mode)) throw Error("launchd's Listener descriptor is not a socket");
    closeOnExec(fd);
    return fd;
  }
  throw Error("launchd passed no socket named Listener");
}

Fd bindDevelopmentSocket(const std::string& path) {
  if (path.empty() || path.front() != '/' || path.size() >= sizeof(sockaddr_un::sun_path)) throw Error("invalid socket path");
  struct stat st{};
  if (lstat(path.c_str(), &st) == 0) {
    if (!S_ISSOCK(st.st_mode)) throw Error("refusing to replace " + path);
    (void)unlink(path.c_str());
  }
  auto socket = checkedFd(::socket(AF_UNIX, SOCK_STREAM, 0), "socket");
  closeOnExec(socket.get());
  sockaddr_un address{}; address.sun_family = AF_UNIX;
  std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  if (bind(socket.get(), reinterpret_cast<sockaddr*>(&address), sizeof address) < 0) systemError("bind " + path);
  if (chmod(path.c_str(), 0600) < 0 || listen(socket.get(), 64) < 0) systemError("listen " + path);
  return socket;
}

Settings parseSettings(int argc, char** argv) {
  Settings settings;
  bool defaultApplications = true;
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    auto value = [&]() -> std::string { if (i + 1 >= argc) throw Error("missing value for " + arg); return argv[++i]; };
    if (arg == "--socket") settings.socket = value();
    else if (arg == "--system-handlers") settings.systemHandlers = value();
    else if (arg == "--applications") {
      if (defaultApplications) settings.applications.clear();
      defaultApplications = false;
      settings.applicationsSet = true;
      settings.applications.push_back(value());
    } else if (arg == "--idle-timeout") settings.idleSeconds = static_cast<unsigned>(std::stoul(value()));
    else throw Error("usage: opend [--socket PATH] [--system-handlers PATH] [--applications DIR ...] [--idle-timeout SECONDS]");
  }
  settings.trustedOwner = geteuid();
  return settings;
}
} // namespace

int main(int argc, char** argv) {
  try {
    auto settings = parseSettings(argc, argv);
    Fd listener = settings.socket ? bindDevelopmentSocket(*settings.socket) : Fd(listenerFromLaunchd());
    nonblocking(listener.get());
    struct sigaction ignore{}; ignore.sa_handler = SIG_IGN; sigemptyset(&ignore.sa_mask);
    sigaction(SIGPIPE, &ignore, nullptr);
    sigset_t blocked; sigemptyset(&blocked); sigaddset(&blocked, SIGCHLD);
    sigprocmask(SIG_BLOCK, &blocked, nullptr);
    Fd queue = checkedFd(kqueue(), "kqueue");
    closeOnExec(queue.get());
    struct kevent changes[2];
    EV_SET(&changes[0], static_cast<uintptr_t>(listener.get()), EVFILT_READ, EV_ADD, 0, 0, nullptr);
    EV_SET(&changes[1], SIGCHLD, EVFILT_SIGNAL, EV_ADD, 0, 0, nullptr);
    if (kevent(queue.get(), changes, 2, nullptr, 0, nullptr) < 0) systemError("kevent");

    std::set<pid_t> workers;
    bool paused = false;
    auto idleSince = Clock::now();
    for (;;) {
      // Exit when idle: launchd keeps the socket and relaunches on demand.
      // Workers must finish first; they and their waits are in our group.
      if (settings.idleSeconds && workers.empty() && Clock::now() - idleSince >= std::chrono::seconds(settings.idleSeconds))
        return 0;
      struct kevent event{};
      timespec timeout{1, 0};
      int count = kevent(queue.get(), nullptr, 0, &event, 1, &timeout);
      if (count < 0) { if (errno == EINTR) continue; systemError("kevent wait"); }
      for (;;) {
        int status;
        pid_t pid = waitpid(-1, &status, WNOHANG);
        if (pid <= 0) break;
        workers.erase(pid);
      }
      if (workers.empty() && count > 0 && event.filter == EVFILT_SIGNAL) idleSince = Clock::now();
      // Beyond the cap, connections wait in the backlog for a worker to finish.
      for (unsigned accepted = 0; accepted < 32 && workers.size() < maxWorkers; ++accepted) {
        int raw = accept(listener.get(), nullptr, nullptr);
        if (raw < 0) {
          if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR && errno != ECONNABORTED) log(std::string("accept: ") + std::strerror(errno));
          break;
        }
        Fd connection(raw);
        closeOnExec(raw);
        pid_t pid = fork();
        if (pid < 0) { log(std::string("fork: ") + std::strerror(errno)); continue; }
        if (!pid) {
          listener.reset(); queue.reset();
          sigset_t empty; sigemptyset(&empty);
          sigprocmask(SIG_SETMASK, &empty, nullptr);
          worker(std::move(connection), settings);
        }
        workers.insert(pid);
        idleSince = Clock::now();
      }
      // Stop watching the listener while full, so a waiting backlog does not
      // spin this loop; SIGCHLD wakes it when a worker finishes.
      bool full = workers.size() >= maxWorkers;
      if (full != paused) {
        struct kevent change{};
        EV_SET(&change, static_cast<uintptr_t>(listener.get()), EVFILT_READ, full ? EV_DISABLE : EV_ENABLE, 0, 0, nullptr);
        if (kevent(queue.get(), &change, 1, nullptr, 0, nullptr) < 0) systemError("kevent");
        paused = full;
      }
    }
  } catch (const std::exception& error) {
    log(error.what());
    return 1;
  }
}
