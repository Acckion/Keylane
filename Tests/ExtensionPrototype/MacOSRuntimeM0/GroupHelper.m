#import <Foundation/Foundation.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>

// First-party M0 candidate, not a production runner. The host creates a session
// for this helper; do not join or signal an ambient process group.
int main(int argc, char **argv) {
    @autoreleasepool {
        if (getpid() != getpgrp()) return 78;
        NSString *root = [[[NSString stringWithUTF8String:argv[0]] stringByDeletingLastPathComponent] stringByResolvingSymlinksInPath];
        NSString *node = [root stringByAppendingPathComponent:@"node"];
        NSArray<NSString *> *environment = @[
            @"PATH=/usr/bin:/bin", [@"HOME=" stringByAppendingString:NSHomeDirectory()],
            [@"TMPDIR=" stringByAppendingString:NSTemporaryDirectory()],
            [@"KEYLANE_M0_CONTAINER=" stringByAppendingString:NSHomeDirectory()]
        ];
        char *childArgs[] = {(char *)node.fileSystemRepresentation, "--max-old-space-size=64", "-", NULL};
        char *childEnv[5];
        for (NSUInteger i = 0; i < environment.count; ++i) childEnv[i] = (char *)environment[i].UTF8String;
        childEnv[4] = NULL;
        posix_spawnattr_t attributes;
        posix_spawn_file_actions_t actions;
        if (posix_spawnattr_init(&attributes) != 0) return 70;
        if (posix_spawn_file_actions_init(&actions) != 0) {
            posix_spawnattr_destroy(&attributes); return 70;
        }
        int error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
        if (!error) error = posix_spawnattr_setpgroup(&attributes, getpgrp());
        for (int fd = 0; fd < 3 && !error; ++fd) error = posix_spawn_file_actions_adddup2(&actions, fd, fd);
        pid_t child = -1;
        if (!error) error = posix_spawn(&child, node.fileSystemRepresentation, &actions, &attributes, childArgs, childEnv);
        posix_spawn_file_actions_destroy(&actions);
        posix_spawnattr_destroy(&attributes);
        if (error) return 70;
        int status = 0;
        while (waitpid(child, &status, 0) < 0) if (errno != EINTR) return 70;
        return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    }
}
