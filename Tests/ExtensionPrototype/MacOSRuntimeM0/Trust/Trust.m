#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#import "Profile.h"

@protocol M0TrustProtocol
- (void)readWithReply:(void (^)(NSData *, int))reply;
- (void)swap:(NSData *)expected replacement:(NSData *)replacement reply:(void (^)(BOOL, int))reply;
@end
static void emit(NSDictionary *record) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    [[NSFileHandle fileHandleWithStandardOutput] writeData:data];
    [[NSFileHandle fileHandleWithStandardOutput] writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
}
static NSDictionary *query(void) {
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService:M0_SERVICE,(__bridge id)kSecAttrAccount:@"receipt-head",
             (__bridge id)kSecUseAuthenticationUI:(__bridge id)kSecUseAuthenticationUIFail};
}
static OSStatus readItem(NSData **value) {
    NSMutableDictionary *q=[query() mutableCopy];
    q[(__bridge id)kSecReturnData]=@YES; q[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
    CFTypeRef result=NULL; OSStatus status=SecItemCopyMatching((__bridge CFDictionaryRef)q,&result);
    if(status==errSecSuccess) *value=CFBridgingRelease(result);
    else if(result)CFRelease(result);
    return status;
}
static BOOL actualPath(NSString *expected) {
    char raw[PATH_MAX],actual[PATH_MAX],enrolled[PATH_MAX]; uint32_t size=sizeof raw;
    if(_NSGetExecutablePath(raw,&size)!=0)return NO;
    if(!realpath(raw,actual)||!realpath(expected.fileSystemRepresentation,enrolled))return NO;
    return strcmp(actual,enrolled)==0;
}
#if M0_TRUST_SERVER
#import <sys/file.h>
#import <fcntl.h>
@interface Authority : NSObject<M0TrustProtocol,NSXPCListenerDelegate>
@end
@implementation Authority
- (int)locked:(int (^)(void))body {
    @synchronized(self) {
    int directory=open(M0_LOCK_ROOT.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(directory<0)return 70;
    int fd=openat(directory,"authority.lock",O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    struct stat info={0},named={0},parent={0},namedParent={0};
    if(fd<0||fstat(fd,&info)!=0||fstatat(directory,"authority.lock",&named,AT_SYMLINK_NOFOLLOW)!=0||
       fstat(directory,&parent)!=0||lstat(M0_LOCK_ROOT.fileSystemRepresentation,&namedParent)!=0||
       parent.st_ino!=M0_ROOT_INODE||parent.st_dev!=M0_ROOT_DEVICE||!S_ISDIR(parent.st_mode)||
       parent.st_uid!=getuid()||(parent.st_mode&077)!=0||parent.st_ino!=namedParent.st_ino||parent.st_dev!=namedParent.st_dev||
       !S_ISREG(info.st_mode)||info.st_ino!=M0_LOCK_INODE||info.st_dev!=M0_LOCK_DEVICE||
       named.st_ino!=info.st_ino||named.st_dev!=info.st_dev||info.st_uid!=getuid()||info.st_nlink!=1||(info.st_mode&077)!=0) {
        if(fd>=0)close(fd); close(directory);return 70;
    }
    if(flock(fd,LOCK_EX)!=0){close(fd);close(directory);return 70;}
    int code=body();
    flock(fd,LOCK_UN);close(fd);close(directory);return code;
    }
}
- (void)readWithReply:(void (^)(NSData *,int))reply {
    __block NSData *value=nil;
    int status=[self locked:^int{return (int)readItem(&value);}];
    reply(value,status);
}
- (void)swap:(NSData *)expected replacement:(NSData *)replacement reply:(void (^)(BOOL,int))reply {
    if(expected.length>1024||replacement.length==0||replacement.length>1024){reply(NO,71);return;}
    __block BOOL swapped=NO;
    int status=[self locked:^int{
        NSData *current=nil; OSStatus result=readItem(&current);
        if(result!=errSecSuccess)return result;
        if(![current isEqual:expected])return 0;
        result=SecItemUpdate((__bridge CFDictionaryRef)query(),(__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:replacement});
        if(result==errSecSuccess)swapped=YES;
        return result;
    }];
    reply(swapped,status);
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    [connection setCodeSigningRequirement:M0_CLIENT_REQUIREMENT];
    connection.exportedInterface=[NSXPCInterface interfaceWithProtocol:@protocol(M0TrustProtocol)];
    connection.exportedObject=self;[connection resume];return YES;
}
@end
#endif

int main(int argc,char **argv) {
    @autoreleasepool {
        SecKeychainSetUserInteractionAllowed(false); // process-local; never display authorization UI
#if M0_TRUST_SERVER
#ifndef M0_TRUST_FOREIGN_SERVER
        if(!actualPath(M0_SERVER_PATH)){emit(@{@"pathRejected":@YES});return 77;}
        if(argc==2&&strcmp(argv[1],"secondary")!=0) {
            NSString *mode=[NSString stringWithUTF8String:argv[1]];
            if([mode isEqual:@"delete"]) {
                OSStatus status=SecItemDelete((__bridge CFDictionaryRef)query());
                emit(@{@"removed":@((BOOL)(status==0||status==errSecItemNotFound)),@"status":@(status)});
                return status==0||status==errSecItemNotFound?0:70;
            }
            if(![mode isEqual:@"create"])return 71;
            NSString *marker=[M0_LOCK_ROOT stringByAppendingPathComponent:@"enrolled"];
            int guard=open(marker.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
            if(guard<0){emit(@{@"enrollmentRejected":@YES});return 77;}
            fsync(guard);close(guard);
            NSMutableDictionary *add=[query() mutableCopy];
            add[(__bridge id)kSecValueData]=[M0_INITIAL dataUsingEncoding:NSUTF8StringEncoding];
            // Default owner ACL is generated by the real owning process. Do not
            // install a hand-built legacy ACL with an unusable owner entry.
            OSStatus status=SecItemAdd((__bridge CFDictionaryRef)add,NULL);
            emit(@{@"created":@((BOOL)(status==0)),@"status":@(status)});return status==0?0:70;
        }
        NSData *value=nil;OSStatus status=readItem(&value);
        if(status!=0){emit(@{@"rootUnavailable":@YES,@"status":@(status)});return 78;}
#endif
        Authority *authority=[Authority new];
#ifdef M0_TRUST_FOREIGN_SERVER
        NSString *name=[M0_MACH_NAME stringByAppendingString:@".foreign"];
#else
        NSString *name=argc==2?[M0_MACH_NAME stringByAppendingString:@".secondary"]:M0_MACH_NAME;
#endif
        NSXPCListener *listener=[[NSXPCListener alloc]initWithMachServiceName:name];listener.delegate=authority;
        [listener setConnectionCodeSigningRequirement:M0_CLIENT_REQUIREMENT];[listener resume];
        emit(@{@"listening":@YES});
        dispatch_main();return 0;
#elif M0_TRUST_CLIENT
#if !M0_TRUST_TEST_SKIP_PATH && !M0_TRUST_TEST_UNVERIFIED
        if(!actualPath(M0_CLIENT_PATH)){emit(@{@"pathRejected":@YES});return 77;}
#endif
        NSData *input=[[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        if(input.length>65536)return 71;
        NSDictionary *request=[NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
        NSString *endpoint=request[@"endpoint"];
        if(![endpoint isEqual:M0_MACH_NAME]&&![endpoint isEqual:[M0_MACH_NAME stringByAppendingString:@".foreign"]]&&![endpoint isEqual:[M0_MACH_NAME stringByAppendingString:@".secondary"]])return 71;
        NSXPCConnection *connection=[[NSXPCConnection alloc] initWithMachServiceName:endpoint options:0];
#if !M0_TRUST_TEST_UNVERIFIED
        [connection setCodeSigningRequirement:M0_SERVER_REQUIREMENT];
#endif
        connection.remoteObjectInterface=[NSXPCInterface interfaceWithProtocol:@protocol(M0TrustProtocol)];[connection resume];
        dispatch_semaphore_t completion=dispatch_semaphore_create(0);
        NSLock *guard=[NSLock new]; __block BOOL done=NO;
        void (^finish)(NSDictionary *)=^(NSDictionary *value){[guard lock];if(!done){done=YES;emit(value);dispatch_semaphore_signal(completion);}[guard unlock];};
        void (^failure)(NSError *)=^(NSError *error){finish(@{@"peerRejected":@YES});};
        id<M0TrustProtocol> proxy=[connection remoteObjectProxyWithErrorHandler:failure];
        if([request[@"mode"] isEqual:@"read"]){
            [proxy readWithReply:^(NSData *value,int status){finish(@{@"ok":@((BOOL)(status==0)),@"value":[[NSString alloc]initWithData:value?:[NSData data] encoding:NSUTF8StringEncoding]?:@"",@"status":@(status)});}];
        } else {
            NSData *expected=[request[@"expected"] dataUsingEncoding:NSUTF8StringEncoding];
            NSData *replacement=[request[@"replacement"] dataUsingEncoding:NSUTF8StringEncoding];
            [proxy swap:expected replacement:replacement reply:^(BOOL swapped,int status){finish(@{@"ok":@((BOOL)(status==0)),@"swapped":@(swapped),@"status":@(status)});}];
        }
        long timedOut=dispatch_semaphore_wait(completion,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC));
        if(timedOut)finish(@{@"peerRejected":@YES});[connection invalidate];return timedOut?79:0;
#else
        // Native sandbox control. No JS API is added for Keychain access.
        NSData *value=nil;OSStatus status=readItem(&value);
        emit(@{@"allowed":@((BOOL)(status==0)),@"status":@(status)});return 0;
#endif
    }
}
