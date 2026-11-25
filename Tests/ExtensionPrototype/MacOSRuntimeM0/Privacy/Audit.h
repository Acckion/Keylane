// First-party bounded observation only; absent from the normal helper build.
#include <dirent.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
typedef struct { BOOL complete,found; size_t files,bytes,dirs; } M0Scan;
static void M0Walk(int fd,NSData *marker,M0Scan *state) {
    if(++state->dirs>128){state->complete=NO;close(fd);return;}
    DIR *directory=fdopendir(fd);if(!directory){state->complete=NO;close(fd);return;}
    for(;;){
        errno=0;struct dirent *entry=readdir(directory);
        if(!entry){if(errno)state->complete=NO;break;}
        if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        struct stat info={0};
        if(fstatat(dirfd(directory),entry->d_name,&info,AT_SYMLINK_NOFOLLOW)!=0){state->complete=NO;break;}
        if(S_ISLNK(info.st_mode))continue;
        if(S_ISDIR(info.st_mode)) {
            int child=openat(dirfd(directory),entry->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            if(child<0){state->complete=NO;break;}M0Walk(child,marker,state);
        } else if(S_ISREG(info.st_mode)) {
            if(++state->files>512||info.st_size<0||info.st_size>2*1024*1024||state->bytes+(size_t)info.st_size>16*1024*1024){state->complete=NO;break;}
            int file=openat(dirfd(directory),entry->d_name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
            if(file<0){state->complete=NO;break;}
            NSMutableData *data=[NSMutableData data];char buffer[4096];
            for(;;){ssize_t n=read(file,buffer,sizeof buffer);if(n<0&&errno==EINTR)continue;if(n<0){state->complete=NO;break;}if(n==0)break;
                if(data.length+(size_t)n>2*1024*1024||state->bytes+(size_t)n>16*1024*1024){state->complete=NO;break;}
                [data appendBytes:buffer length:n];state->bytes+=n;
            }
            close(file);
            if([data rangeOfData:marker options:0 range:NSMakeRange(0,data.length)].location!=NSNotFound)state->found=YES;
        }
        if(!state->complete)break;
    }
    closedir(directory);
}
static NSDictionary *M0PrivacyControl(NSString *source) {
    NSString *home=NSHomeDirectory(),*identifier=NSBundle.mainBundle.bundleIdentifier;
    NSString *suffix=[@"/Library/Containers/"stringByAppendingString:[identifier stringByAppendingString:@"/Data"]];
    if(![home hasSuffix:suffix])return @{@"auditComplete":@NO};
    NSString *root=[home stringByAppendingPathComponent:@"Library/Caches"];
    NSString *control=[root stringByAppendingPathComponent:[@".m0-control-"stringByAppendingString:M0_PRIVACY_MARKER]];
    if([source isEqual:@"__m0AuditWrite"]) {
        [[NSFileManager defaultManager]createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        BOOL ok=[[M0_PRIVACY_MARKER dataUsingEncoding:NSUTF8StringEncoding]writeToFile:control options:NSDataWritingWithoutOverwriting error:nil];
        return @{@"controlWritten":@(ok)};
    }
    if([source isEqual:@"__m0AuditDelete"]) {
        BOOL exists=[[NSFileManager defaultManager]fileExistsAtPath:control];
        BOOL ok=!exists||[[NSFileManager defaultManager]removeItemAtPath:control error:nil];
        return @{@"controlRemoved":@(ok)};
    }
    if(![source isEqual:@"__m0AuditScan"])return nil;
    NSMutableSet *bases=[NSMutableSet setWithArray:@[[home stringByAppendingPathComponent:@"Library"],[home stringByAppendingPathComponent:@"tmp"]]];
    NSString *cache=[root stringByResolvingSymlinksInPath],*resolvedHome=[home stringByResolvingSymlinksInPath];
    if([cache hasPrefix:[resolvedHome stringByAppendingString:@"/"]]||[cache.lastPathComponent isEqual:identifier])[bases addObject:cache];
    else return @{@"auditComplete":@NO};
    M0Scan state={.complete=YES};NSData *marker=[M0_PRIVACY_MARKER dataUsingEncoding:NSUTF8StringEncoding];
    for(NSString *base in bases){
        int fd=open(base.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(fd<0){if(errno==ENOENT)continue;state.complete=NO;break;}M0Walk(fd,marker,&state);if(!state.complete)break;
    }
    return @{@"auditComplete":@(state.complete),@"markerFound":@(state.found),@"files":@(state.files)};
}
