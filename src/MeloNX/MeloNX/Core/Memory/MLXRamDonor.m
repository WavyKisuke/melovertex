#import "MLXRamDonor.h"
#import "MLXRamDonorProtocol.h"
#import <mach/mach.h>

@interface NSExtension : NSObject
@property (nonatomic, strong, readwrite) NSArray *preferredLanguages;
+ (instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *))callback;
- (int)pidForRequestIdentifier:(NSUUID *)identifier;
- (void)_kill:(int)signal;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *uuid, NSError *error))callback;
@end

extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address, mach_vm_size_t size);
extern kern_return_t mach_vm_remap(vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size, mach_vm_offset_t mask, int flags, vm_map_t source, mach_vm_address_t sourceAddress, boolean_t copy, vm_prot_t *currentProtection, vm_prot_t *maxProtection, vm_inherit_t inheritance);

#ifndef VM_FLAGS_OVERWRITE
#define VM_FLAGS_OVERWRITE 0x4000
#endif

static const uint64_t MLXDonorHeadroom = 256ull * 1024ull * 1024ull;

@interface MLXDonorSlot : NSObject
@property (nonatomic) xpc_connection_t connection;
@property (nonatomic) uint64_t remaining;
@end
@implementation MLXDonorSlot
@end

@interface MLXDonatedRegion : NSObject
@property (nonatomic) mach_vm_address_t base;
@property (nonatomic) uint64_t size;
@property (nonatomic) NSMutableArray *shmems;
@end
@implementation MLXDonatedRegion
@end

@interface MLXRamDonor ()
@property (nonatomic) xpc_connection_t listener;
@property (nonatomic) NSMutableArray<NSExtension *> *extensions;
@property (nonatomic) NSMutableArray *connections;
@property (nonatomic) NSMutableDictionary<NSNumber *, MLXDonatedRegion *> *regions;
@property (nonatomic) dispatch_semaphore_t connected;
@property (nonatomic) NSUInteger nextDonor;
@property (nonatomic, copy) NSString *lastError;
@end

@implementation MLXRamDonor
static MLXRamDonor *sharedDonor;

+ (MLXRamDonor *)shared { static dispatch_once_t once; dispatch_once(&once, ^{ sharedDonor = [MLXRamDonor new]; }); return sharedDonor; }
+ (MLXRamDonor *)sharedIfExists { return sharedDonor; }

- (instancetype)init {
    self = [super init];
    _extensions = [NSMutableArray array];
    _connections = [NSMutableArray array];
    _regions = [NSMutableDictionary dictionary];
    _connected = dispatch_semaphore_create(0);
    _maxDonors = 4;
    _killDonorsAfterMapping = YES;
    _listener = xpc_connection_create(NULL, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    __weak typeof(self) weakSelf = self;
    xpc_connection_set_event_handler(_listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_CONNECTION) [weakSelf acceptConnection:(xpc_connection_t)event];
    });
    xpc_connection_resume(_listener);
    return self;
}

- (NSUInteger)liveDonorCount { @synchronized (self) { return self.connections.count; } }

+ (NSString *)donorBundleIdentifier {
    static NSString *identifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *plugIns = NSBundle.mainBundle.builtInPlugInsURL;
        NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:plugIns includingPropertiesForKeys:nil options:0 error:nil];
        for (NSURL *url in contents) {
            if (![url.pathExtension isEqualToString:@"appex"]) continue;
            NSBundle *bundle = [NSBundle bundleWithURL:url];
            NSString *principal = bundle.infoDictionary[@"NSExtension"][@"NSExtensionPrincipalClass"];
            if ([principal isEqualToString:@"MLXRamDonorHandler"]) identifier = bundle.bundleIdentifier;
        }
    });
    return identifier;
}

