#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
id _Nullable MKAudioContext(void);
id _Nullable MKAudioRead(id object, NSString *selector);
BOOL MKAudioSet(id object, NSString *selector, id value);
BOOL MKAudioSupports(id object, NSString *selector);

typedef struct MKAudioRing MKAudioRing;
MKAudioRing * _Nullable MKAudioRingCreate(void);
void MKAudioRingDestroy(MKAudioRing *ring);
void MKAudioRingWrite(MKAudioRing *ring, float left, float right);
size_t MKAudioRingRead(MKAudioRing *ring, float *samples, size_t frames);
size_t MKAudioRingCount(MKAudioRing *ring);
NS_ASSUME_NONNULL_END
