#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/resource.h>

int main(void){@autoreleasepool{
struct rlimit core={0,0};setrlimit(RLIMIT_CORE,&core);
NSData *input=[[NSFileHandle fileHandleWithStandardInput]readDataToEndOfFile];if(input.length>262144)return 71;
NSDictionary *q=[NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
NSMutableDictionary *r=[NSMutableDictionary new];
for(NSString *key in @[@"file",@"link"]){errno=0;int fd=open([q[key]fileSystemRepresentation],O_RDONLY);int e=errno;if(fd>=0)close(fd);r[key]=@{@"allowed":@((BOOL)(fd>=0)),@"errno":@(e)};}
int socketFD=socket(AF_INET,SOCK_STREAM,0);struct sockaddr_in address={0};address.sin_len=sizeof address;address.sin_family=AF_INET;address.sin_port=htons([q[@"port"]intValue]);inet_pton(AF_INET,"127.0.0.1",&address.sin_addr);
errno=0;int connected=connect(socketFD,(struct sockaddr *)&address,sizeof address);int networkError=errno;close(socketFD);
r[@"network"]=@{@"allowed":@((BOOL)(connected==0)),@"errno":@(networkError)};
for(NSString *kind in @[@"signed",@"untrusted"]){
NSData *binary=[[NSData alloc]initWithBase64EncodedString:q[kind] options:0];if(binary.length>98304)return 71;
NSString *path=[NSTemporaryDirectory()stringByAppendingPathComponent:[NSString stringWithFormat:@".keylane-m0-%@-%@.dylib",q[@"tag"],kind]];
if(![binary writeToFile:path options:NSDataWritingWithoutOverwriting error:nil])return 70;
int fd=open(path.fileSystemRepresentation,O_RDONLY);BOOL readable=fd>=0;if(fd>=0)close(fd);
void *library=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);BOOL valid=NO;
if(library){int(*probe)(void)=dlsym(library,"M0Value");valid=probe&&probe()==42;dlclose(library);}
r[kind]=@{@"readable":@(readable),@"loaded":@((BOOL)(library!=NULL)),@"valueMatched":@(valid)};
if(unlink(path.fileSystemRepresentation)!=0)return 70;
}
NSData *out=[NSJSONSerialization dataWithJSONObject:r options:0 error:nil];[[NSFileHandle fileHandleWithStandardOutput]writeData:out];return 0;
}}
