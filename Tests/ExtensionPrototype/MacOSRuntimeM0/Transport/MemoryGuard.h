#include <stdint.h>
typedef struct M0MemoryGuard M0MemoryGuard;
M0MemoryGuard *M0MemoryGuardStart(int pid, uint64_t limit, int enforce);
// Stop/join BEFORE waitpid reaps the child: its PID cannot be reused under the watcher.
void M0MemoryGuardStop(M0MemoryGuard *guard, uint64_t *peak, int *exceeded, int *failed);
int M0StopChildUnreaped(int pid);
