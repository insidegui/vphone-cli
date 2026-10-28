#include <dlfcn.h>
#include <errno.h>
#include <sys/types.h>

pid_t vp_ssh_fork(void) {
    pid_t (*native_fork)(void) = dlsym(RTLD_DEFAULT, "fork");
    if (!native_fork) { errno = ENOSYS; return -1; }
    return native_fork();
}
