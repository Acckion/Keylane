#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <linux/sched.h>
#include <stddef.h>
#include <linux/vm_sockets.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

static void load_module(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0 || syscall(SYS_finit_module, fd, "", 0) < 0) {
        perror(path);
        exit(1);
    }
    close(fd);
}

static int connect_broker(void) {
    struct sockaddr_vm address = {
        .svm_family = AF_VSOCK, .svm_cid = VMADDR_CID_HOST, .svm_port = 4050
    };
    for (int attempt = 0; attempt < 80; attempt++) {
        int fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (fd >= 0) {
            if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) return fd;
            close(fd);
        }
        usleep(50000);
    }
    perror("virtio socket");
    exit(1);
}

static int exchange(FILE *input, FILE *output, const char *session, int request_id,
                    const char *capability, const char *text, const char *expected) {
    if (request_id == 0) {
        fprintf(output, "{\"kind\":\"hello\",\"session\":\"%s\",\"generation\":1,\"versions\":[1]}\n", session);
    } else {
        fprintf(output, "{\"kind\":\"request\",\"session\":\"%s\",\"generation\":1,"
                "\"version\":1,\"requestID\":%d,\"capability\":\"%s\",\"text\":\"%s\"}\n",
                session, request_id, capability, text);
    }
    char reply[16386];
    return fflush(output) == 0 && fgets(reply, sizeof(reply), input) && strstr(reply, expected);
}

// The guest policy permits threads but denies new processes for the sample tools.
static int restrict_process_creation(void) {
    struct sock_filter instructions[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_AARCH64, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        // Force libc to use clone with inspectable flags rather than a pointer to clone_args.
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone3, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ENOSYS),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone, 0, 5),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
        BPF_STMT(BPF_ALU | BPF_AND | BPF_K, CLONE_THREAD),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, CLONE_THREAD, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog filter = { .len = sizeof(instructions) / sizeof(instructions[0]), .filter = instructions };
    return prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0 &&
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &filter) == 0;
}

static void enter_worker(void) {
    if (setgroups(0, NULL) < 0 || setgid(65534) < 0 || setuid(65534) < 0 ||
        !restrict_process_creation()) {
        perror("guest worker isolation");
        _exit(126);
    }
}

