#ifndef SPIKE_RING_H
#define SPIKE_RING_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>
typedef struct SpikeRing SpikeRing;
typedef struct {
    uint32_t numberBuffers;
    uint32_t channels[4];
    uint32_t bytes[4];
} SpikeBufferLayout;
typedef struct {
    uint64_t callbacks, empty, pushed;
    uint64_t ringFull, tooFewBuffers, badSize, layoutMismatch;
    SpikeBufferLayout first, latest;
} SpikeRingStats;
// Coherent snapshot; call from the consumer, never the realtime callback.
SpikeRingStats spike_ring_stats(SpikeRing *ring);
SpikeRing *spike_ring_create(uint32_t buffers, uint32_t channelsPerBuffer, uint32_t bytesPerFrame);
void spike_ring_destroy(SpikeRing *ring);
void spike_ring_push(SpikeRing *ring, const AudioBufferList *input);
// Copies one slot into the caller's preallocated buffers; zero means empty.
uint32_t spike_ring_pop(SpikeRing *ring, AudioBufferList *output);
uint64_t spike_ring_drops(SpikeRing *ring);
void spike_install_interrupt(void);
bool spike_interrupted(void);
void spike_restore_interrupt(void);
#endif
