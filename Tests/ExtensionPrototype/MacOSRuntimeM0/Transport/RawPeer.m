#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sys/socket.h>

// First-party native fault injector; never exported to JS or selected in product builds.
static void put(const void *bytes, size_t count) {
    size_t position = 0;
    while (position < count) {
        ssize_t n = write(4, (const char *)bytes + position, count - position);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) _exit(75);
        position += n;
    }
}
NSString *M0RunRawPeer(NSString *mode) {
    NSData *body = [@"{\"v\":1,\"id\":1,\"op\":\"storage.get\",\"key\":\"item\"}" dataUsingEncoding:NSUTF8StringEncoding];
    uint32_t header = htonl((uint32_t)body.length);
    if ([mode isEqualToString:@"valid"]) {
        for (int i = 0; i < 4; i++) { put((char *)&header+i, 1); usleep(10000); }
        put(body.bytes, body.length);
        unsigned char bytes[4]; size_t position = 0;
        while (position < 4) { ssize_t n = read(4, bytes+position, 4-position); if (n<=0) _exit(75); position+=n; }
        size_t size = ((uint32_t)bytes[0]<<24)|((uint32_t)bytes[1]<<16)|((uint32_t)bytes[2]<<8)|bytes[3];
        if (size > 4096 || size == 0) _exit(75);
        NSMutableData *reply = [NSMutableData dataWithLength:size]; position = 0;
        while (position < size) { ssize_t n = read(4,(char *)reply.mutableBytes+position,size-position); if(n<=0)_exit(75); position+=n; }
        NSDictionary *object = [NSJSONSerialization JSONObjectWithData:reply options:0 error:nil];
        return [object[@"ok"] isEqual:@YES] && [object[@"value"] isEqual:@"synthetic-a"] ? @"true" : @"false";
    }
    if ([mode isEqualToString:@"zero"]) { header=0; put(&header,4); }
    else if ([mode isEqualToString:@"huge"]) { header=UINT32_MAX; put(&header,4); }
    else if ([mode hasPrefix:@"short-header-"]) { put(&header, [[mode substringFromIndex:13] intValue]); }
    else if ([mode isEqualToString:@"short-body"]) { put(&header,4); put(body.bytes,3); }
    else _exit(75);
    shutdown(4, SHUT_WR);
    for (;;) pause(); // parent must detect invalid framing and terminate this peer
}
