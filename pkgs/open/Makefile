CXX ?= c++
CPPFLAGS ?=
CXXFLAGS ?= -O2 -g
WARNINGS = -std=c++23 -Wall -Wextra -Werror -Wpedantic
LDLIBS ?= -lxml2
COMMON = channel.cpp ../launchd/common.cpp
HEADERS = channel.hpp ../launchd/common.hpp

all: open opend
open: open.cpp $(COMMON) $(HEADERS)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(WARNINGS) open.cpp $(COMMON) $(LDFLAGS) $(LDLIBS) -o $@
opend: opend.cpp $(COMMON) $(HEADERS)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(WARNINGS) opend.cpp $(COMMON) $(LDFLAGS) $(LDLIBS) -o $@
clean:
	rm -f open opend
.PHONY: all clean
