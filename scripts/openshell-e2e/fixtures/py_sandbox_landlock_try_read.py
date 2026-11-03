def fn(path):
    import os

    try:
        entries = os.listdir(path)
        return f"OK:{len(entries)}"
    except PermissionError:
        return "EPERM"
    except OSError as e:
        return f"ERROR:{e.errno}"
