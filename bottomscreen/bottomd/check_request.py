#!/usr/bin/env python3
"""check_request.py — assert the mirror capture-request channel state.

The request channel (bottomd -> client) is what actually turns
glReadPixels on, since 1.16.221.01 never signals a container. Getting it
stuck ON would mean a permanent readback tax during normal play, so both
directions are worth guarding.

Usage: check_request.py /dev/shm/<name> <expected_want 0|1>
"""
import struct
import sys
import time

# magic u32 | abi u32 | want u32 | seq u32 | update_ns u64
HDR = struct.Struct("<IIIIQ")
MAGIC = 0x4D435251
STALE_NS = 3_000_000_000


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    path, want = sys.argv[1], int(sys.argv[2])
    try:
        with open(path, "rb") as f:
            buf = f.read(HDR.size)
    except OSError as e:
        print("FAIL  cannot read %s: %s" % (path, e))
        return 1
    if len(buf) < HDR.size:
        print("FAIL  %s too short (%d bytes)" % (path, len(buf)))
        return 1

    magic, abi, got, seq, update_ns = HDR.unpack(buf)
    if magic != MAGIC:
        print("FAIL  bad magic 0x%08x (expected 0x%08x)" % (magic, MAGIC))
        return 1

    now = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
    age = (now - update_ns) / 1e9 if update_ns else float("inf")
    desc = "want=%d seq=%d age=%.2fs abi=%d" % (got, seq, age, abi)

    if got != want:
        print("FAIL  expected want=%d, %s" % (want, desc))
        return 1
    # A request only counts if the heartbeat is fresh — that is the whole
    # protection against a dead bottomd pinning capture on.
    if want == 1 and age > STALE_NS / 1e9:
        print("FAIL  want=1 but heartbeat is stale, %s" % desc)
        return 1
    print("OK    request %s" % desc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
