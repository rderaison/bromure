def fn(path):
    import os

    try:
        with open(os.path.join(path, ".landlock-test"), "w") as f:
            f.write("test")
        return "OK"
    except PermissionError:
        return "EPERM"
    except OSError as e:
        return f"ERROR:{e.errno}"
