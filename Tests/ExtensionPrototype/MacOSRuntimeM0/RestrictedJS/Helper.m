#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#include <pthread.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <unistd.h>

// M0 research only: no JSExport/native objects, Node globals, require, filesystem,
// network, subprocess, inspector or Objective-C bridge is exposed to the script.
static void *watchParent(void *unused) {
    char byte;
    for (;;) {
        ssize_t count = read(3, &byte, 1);
        if (count == 0) _exit(0); // kernel EOF, not a callback scheduled on the JS thread
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) _exit(70);
        _exit(70); // this experiment's liveness channel accepts no data messages
    }
}
static void emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data || data.length > 65536) _exit(71);
    [[NSFileHandle fileHandleWithStandardOutput] writeData:data];
    [[NSFileHandle fileHandleWithStandardOutput] writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
}
int main(void) {
    @autoreleasepool {
        struct rlimit core = {0, 0};
        if (setrlimit(RLIMIT_CORE, &core) != 0) { fprintf(stderr, "M0 core guard failed\n"); return 70; }
        if (fcntl(3, F_GETFD) < 0) { fprintf(stderr, "M0 liveness FD missing\n"); return 70; }
#ifndef M0_DISABLE_PARENT_WATCH
        pthread_t guard;
        if (pthread_create(&guard, NULL, watchParent, NULL) != 0) return 70;
        pthread_detach(guard);
#endif
        NSMutableData *input = [NSMutableData data];
        for (;;) {
            char bytes[4096]; ssize_t count = read(STDIN_FILENO, bytes, sizeof bytes);
            if (count == 0) break;
            if (count < 0 && errno == EINTR) continue;
            if (count < 0 || input.length + count > 65536) return 71;
            [input appendBytes:bytes length:count];
        }
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
        if (![request isKindOfClass:NSDictionary.class] || ![request[@"source"] isKindOfClass:NSString.class]) return 71;
        // A native-side first-party control checks the actual OS restriction.
        // Neither this path nor any callable filesystem API is installed in JS.
        NSDictionary *fileControl = @{ @"tested": @NO };
        if ([request[@"probeFile"] isKindOfClass:NSString.class]) {
            errno = 0;
            int fd = open([request[@"probeFile"] fileSystemRepresentation], O_RDONLY | O_CLOEXEC);
            int error = fd < 0 ? errno : 0;
            if (fd >= 0) close(fd);
            fileControl = @{ @"tested": @YES, @"allowed": @((BOOL)(fd >= 0)), @"errno": @(error) };
        }
        emit(@{ @"ready": @YES, @"pid": @(getpid()), @"fileControl": fileControl });
        JSContext *context = [[JSContext alloc] init];
        if (!context) return 70;
        context.inspectable = NO;
        // First-party lifecycle telemetry only: no arguments or native objects.
        // It proves the script entered, rather than cancelling during engine init.
        __block BOOL entered = NO;
        context[@"__m0Entered"] = ^{
            if (!entered) { entered = YES; emit(@{ @"entered": @YES }); }
        };
        JSValue *value = [context evaluateScript:request[@"source"]];
        if (context.exception) { emit(@{ @"scriptError": @YES }); return 72; }
        if (!value || !value.isString) return 71;
        NSString *output = value.toString;
        if ([output lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 32768) return 71;
        emit(@{ @"result": output });
        return 0;
    }
}
