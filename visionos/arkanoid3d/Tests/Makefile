# license:BSD-3-Clause
#
# Linux/macOS host tests for the Arkanoid state decoder.
#   make -C visionos/arkanoid3d/Tests          # build and run the unit tests
#   make -C visionos/arkanoid3d/Tests dump     # build the capture decoder tool

CC ?= cc
CFLAGS ?= -std=c11 -O1 -g -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wno-sign-conversion -Werror
DECODER := ../Decoder
OUT ?= ./build

all: test

$(OUT):
	mkdir -p $(OUT)

$(OUT)/test_ark3d: test_ark3d.c $(DECODER)/ark3d.c $(DECODER)/ark3d.h | $(OUT)
	$(CC) $(CFLAGS) -I$(DECODER) -o $@ test_ark3d.c $(DECODER)/ark3d.c

$(OUT)/ark3d_dump: ark3d_dump.c $(DECODER)/ark3d.c $(DECODER)/ark3d.h | $(OUT)
	$(CC) $(CFLAGS) -I$(DECODER) -o $@ ark3d_dump.c $(DECODER)/ark3d.c

test: $(OUT)/test_ark3d
	$(OUT)/test_ark3d

dump: $(OUT)/ark3d_dump

clean:
	rm -rf $(OUT)

.PHONY: all test dump clean
