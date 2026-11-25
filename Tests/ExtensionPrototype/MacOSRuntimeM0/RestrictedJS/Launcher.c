#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <limits.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <stdio.h>
#include <mach-o/dyld.h>

// Trusted first-party parent for testing kernel parent launch constraints.
// Fixed relative helper path, no manifest/user-selected executable or arguments.
int main(void) {
    char path[PATH_MAX]; uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size) != 0) return 70;
    char *slash = strrchr(path, '/'); if (!slash) return 70;
    *slash = '\0';
    const char *suffix = "/Capsule.app/Contents/MacOS/helper";
    if (strlen(path) + strlen(suffix) >= sizeof path) return 70;
    strcat(path, suffix);
    int life[2]; if (pipe(life) != 0) return 70;
    // dup2 onto a different FD explicitly clears close-on-exec for the reader.
    // Do not depend on platform behavior for a same-FD spawn dup2(3,3).
    int reader = fcntl(life[0], F_DUPFD_CLOEXEC, 10);
    if (reader < 0 || fcntl(life[1], F_SETFD, FD_CLOEXEC) < 0) return 70;
    close(life[0]); life[0] = reader;
    posix_spawnattr_t attr; posix_spawn_file_actions_t actions;
    if (posix_spawnattr_init(&attr) != 0) return 70;
    if (posix_spawn_file_actions_init(&actions) != 0) return 70;
    int error = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!error) error = posix_spawnattr_setpgroup(&attr, 0);
    for (int fd = 0; fd < 3 && !error; ++fd) error = posix_spawn_file_actions_adddup2(&actions, fd, fd);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, life[0], 3);
    char *args[] = {path, NULL};
    char *env[] = {"PATH=/usr/bin:/bin", NULL};
    pid_t child = -1;
    if (!error) error = posix_spawn(&child, path, &actions, &attr, args, env);
    posix_spawnattr_destroy(&attr); posix_spawn_file_actions_destroy(&actions);
    close(life[0]);
    if (error) { fprintf(stderr, "M0 spawn errno=%d\n", error); close(life[1]); return 70; }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) if (errno != EINTR) return 70;
    close(life[1]);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
