#include "MemoryGuard.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>

int main(void) {
    assert(!M0StopChildUnreaped(0)); assert(!M0StopChildUnreaped(-1));
    assert(!M0MemoryGuardStart(0, UINT64_MAX, 1));
    for (int i=0; i<50; i++) {
        pid_t child=fork(); assert(child>=0);
        if (child==0) { usleep((i%5)*1000); _exit(0); }
        M0MemoryGuard *guard=M0MemoryGuardStart(child, UINT64_MAX, 1); assert(guard);
        siginfo_t info={0}; int result;
        do { result=waitid(P_PID,child,&info,WEXITED|WNOWAIT); } while(result<0&&errno==EINTR);
        assert(result==0&&info.si_pid==child);
        uint64_t peak; int exceeded,failed;
        M0MemoryGuardStop(guard,&peak,&exceeded,&failed);
        int status=0; assert(waitpid(child,&status,0)==child);
        assert(WIFEXITED(status)&&WEXITSTATUS(status)==0);
        assert(!failed&&!exceeded);
    }
    // Strong stop confirms exit without reaping; the parent still owns waitpid.
    pid_t child=fork(); assert(child>=0);
    if(child==0)for(;;)pause();
    assert(M0StopChildUnreaped(child));
    int status=0; assert(waitpid(child,&status,0)==child);
    assert(WIFSIGNALED(status)&&WTERMSIG(status)==SIGKILL);
#ifdef M0_FORCE_SAMPLE_FAILURE
    child=fork(); assert(child>=0);
    if(child==0)for(;;)pause();
    M0MemoryGuard *guard=M0MemoryGuardStart(child,UINT64_MAX,1); assert(guard);
    siginfo_t info={0};
    assert(waitid(P_PID,child,&info,WEXITED|WNOWAIT)==0&&info.si_pid==child);
    uint64_t peak; int exceeded,failed;
    M0MemoryGuardStop(guard,&peak,&exceeded,&failed);
    assert(failed&&!exceeded);
    assert(waitpid(child,&status,0)==child);
    assert(WIFSIGNALED(status)&&WTERMSIG(status)==SIGKILL);
#endif
    puts("PASS 50 child-exit races and non-reaping forced stop");
}
