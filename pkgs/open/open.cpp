// /usr/bin/open: parses Apple's command line, canonicalizes it, and hands one
// request to whichever daemon serves the open socket (docs/open-protocol.md).
// No policy lives here: which program handles an item is the daemon's call.
#include "channel.hpp"

#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <memory>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>

extern char** environ;

namespace {
using namespace md;
using namespace md::open;

[[noreturn]] void usage() {
  std::cerr <<
    "Usage: open [-e] [-t] [-f] [-W] [-R] [-n] [-g] [-j] [-b <bundle identifier>] [-a <application>] [-u URL] [filenames] [--args arguments]\n"
    "Help: Open opens files from a shell.\n"
    "      By default, opens each file using the default application for that file.\n"
    "      If the file is in the form of a URL, the file will be opened as a URL.\n"
    "Options:\n"
    "      -a                Opens with the specified application.\n"
    "      --arch ARCH       Open with the given cpu architecture type and subtype.\n"
    "      -b                Opens with the specified application bundle identifier.\n"
    "      -e                Opens with TextEdit.\n"
    "      -t                Opens with default text editor.\n"
    "      -f                Reads input from standard input and opens with TextEdit.\n"
    "      -F  --fresh       Launches the app fresh, that is, without restoring windows.\n"
    "      -R, --reveal      Selects in the Finder instead of opening.\n"
    "      -W, --wait-apps   Blocks until the used applications are closed (even if they were already running).\n"
    "          --args        All remaining arguments are passed in argv to the application's main() function instead of opened.\n"
    "      -n, --new         Open a new instance of the application even if one is already running.\n"
    "      -j, --hide        Launches the app hidden.\n"
    "      -g, --background  Does not bring the application to the foreground.\n"
    "      -u, --url URL     Open this URL, even if it matches exactly a filepath\n"
    "      -i, --stdin  PATH Launches the application with stdin connected to PATH; defaults to /dev/null\n"
    "      -o, --stdout PATH Launches the application with /dev/stdout connected to PATH;\n"
    "          --stderr PATH Launches the application with /dev/stderr connected to PATH to\n"
    "          --env VAR     Add an enviroment variable to the launched process, where VAR is formatted AAA=foo or just AAA for a null string value.\n";
  std::exit(1);
}

struct Options {
  std::optional<std::string> application, bundle, stdinPath, stdoutPath, stderrPath, arch;
  bool textEdit = false, textEditor = false, readStdin = false, wait = false, reveal = false,
       newInstance = false, hide = false, background = false, fresh = false, headers = false;
  std::vector<std::string> urls, files, arguments;
  std::vector<std::pair<std::string, std::string>> environment;
};

Options parse(int argc, char** argv) {
  Options options;
  bool optionsDone = false;
  auto value = [&](int& i, std::string_view rest) -> std::string {
    if (!rest.empty()) return std::string(rest);
    if (i + 1 >= argc) usage();
    return argv[++i];
  };
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--args") {
      for (++i; i < argc; ++i) options.arguments.emplace_back(argv[i]);
      break;
    }
    // Like BSD getopt, the first operand ends option parsing; --args does not.
    if (optionsDone || arg.size() < 2 || arg[0] != '-') { optionsDone = true; options.files.push_back(arg); continue; }
    if (arg == "--") { optionsDone = true; continue; }
    if (arg.starts_with("--")) {
      if (arg == "--wait-apps") options.wait = true;
      else if (arg == "--reveal") options.reveal = true;
      else if (arg == "--new") options.newInstance = true;
      else if (arg == "--hide") options.hide = true;
      else if (arg == "--background") options.background = true;
      else if (arg == "--fresh") options.fresh = true;
      else if (arg == "--header") options.headers = true;
      else if (arg == "--url") options.urls.push_back(value(i, {}));
      else if (arg == "--stdin") options.stdinPath = value(i, {});
      else if (arg == "--stdout") options.stdoutPath = value(i, {});
      else if (arg == "--stderr") options.stderrPath = value(i, {});
      else if (arg == "--arch") options.arch = value(i, {});
      else if (arg == "--env") {
        auto entry = value(i, {});
        auto equals = entry.find('=');
        auto name = entry.substr(0, equals);
        if (name.empty()) usage();
        options.environment.emplace_back(name, equals == std::string::npos ? "" : entry.substr(equals + 1));
      } else usage();
      continue;
    }
    for (std::size_t j = 1; j < arg.size(); ++j) {
      std::string_view rest = std::string_view(arg).substr(j + 1);
      switch (arg[j]) {
        case 'a': options.application = value(i, rest); j = arg.size(); break;
        case 'b': options.bundle = value(i, rest); j = arg.size(); break;
        case 'u': options.urls.push_back(value(i, rest)); j = arg.size(); break;
        case 'i': options.stdinPath = value(i, rest); j = arg.size(); break;
        case 'o': options.stdoutPath = value(i, rest); j = arg.size(); break;
        case 's': (void)value(i, rest); j = arg.size(); options.headers = true; break;
        case 'e': options.textEdit = true; break;
        case 't': options.textEditor = true; break;
        case 'f': options.readStdin = true; break;
        case 'F': options.fresh = true; break;
        case 'R': options.reveal = true; break;
        case 'W': options.wait = true; break;
        case 'n': options.newInstance = true; break;
        case 'j': options.hide = true; break;
        case 'g': options.background = true; break;
        case 'h': options.headers = true; break;
        default: usage();
      }
    }
  }
  return options;
}

