# Used by bootstrap.nix (host world). installer.nix compiles the same
# sources with the target toolchain and does not use this file.
CC ?= cc
CFLAGS ?= -O2
CFLAGS += -std=c11 -Wall -Wextra -Werror
CPPFLAGS += $(shell pkg-config --cflags libxml-2.0 libcrypto zlib)
LDLIBS += $(shell pkg-config --libs libxml-2.0 libcrypto zlib)
CPPFLAGS += -isystem $(QUICKJS)/include/quickjs
LDLIBS += $(QUICKJS)/lib/libquickjs.a -lm -lpthread

SOURCES = main.c util.c xml.c xar.c cpio.c package.c install.c receipts.c installer-js.c js-plist.c
OBJECTS = $(SOURCES:.c=.o)

mdpkg: $(OBJECTS)
	$(CC) $(LDFLAGS) $(OBJECTS) $(LDLIBS) -o $@

$(OBJECTS): mdpkg.h installer-js.h

.PHONY: clean
clean:
	rm -f mdpkg $(OBJECTS)