- (BOOL)startOneDonorWithTimeout:(NSTimeInterval)timeout {
    NSString *identifier = MLXRamDonor.donorBundleIdentifier;
    if (!identifier) { self.lastError = @"The memory helper is missing from this build"; return NO; }
    NSError *error = nil;
    NSExtension *extension = [NSExtension extensionWithIdentifier:identifier error:&error];
    if (!extension) { self.lastError = [NSString stringWithFormat:@"Could not load %@: %@", identifier, error.localizedDescription]; return NO; }
    extension.preferredLanguages = @[];
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{ @"endpoint": MLXWrapEndpoint(xpc_endpoint_create(self.listener)) };
    const NSUInteger before = self.liveDonorCount;
    __block BOOL started = NO;
    dispatch_semaphore_t spawned = dispatch_semaphore_create(0);
    [extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *uuid) { started = uuid != nil; dispatch_semaphore_signal(spawned); }];
    dispatch_semaphore_wait(spawned, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (!started) { self.lastError = @"The extension request was rejected"; return NO; }
    const NSTimeInterval deadline = NSDate.timeIntervalSinceReferenceDate + timeout;
    while (self.liveDonorCount <= before) {
        const NSTimeInterval remaining = deadline - NSDate.timeIntervalSinceReferenceDate;
        if (remaining <= 0) { self.lastError = @"The donor process spawned, but did not connect before timeout"; return NO; }
        dispatch_semaphore_wait(self.connected, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
    }
    @synchronized (self) { [self.extensions addObject:extension]; }
    return YES;
}

- (NSUInteger)startDonors:(NSUInteger)count timeout:(NSTimeInterval)timeout {
    for (NSUInteger i = self.liveDonorCount; i < count; i++) if (![self startOneDonorWithTimeout:timeout]) break;
    return self.liveDonorCount;
}

- (void)acceptConnection:(xpc_connection_t)connection {
    __weak typeof(self) weakSelf = self;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) { if (xpc_get_type(event) == XPC_TYPE_ERROR) [weakSelf forgetConnection:connection]; });
    xpc_connection_resume(connection);
    @synchronized (self) { [self.connections addObject:connection]; }
    dispatch_semaphore_signal(self.connected);
}
- (void)forgetConnection:(xpc_connection_t)connection { @synchronized (self) { [self.connections removeObjectIdenticalTo:connection]; } }

- (xpc_object_t)send:(const char *)op to:(xpc_connection_t)donor size:(uint64_t)size timeout:(NSTimeInterval)timeout {
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, MLXDonorKeyOp, op);
    if (size) xpc_dictionary_set_uint64(request, MLXDonorKeySize, size);
    __block xpc_object_t answer = nil;
    dispatch_semaphore_t replied = dispatch_semaphore_create(0);
    xpc_connection_send_message_with_reply(donor, request, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(xpc_object_t reply) { if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY) answer = reply; dispatch_semaphore_signal(replied); });
    if (dispatch_semaphore_wait(replied, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) return nil;
    return answer;
}

- (uint64_t)availableMemoryForConnection:(xpc_connection_t)connection { xpc_object_t reply = [self send:MLXDonorOpAvailable to:connection size:0 timeout:2.0]; return reply ? xpc_dictionary_get_uint64(reply, MLXDonorKeyAvailable) : 0; }

- (BOOL)addSlotForNextDonorTo:(NSMutableArray<MLXDonorSlot *> *)slots {
    const NSUInteger before = self.liveDonorCount;
    if (slots.count >= before && ![self startOneDonorWithTimeout:10.0]) return NO;
    xpc_connection_t connection = nil;
    @synchronized (self) {
        NSMutableArray *spare = [self.connections mutableCopy];
        for (MLXDonorSlot *slot in slots) [spare removeObjectIdenticalTo:slot.connection];
        connection = spare.firstObject;
    }
    if (!connection) return NO;
    uint64_t budget = [self availableMemoryForConnection:connection];
    MLXDonorSlot *slot = [MLXDonorSlot new]; slot.connection = connection; slot.remaining = budget > MLXDonorHeadroom ? budget - MLXDonorHeadroom : 0;
    [slots addObject:slot];
    return slot.remaining > 0;
}

- (MLXDonorSlot *)slotWithRoomFor:(uint64_t)length in:(NSMutableArray<MLXDonorSlot *> *)slots {
    for (NSUInteger i = 0; i < slots.count; i++) { MLXDonorSlot *slot = slots[self.nextDonor++ % slots.count]; if (slot.remaining >= length) return slot; }
    if (slots.count >= self.maxDonors || ![self addSlotForNextDonorTo:slots]) return nil;
    MLXDonorSlot *added = slots.lastObject; return added.remaining >= length ? added : nil;
}

- (BOOL)mapChunkOfSize:(uint64_t)length from:(MLXDonorSlot *)slot into:(MLXDonatedRegion *)region at:(mach_vm_address_t)target {
    xpc_object_t reply = [self send:MLXDonorOpCreate to:slot.connection size:length timeout:30.0];
    if (!reply) return NO;
    const char *donorError = xpc_dictionary_get_string(reply, MLXDonorKeyError);
    if (donorError) { self.lastError = [NSString stringWithUTF8String:donorError]; return NO; }
    xpc_object_t shmem = xpc_dictionary_get_value(reply, MLXDonorKeyShmem);
    if (!shmem || xpc_get_type(shmem) != XPC_TYPE_SHMEM) return NO;
    void *scratch = NULL; size_t mapped = xpc_shmem_map(shmem, &scratch);
    if (mapped < length || !scratch) return NO;
    vm_prot_t current = VM_PROT_NONE, maximum = VM_PROT_NONE; mach_vm_address_t destination = target;
    kern_return_t kr = mach_vm_remap(mach_task_self(), &destination, length, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (mach_vm_address_t)scratch, false, &current, &maximum, VM_INHERIT_SHARE);
    mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)scratch, mapped);
    if (kr != KERN_SUCCESS) { self.lastError = [NSString stringWithFormat:@"Could not remap donated chunk: %s", mach_error_string(kr)]; return NO; }
    [region.shmems addObject:shmem]; return YES;
}

