import os, time
deadline = time.monotonic() + 60
while not os.path.exists(@@PATH_PY@@) and time.monotonic() < deadline:
    time.sleep(0.1)
if not os.path.exists(@@PATH_PY@@):
    if os.path.exists(@@LOG_PY@@):
        print(open(@@LOG_PY@@).read())
    raise SystemExit("timed out waiting for @@PATH@@")
print(open(@@PATH_PY@@).read())
