def current_user() -> str:
    import os
    import pwd

    return pwd.getpwuid(os.getuid()).pw_name
