#include "MemoryGuard.h"
#include <libproc.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>

struct M0MemoryGuard {
    pthread_t thread;
    atomic_bool stop;
    int pid, enforce, exceeded, failed;
    uint64_t limit, peak;
};
static void *watch(void *value) {
    M0MemoryGuard *guard = value;
    while (!atomic_load(&guard->stop)) {
        struct proc_taskinfo info = {0};
#ifdef M0_FORCE_SAMPLE_FAILURE
        int size = 0; // native test-only negative control, never a guest option
#else
        int size = proc_pidinfo(guard->pid, PROC_PIDTASKINFO, 0, &info, sizeof info);
#endif
        if (size == sizeof info) {
            if (info.pti_resident_size > guard->peak) guard->peak = info.pti_resident_size;
            if (info.pti_resident_size > guard->limit) {
                guard->exceeded = 1;
                if (guard->enforce) { kill(guard->pid, SIGKILL); break; }
            }
        } else {
            // Task teardown can precede BSD zombie status. Only a positive
            // kernel child-exit observation excuses a missing memory sample.
            // Do not reap: the parent's sole waitpid owns final PID retirement.
            int exited = 0;
            for (int attempt = 0; attempt < 3; attempt++) {
                siginfo_t info = {0};
                int result = waitid(P_PID, guard->pid, &info, WEXITED | WNOHANG | WNOWAIT);
                if (result == 0 && info.si_pid == guard->pid) { exited = 1; break; }
                if (attempt < 2) usleep(10000);
            }
            if (!exited) {
                guard->failed = 1;
                kill(guard->pid, SIGKILL);
            }
            break;
        }
        usleep(20000);
    }
    return NULL;
}
M0MemoryGuard *M0MemoryGuardStart(int pid, uint64_t limit, int enforce) {
    if (pid <= 0 || limit == 0) return NULL; // never turn a child PID into a process-group signal
    M0MemoryGuard *guard = calloc(1, sizeof *guard);
    if (!guard) return NULL;
    atomic_init(&guard->stop, 0);
    guard->pid = pid; guard->limit = limit; guard->enforce = enforce;
    if (pthread_create(&guard->thread, NULL, watch, guard) != 0) { free(guard); return NULL; }
    return guard;
}
void M0MemoryGuardStop(M0MemoryGuard *guard, uint64_t *peak, int *exceeded, int *failed) {
    atomic_store(&guard->stop, 1);
    pthread_join(guard->thread, NULL);
    *peak = guard->peak; *exceeded = guard->exceeded; *failed = guard->failed;
    free(guard);
}
int M0StopChildUnreaped(int pid) {
    // Caller owns this child and has not reaped it. Do not reuse for arbitrary PIDs.
    if (pid <= 0) return 0;
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) return 0;
    siginfo_t info = {0};
    int result;
    do { result = waitid(P_PID, pid, &info, WEXITED | WNOWAIT); } while (result != 0 && errno == EINTR);
    return result == 0 && info.si_pid == pid;
}
