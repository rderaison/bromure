# drive.py <bromure-ac> | --ssh <ssh argv...>: on a pty, expects the remote
# menu, opens Workspaces (the daemon's workspace listed), leaves with q, q.
import os, pty, select, sys, time, re
if sys.argv[1] == "--ssh":
    argv = sys.argv[2:]
else:
    argv = [sys.argv[1], "__remote-menu"]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
out = b""
def read_until(pat, secs):
    global out
    strip = lambda b: re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", b)
    if re.search(pat, strip(out)): return True
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try: chunk = os.read(fd, 65536)
            except OSError: return False
            if not chunk: return False
            out += chunk
            if re.search(pat, re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out)): return True
    return False
def fail(msg):
    print("FAIL", msg); print(re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out)[-1500:].decode("utf-8", "replace"))
    try: os.kill(pid, 9)
    except ProcessLookupError: pass
    sys.exit(1)
if not read_until(rb"bromure-ac .+ remote", 10): fail("no top menu")
print("ok   top menu shown")
if not read_until(rb"Exit \(disconnect\)", 5): fail("no Exit item")
out = b""
os.write(fd, b"\r")                      # Workspaces
if not read_until(rb"menu-e2e-ws", 10): fail("the workspace isn't listed")
print("ok   Workspaces lists the daemon's workspace")
os.write(fd, b"q"); time.sleep(0.5); os.write(fd, b"q")
end = time.time() + 10
while time.time() < end:
    wpid, status = os.waitpid(pid, os.WNOHANG)
    if wpid: break
    try: os.read(fd, 65536)
    except OSError: pass
    time.sleep(0.1)
else: fail("menu didn't exit on q, q")
print("ok   q, q leaves the menu (status %d)" % os.waitstatus_to_exitcode(status))
sys.exit(0)
