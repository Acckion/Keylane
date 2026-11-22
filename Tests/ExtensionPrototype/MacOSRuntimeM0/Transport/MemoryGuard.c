#include "MemoryGuard.h"
#include <libproc.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/proc.h>
#include <unistd.h>

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
        int size = proc_pidinfo(guard->pid, PROC_PIDTASKINFO, 0, &info, sizeof info);
        if (size == sizeof info) {
            if (info.pti_resident_size > guard->peak) guard->peak = info.pti_resident_size;
            if (info.pti_resident_size > guard->limit) {
                guard->exceeded = 1;
                if (guard->enforce) { kill(guard->pid, SIGKILL); break; }
            }
        } else {
            // An exited unreaped child may already have no task. If still alive,
            // deny observation failure rather than silently claiming protection.
            struct proc_bsdinfo state = {0};
            int got = proc_pidinfo(guard->pid, PROC_PIDTBSDINFO, 0, &state, sizeof state);
            if (got != sizeof state || state.pbi_status != SZOMB) {
                guard->failed = 1; kill(guard->pid, SIGKILL);
            }
            break;
        }
        usleep(20000);
    }
    return NULL;
}
M0MemoryGuard *M0MemoryGuardStart(int pid, uint64_t limit, int enforce) {
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
