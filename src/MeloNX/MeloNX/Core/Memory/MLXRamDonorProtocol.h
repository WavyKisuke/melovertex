//
//  MLXRamDonorProtocol.h
//  MeloNX
//
//  RAM donor IPC protocol.
//

#ifndef MLXRamDonorProtocol_h
#define MLXRamDonorProtocol_h

@import Foundation;
#import <mach/mach.h>
#import <xpc/xpc.h>

#define MLX_DONOR_CHUNK_SIZE (256ull * 1024ull * 1024ull)
#define MLXDonorKeyOp        "op"
#define MLXDonorKeySize      "size"
#define MLXDonorKeyShmem     "shmem"
#define MLXDonorKeyError     "error"
#define MLXDonorKeyAvailable "available"
#define MLXDonorKeyPhysMem   "phys_footprint"

#define MLXDonorOpCreate     "create"
#define MLXDonorOpRelease    "release"
#define MLXDonorOpAvailable  "available"
#define MLXDonorOpPhysMem    "phys_footprint"

NS_ASSUME_NONNULL_BEGIN

@interface NSXPCListenerEndpoint (MLXPrivate)
@property (nonatomic, setter=_setEndpoint:) xpc_object_t _endpoint;
@end

static inline NSXPCListenerEndpoint *MLXWrapEndpoint(xpc_endpoint_t endpoint)
{
    NSXPCListenerEndpoint *wrapper = [NSXPCListenerEndpoint new];
    wrapper._endpoint = endpoint;
    return wrapper;
}

static inline xpc_endpoint_t _Nullable MLXUnwrapEndpoint(NSXPCListenerEndpoint *_Nullable wrapper)
{
    if (!wrapper) return nil;
    xpc_object_t inner = wrapper._endpoint;
    if (!inner || xpc_get_type(inner) != XPC_TYPE_ENDPOINT) return nil;
    return (xpc_endpoint_t)inner;
}

NS_ASSUME_NONNULL_END
#endif