- (void *)acquireUpTo:(uint64_t)size minimum:(uint64_t)minimum actual:(uint64_t *)actual {
    if (actual) *actual = 0; if (!size) return NULL;
    uint64_t mask = (uint64_t)vm_page_size - 1; size = (size + mask) & ~mask; minimum = MIN((minimum + mask) & ~mask, size);
    NSMutableArray *slots = [NSMutableArray array]; if (![self addSlotForNextDonorTo:slots]) return NULL;
    mach_vm_address_t base = 0; if (mach_vm_allocate(mach_task_self(), &base, size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return NULL;
    MLXDonatedRegion *region = [MLXDonatedRegion new]; region.base = base; region.size = size; region.shmems = [NSMutableArray array];
    uint64_t offset = 0;
    while (offset < size) { uint64_t length = MIN(MLX_DONOR_CHUNK_SIZE, size - offset); MLXDonorSlot *slot = [self slotWithRoomFor:length in:slots]; if (!slot || ![self mapChunkOfSize:length from:slot into:region at:base + offset]) break; slot.remaining -= length; offset += length; }
    if (offset == 0 || offset < minimum) { [self tearDownRegion:region]; return NULL; }
    if (offset < size) { mach_vm_deallocate(mach_task_self(), base + offset, size - offset); region.size = offset; }
    @synchronized (self) { self.regions[@(base)] = region; }
    if (actual) *actual = offset;
    if (self.killDonorsAfterMapping) [self killDonorProcesses];
    return (void *)base;
}

- (void *)acquireBytes:(uint64_t)size { return [self acquireUpTo:size minimum:size actual:NULL]; }
- (void)tearDownRegion:(MLXDonatedRegion *)region { [region.shmems removeAllObjects]; if (region.base) mach_vm_deallocate(mach_task_self(), region.base, region.size); }
- (void)releaseRegionAt:(void *)base { MLXDonatedRegion *region; @synchronized (self) { region = self.regions[@((mach_vm_address_t)base)]; [self.regions removeObjectForKey:@((mach_vm_address_t)base)]; } if (region) [self tearDownRegion:region]; }
- (uint64_t)donatedBytes { return 0; }
- (uint64_t)donorAvailableMemory { @synchronized (self) { xpc_connection_t donor = self.connections.firstObject; return donor ? [self availableMemoryForConnection:donor] : 0; } }
- (void)killDonorProcesses { NSArray *extensions; @synchronized (self) { extensions = [self.extensions copy]; [self.extensions removeAllObjects]; } for (NSExtension *extension in extensions) [extension _kill:SIGKILL]; }
- (void)shutdown { NSArray *extensions; NSArray *regions; @synchronized (self) { extensions = [self.extensions copy]; regions = self.regions.allValues; [self.extensions removeAllObjects]; [self.connections removeAllObjects]; [self.regions removeAllObjects]; } for (MLXDonatedRegion *region in regions) [self tearDownRegion:region]; for (NSExtension *extension in extensions) [extension _kill:SIGTERM]; }
@end

uint32_t mlx_ram_donor_start(uint32_t count, double timeoutSeconds) { return (uint32_t)[MLXRamDonor.shared startDonors:count timeout:timeoutSeconds]; }
void *mlx_ram_donor_acquire(uint64_t size) { return [MLXRamDonor.shared acquireBytes:size]; }
void *mlx_ram_donor_acquire_up_to(uint64_t size, uint64_t minimum, uint64_t *actual) { return [MLXRamDonor.shared acquireUpTo:size minimum:minimum actual:actual]; }
void mlx_ram_donor_release(void *base) { [MLXRamDonor.shared releaseRegionAt:base]; }
uint32_t mlx_ram_donor_live_count(void) { return (uint32_t)[MLXRamDonor.sharedIfExists liveDonorCount]; }
uint64_t mlx_ram_donor_available_memory(void) { return [MLXRamDonor.sharedIfExists donorAvailableMemory]; }
bool mlx_ram_donor_is_available(void) { return MLXRamDonor.donorBundleIdentifier != nil; }
const char *mlx_ram_donor_last_error(void) { return MLXRamDonor.sharedIfExists.lastError.UTF8String; }
void mlx_ram_donor_shutdown(void) { [MLXRamDonor.sharedIfExists shutdown]; }
void mlx_ram_donor_set_kill_after_mapping(bool enabled) { MLXRamDonor.shared.killDonorsAfterMapping = enabled; }
void mlx_ram_donor_kill_processes(void) { [MLXRamDonor.sharedIfExists killDonorProcesses]; }
