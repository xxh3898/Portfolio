#!/usr/bin/python3

import fcntl
import sys


if sys.argv[1:] != ["-s", "-t", "0", "9"]:
    raise SystemExit(64)

try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(75)
