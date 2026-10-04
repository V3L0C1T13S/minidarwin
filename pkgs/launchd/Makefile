CXX ?= c++
CPPFLAGS ?=
CXXFLAGS ?= -O2 -g
WARNINGS = -std=c++23 -Wall -Wextra -Werror -Wpedantic
LDLIBS ?= -lxml2

all: launchd launchctl
launchd: daemon.cpp job.cpp common.cpp common.hpp job.hpp
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(WARNINGS) daemon.cpp job.cpp common.cpp $(LDFLAGS) $(LDLIBS) -o $@
launchctl: client.cpp common.cpp common.hpp
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(WARNINGS) client.cpp common.cpp $(LDFLAGS) $(LDLIBS) -o $@
unit-test: unit-test.cpp job.cpp common.cpp common.hpp job.hpp
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(WARNINGS) unit-test.cpp job.cpp common.cpp $(LDFLAGS) $(LDLIBS) -o $@
clean:
	rm -f launchd launchctl unit-test
.PHONY: all clean
