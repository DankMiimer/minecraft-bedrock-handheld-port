# PC/WSL build for the telemetry module + tools.
# The same writer/hook sources compile into mcpelauncher-client via its
# CMake tree (see README.md); this Makefile is for standalone dev/test.
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=c11
LDLIBS   = -lrt -lm

BIN = telemetry_dump test_feed test_mirror

all: $(BIN)

# Fake mirror producer (the real one needs a live GL context).
test_mirror: test_mirror.c mcpe_mirror_abi.h
	$(CC) $(CFLAGS) -o $@ test_mirror.c $(LDLIBS)

# The GL capture path only COMPILES here — it cannot be exercised
# without a game. This target exists so a syntax/type break is caught in
# the fast host build instead of a 10-minute docker client rebuild.
mirror_writer_compile_check: mirror_writer.c mirror_writer.h mcpe_mirror_abi.h
	$(CC) $(CFLAGS) -c -o /tmp/mirror_writer.o mirror_writer.c
	@echo "mirror_writer.c compiles"

# downscale_flip correctness. The 1:1 fast path only triggers at exactly
# 640x480 (the RG DS game window), so it never runs on the host by
# accident — this is the only thing that exercises it.
test_downscale: test_downscale.c mirror_writer.c mcpe_mirror_abi.h
	$(CC) $(CFLAGS) -o $@ test_downscale.c $(LDLIBS)

check-downscale: test_downscale
	@./test_downscale

telemetry_dump: telemetry_dump.c mcpe_telemetry_abi.h
	$(CC) $(CFLAGS) -o $@ telemetry_dump.c $(LDLIBS)

test_feed: test_feed.c telemetry_writer.c fmod_listener_hook.c \
           telemetry_writer.h mcpe_telemetry_abi.h
	$(CC) $(CFLAGS) -o $@ test_feed.c telemetry_writer.c \
	    fmod_listener_hook.c $(LDLIBS)

# Smoke test: feed fake data, then verify the dump sees sane values.
# Also runs the downscale correctness test (the mirror's 1:1 fast path).
check: all check-downscale
	@MCPE_TELEMETRY_SHM=/mcpe_telemetry_test ./test_feed 4 & \
	FEED=$$!; sleep 2; \
	MCPE_TELEMETRY_SHM=/mcpe_telemetry_test ./telemetry_dump --once \
	    | tee /tmp/mcpe_tel_check.out; \
	wait $$FEED; \
	grep -q "pos=(" /tmp/mcpe_tel_check.out && \
	grep -q "fps=" /tmp/mcpe_tel_check.out && \
	echo "CHECK PASSED" || { echo "CHECK FAILED"; exit 1; }
	@rm -f /dev/shm/mcpe_telemetry_test
	@MCPE_TELEMETRY_SHM=/mcpe_telemetry_remote \
	  MCPE_TEST_REMOTE_WORLD=ipv6 ./test_feed 2 >/dev/null & \
	FEED=$$!; sleep 1; \
	MCPE_TELEMETRY_SHM=/mcpe_telemetry_remote ./telemetry_dump --once \
	    | tee /tmp/mcpe_tel_remote.out; \
	wait $$FEED; \
	grep -q "flags=\[.*remote " /tmp/mcpe_tel_remote.out && \
	echo "REMOTE WORLD CHECK PASSED" || { echo "REMOTE WORLD CHECK FAILED"; exit 1; }
	@rm -f /dev/shm/mcpe_telemetry_remote

clean:
	rm -f $(BIN) test_downscale

.PHONY: all check check-downscale mirror_writer_compile_check clean
