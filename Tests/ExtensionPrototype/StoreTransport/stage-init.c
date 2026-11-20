// Controlled fixed-recipe fixture. Not an arbitrary package installer.
#define main existing_guest_main
#include "../LinuxGuest/init.c"
#undef main
#include <sys/resource.h>
#include <signal.h>
static void timeout_handler(int signal_number) { (void)signal_number; _exit(124); }
static int child(int fd,const char *script,const char *stage) {
 pid_t p=fork(); if(p<0)return 0;
 if(!p){
  struct rlimit limit={8192,8192}; if(setrlimit(RLIMIT_FSIZE,&limit))_exit(126);
  if(dup2(fd,3)<0 || fcntl(3,F_SETFD,0)<0)_exit(126);
  if(fd!=3)close(fd);
  enter_worker();
  execl("/usr/bin/node","node",script,stage,NULL);_exit(127);
 }
 int status;return waitpid(p,&status,0)==p && WIFEXITED(status) && !WEXITSTATUS(status);
}
static int seal(const char *path) {
 struct stat st;
 return !lstat(path,&st) && S_ISREG(st.st_mode) && st.st_nlink==1 && st.st_size<=4096 &&
  !chown(path,0,0) && !chmod(path,0444) && !chown("/handoff",0,0) && !chmod("/handoff",0555);
}
int main(void){
 const char *phase=getenv("KEYLANE_PHASE");
 if(!phase || (strcmp(phase,"fixture-build") && strcmp(phase,"fixture-run")))return 1;
 struct rlimit limit={8192,8192}; if(setrlimit(RLIMIT_FSIZE,&limit))return 1;
 if(signal(SIGALRM,timeout_handler)==SIG_ERR)return 1;
 alarm(20);
 load_module("/modules/virtio_mmio.ko");load_module("/modules/vsock.ko");
 load_module("/modules/vmw_vsock_virtio_transport_common.ko");load_module("/modules/vmw_vsock_virtio_transport.ko");
 if(mount("proc","/proc","proc",0,NULL) || mount("devtmpfs","/dev","devtmpfs",0,NULL) ||
  mkdir("/handoff",0700) || chown("/handoff",65534,65534))return 2;
 int build=!strcmp(phase,"fixture-build"),fd=connect_broker();
 if(!child(fd,"/stage-receiver.cjs",build?"receive-source":"receive-artifact"))return 3;
 if(!seal(build?"/handoff/source.ts":"/handoff/bundle.cjs"))return 4;
 // Only init can create the compiler child; existing enter_worker seccomp is unchanged.
 if(build && !build_bundle("/handoff/source.ts"))return 5;
 if(!child(fd,"/stage-output.cjs",build?"export":"execute"))return 6;
 close(fd);for(;;)pause();
}
