#include "SpikeRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#define SLOTS 64
#define MAX_BYTES 65536
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Ring requires lock-free counters");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Layout requires lock-free stores");
struct AtomicLayout {
    _Atomic unsigned int numberBuffers, channels[4], bytes[4];
};
struct Slot { uint32_t bytes; unsigned char data[2][MAX_BYTES]; };
struct SpikeRing {
    _Atomic unsigned long long writeIndex, readIndex;
    _Atomic unsigned long long sequence, callbacks, empty, pushed;
    _Atomic unsigned long long ringFull, tooFewBuffers, badSize, layoutMismatch;
    struct AtomicLayout first, latest;
    uint32_t buffers, channels, bytesPerFrame;
    struct Slot slots[SLOTS];
};
SpikeRing *spike_ring_create(uint32_t buffers, uint32_t channels, uint32_t bytesPerFrame) {
    if (!buffers || buffers > 2 || !channels || !bytesPerFrame) return NULL;
    SpikeRing *r = calloc(1, sizeof(*r));
    if (r) {
        atomic_init(&r->writeIndex, 0); atomic_init(&r->readIndex, 0);
        atomic_init(&r->sequence, 0); atomic_init(&r->callbacks, 0);
        atomic_init(&r->empty, 0); atomic_init(&r->pushed, 0);
        atomic_init(&r->ringFull, 0); atomic_init(&r->tooFewBuffers, 0);
        atomic_init(&r->badSize, 0); atomic_init(&r->layoutMismatch, 0);
        atomic_init(&r->first.numberBuffers, 0); atomic_init(&r->latest.numberBuffers, 0);
        for (unsigned i = 0; i < 4; ++i) {
            atomic_init(&r->first.channels[i], 0); atomic_init(&r->first.bytes[i], 0);
            atomic_init(&r->latest.channels[i], 0); atomic_init(&r->latest.bytes[i], 0);
        }
        r->buffers = buffers; r->channels = channels; r->bytesPerFrame = bytesPerFrame;
        // Touch every page before starting realtime IO.
        volatile unsigned char *pages = (volatile unsigned char *)r->slots;
        for (size_t i = 0; i < sizeof(r->slots); i += 4096) pages[i] = 0;
    }
    return r;
}
void spike_ring_destroy(SpikeRing *r) { free(r); }
static void record_layout(struct AtomicLayout *layout, const AudioBufferList *input) {
    atomic_store(&layout->numberBuffers, input->mNumberBuffers);
    for (unsigned i = 0; i < 4; ++i) {
        atomic_store(&layout->channels[i], i < input->mNumberBuffers ? input->mBuffers[i].mNumberChannels : 0);
        atomic_store(&layout->bytes[i], i < input->mNumberBuffers ? input->mBuffers[i].mDataByteSize : 0);
    }
}
void spike_ring_push(SpikeRing *r, const AudioBufferList *input) {
    // Single producer. Sequentially consistent atomic diagnostics and sequence
    // allow the non-realtime reader to retry a snapshot without blocking IO.
    atomic_fetch_add(&r->sequence, 1);
    if (atomic_fetch_add(&r->callbacks, 1) == 0) record_layout(&r->first, input);
    record_layout(&r->latest, input);
    if (input->mNumberBuffers < r->buffers) {
        atomic_fetch_add(&r->tooFewBuffers, 1); goto done;
    }
    // Aggregate sub-device inputs precede its sub-tap inputs.
    uint32_t offset = input->mNumberBuffers - r->buffers;
    bool allEmpty = true;
    for (uint32_t i = 0; i < r->buffers; ++i)
        if (input->mBuffers[offset + i].mDataByteSize != 0) allEmpty = false;
    if (allEmpty) { atomic_fetch_add(&r->empty, 1); goto done; }
    uint32_t bytes = input->mBuffers[offset].mDataByteSize;
    for (uint32_t i = 0; i < r->buffers; ++i) {
        uint32_t size = input->mBuffers[offset + i].mDataByteSize;
        if (size > MAX_BYTES || size % r->bytesPerFrame) {
            atomic_fetch_add(&r->badSize, 1); goto done;
        }
    }
    for (uint32_t i = 0; i < r->buffers; ++i) {
        const AudioBuffer *b = &input->mBuffers[offset + i];
        if (!bytes || !b->mData || b->mDataByteSize != bytes || b->mNumberChannels != r->channels) {
            atomic_fetch_add(&r->layoutMismatch, 1); goto done;
        }
    }
    unsigned long long w = atomic_load_explicit(&r->writeIndex, memory_order_relaxed);
    unsigned long long rd = atomic_load_explicit(&r->readIndex, memory_order_acquire);
    if (w - rd == SLOTS) { atomic_fetch_add(&r->ringFull, 1); goto done; }
    struct Slot *slot = &r->slots[w % SLOTS];
    slot->bytes = bytes;
    for (uint32_t i = 0; i < r->buffers; ++i)
        memcpy(slot->data[i], input->mBuffers[offset + i].mData, bytes);
    atomic_store_explicit(&r->writeIndex, w + 1, memory_order_release);
    atomic_fetch_add(&r->pushed, 1);
done:
    atomic_fetch_add(&r->sequence, 1);
}
static SpikeBufferLayout read_layout(const struct AtomicLayout *layout) {
    SpikeBufferLayout result = {0};
    result.numberBuffers = atomic_load(&layout->numberBuffers);
    for (unsigned i = 0; i < 4; ++i) {
        result.channels[i] = atomic_load(&layout->channels[i]);
        result.bytes[i] = atomic_load(&layout->bytes[i]);
    }
    return result;
}
SpikeRingStats spike_ring_stats(SpikeRing *r) {
    SpikeRingStats result;
    for (;;) {
        unsigned long long before = atomic_load(&r->sequence);
        if (before & 1) continue;
        result.callbacks = atomic_load(&r->callbacks);
        result.empty = atomic_load(&r->empty);
        result.pushed = atomic_load(&r->pushed);
        result.ringFull = atomic_load(&r->ringFull);
        result.tooFewBuffers = atomic_load(&r->tooFewBuffers);
        result.badSize = atomic_load(&r->badSize);
        result.layoutMismatch = atomic_load(&r->layoutMismatch);
        result.first = read_layout(&r->first);
        result.latest = read_layout(&r->latest);
        if (before == atomic_load(&r->sequence)) return result;
    }
}
uint32_t spike_ring_pop(SpikeRing *r, AudioBufferList *output) {
    unsigned long long rd = atomic_load_explicit(&r->readIndex, memory_order_relaxed);
    if (rd == atomic_load_explicit(&r->writeIndex, memory_order_acquire)) return 0;
    struct Slot *slot = &r->slots[rd % SLOTS];
    for (uint32_t i = 0; i < r->buffers; ++i) {
        memcpy(output->mBuffers[i].mData, slot->data[i], slot->bytes);
        output->mBuffers[i].mDataByteSize = slot->bytes;
    }
    uint32_t frames = slot->bytes / r->bytesPerFrame;
    atomic_store_explicit(&r->readIndex, rd + 1, memory_order_release);
    return frames;
}
uint64_t spike_ring_drops(SpikeRing *r) {
    SpikeRingStats s = spike_ring_stats(r);
    return s.ringFull + s.tooFewBuffers + s.badSize + s.layoutMismatch;
}
static volatile sig_atomic_t interrupted = 0;
static struct sigaction old_action;
static void handle_interrupt(int sig) { (void)sig; interrupted = 1; }
void spike_install_interrupt(void) {
    interrupted = 0;
    struct sigaction action = {0};
    action.sa_handler = handle_interrupt;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, &old_action);
}
bool spike_interrupted(void) { return interrupted != 0; }
void spike_restore_interrupt(void) { sigaction(SIGINT, &old_action, NULL); }