std::string absolute(const std::string& path) {
  if (!path.empty() && path.front() == '/') return path;
  std::unique_ptr<char, decltype(&std::free)> cwd(getcwd(nullptr, 0), std::free);
  if (!cwd) systemError("getcwd");
  std::string base = cwd.get();
  return (base == "/" ? "" : base) + "/" + path;
}
std::optional<std::string> resolved(const std::string& path) {
  std::unique_ptr<char, decltype(&std::free)> raw(realpath(path.c_str(), nullptr), std::free);
  if (!raw) return std::nullopt;
  return std::string(raw.get());
}
// RFC 3986 scheme followed by ':'.
bool hasScheme(const std::string& value) {
  auto colon = value.find(':');
  if (colon == std::string::npos || !colon) return false;
  if (!std::isalpha(static_cast<unsigned char>(value[0]))) return false;
  for (std::size_t i = 1; i < colon; ++i) {
    char c = value[i];
    if (!std::isalnum(static_cast<unsigned char>(c)) && c != '+' && c != '-' && c != '.') return false;
  }
  return true;
}
std::string percentDecode(const std::string& value) {
  std::string result;
  for (std::size_t i = 0; i < value.size(); ++i) {
    if (value[i] == '%' && i + 2 < value.size() && std::isxdigit(static_cast<unsigned char>(value[i + 1])) &&
        std::isxdigit(static_cast<unsigned char>(value[i + 2]))) {
      result += static_cast<char>(std::stoi(value.substr(i + 1, 2), nullptr, 16));
      i += 2;
    } else result += value[i];
  }
  return result;
}
[[noreturn]] void fail(const std::string& message) {
  std::cerr << message << '\n';
  std::exit(1);
}
Value fileItem(const std::string& path) {
  auto real = resolved(path);
  if (!real) fail("The file " + absolute(path) + " does not exist.");
  return Value(Value::Dict{{"Type", Value(std::string("file"))}, {"Value", Value(*real)}});
}
Value item(const std::string& argument, bool forceURL) {
  // An existing path wins over URL syntax unless -u says otherwise.
  struct stat st{};
  if (!forceURL && stat(argument.c_str(), &st) == 0) return fileItem(argument);
  if (forceURL || hasScheme(argument)) {
    // file: URLs name local files; the daemon only ever sees their paths.
    std::string lower = argument.substr(0, 5);
    for (auto& c : lower) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    if (lower == "file:") {
      auto rest = argument.substr(5);
      if (rest.starts_with("//")) {
        rest.erase(0, 2);
        auto slash = rest.find('/');
        auto host = rest.substr(0, slash == std::string::npos ? rest.size() : slash);
        if (!host.empty() && host != "localhost") fail("open: " + argument + ": remote file URLs are not supported");
        rest = slash == std::string::npos ? "/" : rest.substr(slash);
      }
      return fileItem(percentDecode(rest));
    }
    if (!hasScheme(argument)) fail("open: " + argument + " is not a URL");
    return Value(Value::Dict{{"Type", Value(std::string("url"))}, {"Value", Value(argument)}});
  }
  fail("The file " + absolute(argument) + " does not exist.");
}

