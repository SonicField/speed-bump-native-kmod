# Makefile for sbctl userspace tool
#
# SPDX-License-Identifier: GPL-2.0

CC ?= gcc
CFLAGS ?= -Wall -Wextra -Werror -pedantic -O2
CFLAGS += -std=c99 -D_POSIX_C_SOURCE=200809L

TARGET = sbctl
SRCS = sbctl.c
OBJS = $(SRCS:.c=.o)

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

.PHONY: all clean install uninstall

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(TARGET) $(OBJS)

install: $(TARGET)
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 $(TARGET) $(DESTDIR)$(BINDIR)/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(TARGET)
