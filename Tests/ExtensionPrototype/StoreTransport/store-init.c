// Candidate Store-only guest init. No device sharing/network; all authority is
// single use inside this guest. Rely on the existing no-new-privileges worker
// and use the pinned Linux esbuild only, never package scripts or argv flags.
#define main existing_guest_main
#include "../LinuxGuest/init.c"
#undef main
#include <signal.h>
#include <sys/resource.h>

static void timeout_handler(int signo) { (void)signo; _exit(124); }

static int entry_path(const char *path) {
    if (!path || !*path || strlen(path) > 1024) return 0;
    size_t len = 0;
    const char *segment = path;
    for (const char *p = path; ; p++) {
        char c = *p;
        if (!c || c == '/') {
            if (!len || *segment == '-' || (len == 1 && *segment == '.') ||
                (len == 2 && segment[0] == '.' && segment[1] == '.')) return 0;
            if (!c) return 1;
            len = 0;
            segment = p + 1;
        } else {
            if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
                  (c >= 'a' && c <= 'z') || strchr("._+@-", c))) return 0;
            len++;
        }
    }
}

static int approved_entry(const char *entry) {
    return entry_path(entry) &&
        (!strncmp(entry, "src/", 4));
}

static int node_step(int fd, const char *stage, const char *entry) {
    pid_t p = fork();
    if (p < 0) return 0;
    if (!p) {
        if (dup2(fd, 3) < 0 || fcntl(3, F_SETFD, 0) < 0) _exit(126);
        if (fd != 3) close(fd);
        enter_worker();
        execl("/usr/bin/node", "node", "/store-stage.cjs", stage, entry, NULL);
        _exit(127);
    }
    int status;
    return waitpid(p, &status, 0) == p && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static int seal_file(const char *path, off_t maximum) {
    struct stat st;
    return !lstat(path,&st) && S_ISREG(st.st_mode) && st.st_nlink == 1 && st.st_size > 0 &&
        st.st_size <= maximum && !chown(path,0,0) && !chmod(path,0444);
}

int main(void) {
    const char *phase = getenv("KEYLANE_PHASE");
    const char *entry = getenv("KEYLANE_STORE_ENTRY");
    if (!phase || (strcmp(phase, "store-build") && strcmp(phase, "store-run"))) return 1;
    const int building = !strcmp(phase, "store-build");
    if (building && !approved_entry(entry)) return 1;
    struct rlimit artifact_limit = {32 * 1024 * 1024, 32 * 1024 * 1024};
    if (setrlimit(RLIMIT_FSIZE, &artifact_limit) || signal(SIGALRM, timeout_handler) == SIG_ERR) return 1;
    alarm(25);
    load_module("/modules/virtio_mmio.ko");
    load_module("/modules/vsock.ko");
    load_module("/modules/vmw_vsock_virtio_transport_common.ko");
    load_module("/modules/vmw_vsock_virtio_transport.ko");
    if (mount("proc","/proc","proc",0,NULL) || mount("devtmpfs","/dev","devtmpfs",0,NULL) ||
        mkdir("/staging",0700) || chown("/staging",65534,65534)) return 2;
    int fd = connect_broker();
    if (building) {
        if (!node_step(fd,"receive-source",entry)) return 3;
        // The data receiver is the only worker so far; it wrote exclusive
        // read-only regular files. No extension process can mutate the tree.
        char source[1100];
        int n = snprintf(source,sizeof(source),"/staging/project/%s",entry);
        if (n <= 0 || (size_t)n >= sizeof(source) || !build_bundle(source) ||
            !node_step(fd,"export-artifact",NULL)) return 4;
    } else {
        if (!node_step(fd,"receive-artifact",NULL)) return 5;
        if (!seal_file("/staging/bundle.cjs",4*1024*1024) || !seal_file("/staging/launch.json",4096) ||
            chown("/staging",0,0) || chmod("/staging",0555) ||
            !node_step(fd,"run-artifact",NULL)) return 6;
    }
    shutdown(fd,SHUT_WR);
    close(fd);
    for (;;) pause();
}
