#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <os/proc.h>
#import <xpc/xpc.h>

#import "../MeloNX/Core/Memory/MLXRamDonorProtocol.h"

@interface DonorHandler : NSObject
@end

@implementation DonorHandler {
    NSMutableArray<NSValue *> *_regions;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _regions = [NSMutableArray array];
    }
    return self;
}

- (void)handleConnection:(xpc_connection_t)connection {
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) {
            return;
        }

        const char *operation = xpc_dictionary_get_string(event, MLXRamDonorXPCOperationKey);
        if (operation == NULL) {
            return;
        }

        if (strcmp(operation, MLXRamDonorXPCOperationCreate) == 0) {
            uint64_t requested = xpc_dictionary_get_uint64(event, MLXRamDonorXPCRequestedBytesKey);
            uint64_t granted = requested - (requested % MLXRamDonorChunkSize);
            if (granted == 0) {
                granted = MLXRamDonorChunkSize;
            }

            vm_address_t address = 0;
            kern_return_t kr = mach_vm_allocate(mach_task_self(), &address, granted, VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE);
            xpc_object_t reply = xpc_dictionary_create_reply(event);
            if (reply == NULL) {
                if (kr == KERN_SUCCESS) {
                    mach_vm_deallocate(mach_task_self(), address, granted);
                }
                return;
            }

            if (kr == KERN_SUCCESS) {
                [_regions addObject:[NSValue valueWithPointer:(void *)address]];
                xpc_dictionary_set_uint64(reply, MLXRamDonorGrantedBytesKey, granted);
                xpc_dictionary_set_value(reply, MLXRamDonorShmemKey, xpc_shmem_create(NULL, (void *)address, granted));
            } else {
                xpc_dictionary_set_uint64(reply, MLXRamDonorGrantedBytesKey, 0);
                xpc_dictionary_set_string(reply, MLXRamDonorErrorKey, mach_error_string(kr));
            }
            xpc_connection_send_message(connection, reply);
            return;
        }

        if (strcmp(operation, MLXRamDonorXPCOperationRelease) == 0) {
            xpc_object_t shmem = xpc_dictionary_get_value(event, MLXRamDonorShmemKey);
            void *address = NULL;
            size_t size = 0;
            if (shmem != NULL && xpc_get_type(shmem) == XPC_TYPE_SHMEM) {
                xpc_shmem_map(shmem, &address, &size);
                if (address != NULL && size != 0) {
                    mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)address, size);
                }
            }
            return;
        }
    });
    xpc_connection_resume(connection);
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        DonorHandler *handler = [DonorHandler new];
        xpc_main(^(xpc_connection_t connection) {
            [handler handleConnection:connection];
        });
    }
    return 0;
}
