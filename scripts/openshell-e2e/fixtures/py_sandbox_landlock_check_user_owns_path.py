def fn(path):
    import os

    try:
        st = os.stat(path)
        uid = os.getuid()
        return f"owner:{st.st_uid} me:{uid} match:{st.st_uid == uid}"
    except OSError as e:
        return f"ERROR:{e}"