static int build_bundle(const char *source) {
    if (mkdir("/work", 0700) < 0 || chown("/work", 65534, 65534) < 0) return 0;
    pid_t pid = fork();
    if (pid < 0) return 0;
    if (pid == 0) {
        enter_worker();
        const char *main_fields = !strcmp(source, "/menu-bar.tsx") ? "--main-fields=module,main" : NULL;
        const char *args[] = {"esbuild", source, "--bundle", "--platform=node", "--format=cjs",
            "--target=node22", "--external:@raycast/api", "--external:@raycast/utils", "--external:react", "--jsx=automatic",
            "--minify", "--outfile=/work/bundle.cjs", main_fields, NULL};
        execv("/esbuild", (char * const *)args);
        perror("exec esbuild");
        _exit(127);
    }
    int status;
    return waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static int run_node(const char *phase, const char *sentinel, const char *source, char *result, size_t capacity) {
    int pipefd[2];
    if (pipe(pipefd) < 0) return 0;
    pid_t pid = fork();
    if (pid < 0) return 0;
    if (pid == 0) {
        close(pipefd[0]);
        if (dup2(pipefd[1], STDOUT_FILENO) < 0) _exit(126);
        enter_worker();
        close(pipefd[1]);
        execl("/usr/bin/node", "node", "/node-stage.cjs", phase, sentinel, source, NULL);
        perror("exec node");
        _exit(127);
    }
    close(pipefd[1]);
    FILE *output = fdopen(pipefd[0], "r");
    if (!output) return 0;
    size_t count = fread(result, 1, capacity - 1, output);
    int complete = feof(output) && !ferror(output);
    fclose(output);
    int status;
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0 ||
        !complete || count == 0) return 0;
    result[count] = '\0';
    return strspn(result, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=") == count;
}

static int run_extension(int fd, const char *script) {
    pid_t pid = fork();
    if (pid < 0) return 0;
    if (pid == 0) {
        if (dup2(fd, 3) < 0 || fcntl(3, F_SETFD, 0) < 0 || dup2(STDERR_FILENO, STDOUT_FILENO) < 0)
            _exit(126);
        if (fd != 3) close(fd);
        enter_worker();
        execl("/usr/bin/node", "node", script, NULL);
        _exit(127);
    }
    int status;
    int success = waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0;
    if (success) fprintf(stderr, "keylane: Node confirmed broker replies\n");
    shutdown(fd, SHUT_WR);
    close(fd);
    return success;
}

int main(void) {
    fprintf(stderr, "keylane: init started\n");
    const char *session = getenv("KEYLANE_SESSION");
    const char *sentinel = getenv("KEYLANE_SENTINEL");
    const char *phase = getenv("KEYLANE_PHASE");
    if (!session || !sentinel || !phase) return 1;
    load_module("/modules/virtio_mmio.ko");
    load_module("/modules/vsock.ko");
    load_module("/modules/vmw_vsock_virtio_transport_common.ko");
    load_module("/modules/vmw_vsock_virtio_transport.ko");

    if (mount("proc", "/proc", "proc", 0, NULL) < 0) return 2;
    FILE *network = fopen("/proc/net/dev", "r");
    if (!network) return 3;
    unsigned interfaces = 0;
    char line[512];
    while (fgets(line, sizeof(line), network)) {
        if (strchr(line, ':')) {
            if (!strstr(line, "lo:")) return 4;
            interfaces++;
        }
    }
    fclose(network);
    if (interfaces != 1 || access(sentinel, F_OK) == 0 || errno != ENOENT) return 5;

    if (!strcmp(phase, "stall")) {
        fprintf(stderr, "keylane: intentionally waiting without a broker connection\n");
        for (;;) pause();
    }
    if (!strncmp(phase, "noview-", 7) || (!strcmp(phase, "view-app") || !strcmp(phase, "uuid-storage-app"))) {
        if (mkdir("/support", 0700) < 0 || chown("/support", 65534, 65534) < 0 ||
            mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) < 0 ||
            !run_extension(connect_broker(), !strncmp(phase, "noview-", 7) ? "/no-view.cjs" : "/view.cjs")) return 9;
        for (;;) pause();
    }
    if (!strcmp(phase, "log-flood")) {
        for (int i = 0; i < 65536; i++) fputc('x', stderr);
        for (;;) pause();
    }
    char result[12288];
    if (!strcmp(phase, "build") || !strcmp(phase, "uuid-build") || !strcmp(phase, "view-build") || !strcmp(phase, "uuid-suite-build") || !strcmp(phase, "menu-bar-build") || !strcmp(phase, "run")) {
        const char *stage = !strcmp(phase, "run") ? "run" : "build";
        const char *source = !strcmp(phase, "view-build") ? "/chmod.tsx" :
            !strcmp(phase, "uuid-suite-build") ? "/uuid-suite.ts" :
            !strcmp(phase, "menu-bar-build") ? "/menu-bar.tsx" : "/dependency.ts";
        if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) < 0 ||
            (!strcmp(stage, "build") && !build_bundle(source)) ||
            !run_node(stage, sentinel, source, result, sizeof(result))) return 8;
    } else {
        strcpy(result, "loopback-only-host-file-absent");
    }
    fprintf(stderr, "keylane: preflight passed\n");
    int fd = connect_broker();
    fprintf(stderr, "keylane: vsock connected\n");
    FILE *input = fdopen(fd, "r");
    FILE *output = fdopen(dup(fd), "w");
    if (!input || !output) return 6;
    if (!exchange(input, output, session, 0, NULL, NULL, "\"ready\"")) return 7;
    if (!strcmp(phase, "oversize")) {
        fprintf(stderr, "keylane: sending oversized frame\n");
        for (int i = 0; i < 16385; i++) fputc('x', output);
        fflush(output);
    } else if (!strcmp(phase, "malformed") || !strcmp(phase, "partial")) {
        fprintf(stderr, "keylane: sending %s frame\n", phase);
        fputs(!strcmp(phase, "partial") ? "{" : "{bad}\n", output);
        fflush(output);
    } else {
        // A generation-zero request must produce no reply and consume no request ID.
        fprintf(output, "{\"kind\":\"request\",\"session\":\"%s\",\"generation\":0,"
                "\"version\":1,\"requestID\":99,\"capability\":\"echo\",\"text\":\"stale\"}\n", session);
        if (!exchange(input, output, session, 1, "file.read", "host-sentinel", "\"denied\"")) return 7;
        if (!strcmp(phase, "replay")) {
            fprintf(stderr, "keylane: replaying request ID\n");
            fprintf(output, "{\"kind\":\"request\",\"session\":\"%s\",\"generation\":1,"
                    "\"version\":1,\"requestID\":1,\"capability\":\"echo\",\"text\":\"replay\"}\n", session);
            fflush(output);
        } else {
            if (!exchange(input, output, session, 2, "echo", result, "\"result\"")) return 7;
            fprintf(stderr, "keylane: broker replies verified\n");
        }
    }
    shutdown(fd, SHUT_WR);
    fclose(output);
    fclose(input);
    // The host owns shutdown, including termination when no connection completes.
    for (;;) pause();
}