// -f: like Apple's, stdin is copied to a temporary .txt that is then opened.
std::string stdinToTemporary() {
  const char* directory = std::getenv("TMPDIR");
  std::string pattern = std::string(directory && *directory ? directory : "/tmp");
  if (pattern.back() != '/') pattern += '/';
  pattern += "open_XXXXXXXX.txt";
  std::vector<char> buffer(pattern.begin(), pattern.end());
  buffer.push_back('\0');
  Fd fd(mkstemps(buffer.data(), 4));
  if (fd.get() < 0) systemError("create temporary file");
  char bytes[65536];
  for (;;) {
    auto count = read(0, bytes, sizeof bytes);
    if (count < 0) { if (errno == EINTR) continue; systemError("read stdin"); }
    if (!count) break;
    for (ssize_t offset = 0; offset < count;) {
      auto written = write(fd.get(), bytes + offset, static_cast<std::size_t>(count - offset));
      if (written < 0) { if (errno == EINTR) continue; systemError("write temporary file"); }
      offset += written;
    }
  }
  return buffer.data();
}

Fd openStream(const std::string& path, bool input) {
  int fd = ::open(path.c_str(), input ? O_RDONLY : O_WRONLY | O_CREAT | O_TRUNC, 0666);
  if (fd < 0) fail("open: " + path + ": " + std::strerror(errno));
  return Fd(fd);
}

volatile sig_atomic_t pendingSignal = 0;
extern "C" void remember(int signal) { pendingSignal = signal; }
} // namespace

