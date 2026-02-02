# Speed Bump Tests Makefile
#
# Builds tests with MOCK_KERNEL for userspace testing of kernel module logic.

CC = gcc
CFLAGS = -Wall -Wextra -Werror -O2 -DMOCK_KERNEL -I. -I../src
LDFLAGS =

# Source directories
SRC_DIR = ../src
TEST_DIR = .

# Test targets
TESTS = test_delay test_match test_mock

# Source files from src/ needed for tests
DELAY_SRC = $(SRC_DIR)/speed_bump_delay.c
MATCH_SRC = $(SRC_DIR)/speed_bump_match.c

.PHONY: all clean test

all: $(TESTS)

test_delay: test_delay.c $(DELAY_SRC)
	$(CC) $(CFLAGS) -I$(SRC_DIR) -o $@ $^ $(LDFLAGS)

test_match: test_match.c $(MATCH_SRC)
	$(CC) $(CFLAGS) -I$(SRC_DIR) -o $@ $^ $(LDFLAGS)

test_mock: test_mock.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

test: all
	@echo "=== Running test_delay ==="
	./test_delay
	@echo ""
	@echo "=== Running test_match ==="
	./test_match
	@echo ""
	@echo "=== Running test_mock ==="
	./test_mock
	@echo ""
	@echo "All tests completed!"

clean:
	rm -f $(TESTS)
