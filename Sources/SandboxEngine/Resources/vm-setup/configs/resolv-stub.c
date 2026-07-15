#include <stddef.h>
#include <stdarg.h>
#include <fcntl.h>

/* gcompat lacks these glibc resolver entry points. */
int __res_init(void) { return 0; }
int res_init(void) { return 0; }
int __res_nclose(void *s) { return 0; }
int __res_ninit(void *s) { return 0; }

/* glibc renamed fcntl -> fcntl64 (LFS is the default since glibc 2.28);
   musl and gcompat only export plain fcntl, so newer glibc binaries such
   as warp-cli fail to relocate. Forward the single variadic arg — on LP64
   a long covers both the int cmds (F_SETFD/F_SETFL/F_DUPFD) and the
   pointer cmds (F_SETLK/F_GETLK's struct flock *). fcntl stays undefined
   in this stub and binds to the host process's musl libc at load time. */
int fcntl64(int fd, int cmd, ...) {
    va_list ap;
    va_start(ap, cmd);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    return fcntl(fd, cmd, arg);
}