int main(int argc, char** argv) {
  try {
    auto options = parse(argc, argv);
    if (options.headers) fail("open: -h and -s (header search) are not supported");
    int selections = (options.application ? 1 : 0) + (options.bundle ? 1 : 0) + (options.textEdit ? 1 : 0) + (options.textEditor ? 1 : 0);
    if (selections > 1) usage();
    if (options.readStdin && (!options.files.empty() || !options.urls.empty())) usage();
    if (!selections && !options.readStdin && options.files.empty() && options.urls.empty()) usage();

    Value::Array items;
    for (const auto& url : options.urls) items.push_back(item(url, true));
    for (const auto& file : options.files) items.push_back(item(file, false));
    if (options.readStdin) items.push_back(fileItem(stdinToTemporary()));

    Value::Dict request{{"Version", Value(protocolVersion)}, {"Items", Value(std::move(items))}};
    if (options.application) {
      // A name is a registered application; anything with a slash is a path.
      bool path = options.application->find('/') != std::string::npos;
      if (path) {
        auto real = resolved(*options.application);
        if (!real) fail("Unable to find application named '" + *options.application + "'");
        options.application = real;
      }
      request.emplace("Application", Value(Value::Dict{{path ? "Path" : "Name", Value(*options.application)}}));
    } else if (options.bundle) {
      request.emplace("Application", Value(Value::Dict{{"BundleIdentifier", Value(*options.bundle)}}));
    } else if (options.textEdit) {
      request.emplace("Application", Value(Value::Dict{{"Name", Value(std::string("TextEdit"))}}));
    } else if (options.textEditor || options.readStdin) {
      request.emplace("Role", Value(std::string("TextEditor")));
    }

    Value::Array arguments;
    for (const auto& argument : options.arguments) arguments.push_back(Value(argument));
    request.emplace("Arguments", Value(std::move(arguments)));
    Value::Dict environment, overrides;
    for (char** entry = environ; entry && *entry; ++entry) {
      std::string text = *entry;
      auto equals = text.find('=');
      if (equals == std::string::npos || !equals) continue;
      environment.try_emplace(text.substr(0, equals), Value(text.substr(equals + 1)));
    }
    for (const auto& [name, item] : options.environment) overrides.insert_or_assign(name, Value(item));
    request.emplace("Environment", Value(std::move(environment)));
    request.emplace("EnvironmentOverrides", Value(std::move(overrides)));
    {
      std::unique_ptr<char, decltype(&std::free)> cwd(getcwd(nullptr, 0), std::free);
      if (cwd) request.emplace("WorkingDirectory", Value(std::string(cwd.get())));
    }
    Value::Dict flags{{"Wait", Value(options.wait)}, {"NewInstance", Value(options.newInstance)},
      {"Background", Value(options.background)}, {"Hide", Value(options.hide)},
      {"Fresh", Value(options.fresh)}, {"Reveal", Value(options.reveal)}};
    if (options.arch) flags.emplace("Architecture", Value(*options.arch));
    request.emplace("Options", Value(std::move(flags)));

    // Paths are opened here, with the caller's own permissions, so the daemon
    // never opens a file on the caller's behalf.
    std::vector<Fd> owned;
    std::vector<int> descriptors;
    Value::Array names;
    auto attach = [&](Fd fd, const char* name) {
      descriptors.push_back(fd.get()); owned.push_back(std::move(fd)); names.push_back(Value(std::string(name)));
    };
    if (options.stdinPath) attach(openStream(*options.stdinPath, true), "stdin");
    if (options.stdoutPath) attach(openStream(*options.stdoutPath, false), "stdout");
    if (options.stderrPath) attach(openStream(*options.stderrPath, false), "stderr");
    // The caller's streams, for handlers that run on its terminal. -f
    // consumed stdin, so the editor reads the terminal itself.
    if (options.readStdin) {
      int tty = ::open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC);
      if (tty >= 0) attach(Fd(tty), "caller-stdin");
    } else if (fcntl(0, F_GETFD) >= 0) attach(Fd(dup(0)), "caller-stdin");
    if (fcntl(1, F_GETFD) >= 0) attach(Fd(dup(1)), "caller-stdout");
    if (fcntl(2, F_GETFD) >= 0) attach(Fd(dup(2)), "caller-stderr");
    request.emplace("Descriptors", Value(std::move(names)));

    struct sigaction ignore{}; ignore.sa_handler = SIG_IGN; sigemptyset(&ignore.sa_mask);
    sigaction(SIGPIPE, &ignore, nullptr);
    const char* override = std::getenv(socketVariable);
    std::string path = override && *override ? override : md::open::defaultSocket;
    auto deadline = Clock::now() + replyTimeout;
    Fd socket;
    try { socket = connectTo(path, deadline); }
    catch (const std::exception& error) { fail(std::string("open: the open service is unavailable (") + error.what() + ")"); }
    sendFrame(socket.get(), Value(std::move(request)), descriptors, deadline);
    owned.clear();

    auto replyValue = receiveFrame(socket.get(), deadline);
    if (!replyValue) fail("open: the open service closed the connection");
    const auto& reply = dict(*replyValue);
    if (required(reply, "Version").as<std::int64_t>() != protocolVersion) fail("open: unsupported reply version");
    if (auto it = reply.find("Warnings"); it != reply.end())
      for (const auto& warning : it->second.as<Value::Array>()) std::cerr << warning.as<std::string>() << '\n';
    if (!required(reply, "OK").as<bool>()) fail(optionalString(reply, "Message").value_or("open: request failed"));
    if (!flag(reply, "Waiting")) return 0;

    // A terminal handler shares this terminal but not its foreground process
    // group: forward the keyboard's signals to it rather than dying.
    std::vector<pid_t> groups;
    if (flag(reply, "Terminal")) {
      if (auto it = reply.find("Launched"); it != reply.end())
        for (const auto& launched : it->second.as<Value::Array>()) {
          auto pid = required(dict(launched), "PID").as<std::int64_t>();
          if (pid > 0) groups.push_back(static_cast<pid_t>(pid));
        }
      struct sigaction action{}; action.sa_handler = remember; sigemptyset(&action.sa_mask);
      for (int signal : {SIGINT, SIGQUIT, SIGTERM, SIGHUP}) sigaction(signal, &action, nullptr);
    }
    for (;;) {
      if (pendingSignal) {
        int signal = pendingSignal;
        pendingSignal = 0;
        for (pid_t group : groups) (void)kill(-group, signal);
      }
      // Short polls so a forwarded signal is never delayed for long.
      if (!ready(socket.get(), POLLIN, Clock::now() + std::chrono::milliseconds(200))) continue;
      auto completion = receiveFrame(socket.get(), noDeadline);
      if (!completion) fail("open: the open service closed the connection");
      return 0;
    }
  } catch (const std::exception& error) {
    std::cerr << "open: " << error.what() << '\n';
    return 1;
  }
}
