#import <Foundation/Foundation.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <sys/resource.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <string.h>
int main(void){@autoreleasepool{
struct rlimit core={0,0};setrlimit(RLIMIT_CORE,&core);
char binary[PATH_MAX];uint32_t count=sizeof binary;if(_NSGetExecutablePath(binary,&count)!=0)return 70;
char *tail=strrchr(binary,'/');if(!tail)return 70;*tail=0;if(strlen(binary)+9>=sizeof binary)return 70;strcat(binary,"/esbuild");
if(chdir(NSHomeDirectory().fileSystemRepresentation)!=0)return 70;
posix_spawnattr_t attr;posix_spawn_file_actions_t actions;if(posix_spawnattr_init(&attr)||posix_spawn_file_actions_init(&actions))return 70;
posix_spawnattr_setflags(&attr,POSIX_SPAWN_CLOEXEC_DEFAULT);
for(int fd=0;fd<3;fd++)posix_spawn_file_actions_adddup2(&actions,fd,fd);
char *args[]={binary,"--bundle","--platform=neutral","--format=iife","--minify","--loader=ts","--tsconfig-raw={}","--sourcefile=fixture.ts","--external:node:*","--log-level=error",NULL};
char *env[]={"PATH=/usr/bin:/bin",NULL};pid_t pid=-1;int error=posix_spawn(&pid,binary,&actions,&attr,args,env);
posix_spawnattr_destroy(&attr);posix_spawn_file_actions_destroy(&actions);if(error)return 70;
int status=0;while(waitpid(pid,&status,0)<0)if(errno!=EINTR)return 70;
return WIFEXITED(status)?WEXITSTATUS(status):128+WTERMSIG(status);
}}
