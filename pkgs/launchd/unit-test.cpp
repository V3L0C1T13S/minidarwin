#include "job.hpp"
#include <cerrno>
#include <fcntl.h>
#include <grp.h>
#include <signal.h>
#include <sys/wait.h>
#include <thread>
#include <iostream>
#include <unistd.h>

namespace {
void require(bool value, const char* message) { if (!value) throw md::Error(message); }
md::Value config() {
  return md::Value(md::Value::Dict{{"Label", md::Value(std::string("test.job"))},
    {"Program", md::Value(std::string("/bin/echo"))}});
}
}
int main(int argc, char** argv) {
  // Helpers execute through the same fork/setup/exec path as real jobs.
  if (argc == 3 && std::string(argv[1]) == "--fd-probe") {
    int fd = std::stoi(argv[2]);
    return fcntl(fd, F_GETFD) == -1 && errno == EBADF ? 0 : 1;
  }
  if (argc == 3 && std::string(argv[1]) == "--identity-probe") {
    if (getuid() != 65534 || geteuid() != 65534 || getgid() != 65534 || getegid() != 65534) return 1;
    gid_t groups[32];
    int count = getgroups(32, groups);
    if (count < 0) return 1;
    bool extra = false;
    for (int i = 0; i < count; ++i) {
      if (groups[i] == 65533) extra = true;
      else if (groups[i] != 65534) return 1;
    }
    return extra == (std::string(argv[2]) == "extra") ? 0 : 1;
  }
  using namespace md;
  try {
    auto value = config();
    auto encoded = writePlist(value);
    auto decoded = parsePlist(encoded);
    require(decoded.has_value(), "roundtrip parse");
    auto valid = parseConfig(*decoded, true);
    require(valid && valid->throttle == 10 && valid->exitTimeout == 20, "defaults");
    require(!valid->runAtLoad && !valid->keepAlive, "default activation");
    require(valid->arguments == std::vector<std::string>{"/bin/echo"}, "default argv");
    for (const auto& xml : {
      "<plist><dict><key>Label</key><string>x</string><key>Label</key><string>y</string></dict></plist>",
      "<plist><dict><key>missing</key></dict></plist>",
      "<plist><dict/><dict/></plist>",
      "<plist><integer>9223372036854775808</integer></plist>",
      "<!DOCTYPE plist [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><plist><string>&x;</string></plist>",
      "<plist><string>&unknown;</string></plist>",
      "<plist><dict><key>x</key><string><bad/></string></dict></plist>",
      "<plist><data>AA==</data></plist>"}) require(!parsePlist(xml), "invalid XML accepted");
    require(parsePlist("<!DOCTYPE plist PUBLIC '-//Apple//DTD PLIST 1.0//EN' 'http://www.apple.com/DTDs/PropertyList-1.0.dtd'><plist><dict/></plist>").has_value(), "conventional DOCTYPE");
    require(!parsePlist(std::string("<plist/>\0x", 10)), "NUL rejected");
    auto framed = frame(value);
    require(frameSize(framed.data()) == framed.size() - 4, "frame length");
    for (const auto& key : {"Sockets", "MachServices", "StartInterval", "UserName", "GroupName"}) {
      auto bad = config(); std::get<Value::Dict>(bad.data).emplace(key, Value(true));
      require(!parseConfig(bad, true), "unsupported key accepted");
    }
    auto bad = config(); std::get<Value::Dict>(bad.data)["KeepAlive"] = Value(Value::Dict{});
    require(!parseConfig(bad, true), "conditional KeepAlive accepted");
    bad = config(); std::get<Value::Dict>(bad.data)["Program"] = Value(std::string("echo"));
    require(!parseConfig(bad, true), "relative executable accepted");
    bad = config(); std::get<Value::Dict>(bad.data)["ThrottleInterval"] = Value(std::int64_t(-1));
    require(!parseConfig(bad, true), "negative interval accepted");
    bad = config(); std::get<Value::Dict>(bad.data)["ThrottleInterval"] = Value(std::int64_t(0));
    require(parseConfig(bad, true)->throttle == 1, "zero interval floor");
    bad = config(); std::get<Value::Dict>(bad.data)["UserID"] = Value(std::int64_t(10));
    require(!parseConfig(bad, false), "partial identity accepted");
    std::get<Value::Dict>(bad.data)["GroupID"] = Value(std::int64_t(10));
    require(!parseConfig(bad, true), "foreground identity accepted");
    bad = config(); std::get<Value::Dict>(bad.data)["SupplementaryGroups"] = Value(Value::Array{});
    require(!parseConfig(bad, false), "groups without identity accepted");
    bad = config(); std::get<Value::Dict>(bad.data)["ProgramArguments"] = Value(Value::Array{});
    require(!parseConfig(bad, true), "empty argv accepted");
    bad = config(); std::get<Value::Dict>(bad.data)["EnvironmentVariables"] = Value(Value::Dict{{"A=B", Value(std::string("x"))}});
    require(!parseConfig(bad, true), "invalid environment accepted");
    int raw;
    {
      auto first = checkedFd(open("/dev/null", O_RDONLY), "open test");
      raw = first.get();
      Fd second(std::move(first));
      require(first.get() == -1 && second.get() == raw, "move ownership");
      Fd third; third = std::move(second);
      require(second.get() == -1 && third.get() == raw, "move assignment");
    }
    require(fcntl(raw, F_GETFD) == -1 && errno == EBADF, "descriptor leak");
    Job job(*valid);
    job.exitStatus = 0;
    auto status = jobStatus(job).as<Value::Dict>();
    require(required(status, "ExitStatus").as<std::int64_t>() == 0, "zero exit status omitted");
    auto runProbe = [&](Config probe) {
      Job child(std::move(probe));
      spawn(child);
      int status = 0;
      auto deadline = Clock::now() + std::chrono::seconds(5);
      while (waitpid(child.pid, &status, WNOHANG) == 0) {
        if (Clock::now() >= deadline) {
          kill(-child.pid, SIGKILL);
          waitpid(child.pid, &status, 0);
          throw Error("child probe timed out");
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      }
      drainExecError(child);
      require(child.launchError.empty(), "child probe setup failed");
      require(WIFEXITED(status) && WEXITSTATUS(status) == 0, "child probe failed");
    };
    Config probe;
    probe.label = "probe";
    probe.program = argv[0];
    auto inherited = checkedFd(fcntl(STDIN_FILENO, F_DUPFD, 200), "duplicate inherited descriptor");
    probe.arguments = {argv[0], "--fd-probe", std::to_string(inherited.get())};
    runProbe(probe);
    if (geteuid() == 0) {
      probe.uid = 65534; probe.gid = 65534;
      probe.arguments = {argv[0], "--identity-probe", "clear"};
      runProbe(probe);
      probe.groups = {65533};
      probe.arguments.back() = "extra";
      runProbe(probe);
      std::cout << "privileged credential-dropping probes passed\n";
    } else std::cout << "privileged credential-dropping probes skipped (requires root)\n";
    std::cout << "launchd unit tests passed\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
