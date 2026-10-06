#!/bin/bash
# Run a command fully detached from the agent or terminal session: new session (setsid) + double fork, so the
# process is re-parented to launchd (ppid 1) and survives the session's teardown.
# `nohup … & disown` does NOT survive it: the launcher, supervisor and caffeinate all die with the session.
# No placeholders: this script is project-neutral.
# Usage: templates/detach.sh PIDFILE CMD [ARGS...]   (PIDFILE receives the detached pid)
pidfile=$1; shift
python3 - "$pidfile" "$@" <<'PY'
import os, sys
pidfile, argv = sys.argv[1], sys.argv[2:]
if os.fork():
    os._exit(0)                      # parent returns at once
os.setsid()                          # new session, no controlling terminal
if os.fork():
    os._exit(0)                      # session leader exits; grandchild is re-parented to launchd
open(pidfile, "w").write(f"{os.getpid()}\n")
fd = os.open(os.devnull, os.O_RDWR)
for i in (0, 1, 2):
    os.dup2(fd, i)
os.execvp(argv[0], argv)
PY
