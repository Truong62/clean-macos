#import "MacKitAudioBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdatomic.h>

id MKAudioRead(id object, NSString *selector) {
    @try {
        SEL method = NSSelectorFromString(selector);
        if (![object respondsToSelector:method]) return nil;
        return ((id (*)(id, SEL))objc_msgSend)(object, method);
    } @catch (NSException *exception) {
        return nil;
    }
}

BOOL MKAudioSupports(id object, NSString *selector) {
    @try { return [object respondsToSelector:NSSelectorFromString(selector)]; }
    @catch (NSException *exception) { return NO; }
}

BOOL MKAudioSet(id object, NSString *selector, id value) {
    @try {
        SEL method = NSSelectorFromString(selector);
        if (![object respondsToSelector:method]) return NO;
        ((void (*)(id, SEL, id))objc_msgSend)(object, method, value);
        return YES;
    } @catch (NSException *exception) { return NO; }
}

id MKAudioContext(void) {
    Class type = NSClassFromString(@"AVOutputContext");
    SEL selector = NSSelectorFromString(@"sharedAudioPresentationOutputContext");
    if (!type || !class_getClassMethod(type, selector)) return nil;
    return MKAudioRead(type, NSStringFromSelector(selector));
}

struct MKAudioRing {
    _Atomic(size_t) read;
    _Atomic(size_t) write;
    float samples[65536 * 2];
};

MKAudioRing *MKAudioRingCreate(void) { return calloc(1, sizeof(MKAudioRing)); }
void MKAudioRingDestroy(MKAudioRing *ring) { free(ring); }

void MKAudioRingWrite(MKAudioRing *ring, float left, float right) {
    size_t write = atomic_load_explicit(&ring->write, memory_order_relaxed);
    size_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    if (write - read >= 65536) return;
    ring->samples[(write % 65536) * 2] = left;
    ring->samples[(write % 65536) * 2 + 1] = right;
    atomic_store_explicit(&ring->write, write + 1, memory_order_release);
}

size_t MKAudioRingRead(MKAudioRing *ring, float *samples, size_t frames) {
    size_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    size_t write = atomic_load_explicit(&ring->write, memory_order_acquire);
    size_t count = MIN(frames, write - read);
    for (size_t index = 0; index < count; index++) {
        samples[index * 2] = ring->samples[((read + index) % 65536) * 2];
        samples[index * 2 + 1] = ring->samples[((read + index) % 65536) * 2 + 1];
    }
    atomic_store_explicit(&ring->read, read + count, memory_order_release);
    return count;
}

size_t MKAudioRingCount(MKAudioRing *ring) {
    size_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    size_t write = atomic_load_explicit(&ring->write, memory_order_acquire);
    return write - read;
}
