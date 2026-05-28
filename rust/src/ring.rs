//! Lock-free stereo ring buffer for raw PCM audio frames.
//!
//! Sized for 4 seconds of stereo 48 kHz 16-bit = 4 × 48000 × 2 = 384k samples = 768 KB.
//! Pushed from the native audio thread (Android `AudioRecord` callback / iOS `AVAudioEngine` tap).
//! Drained by the DSP / streaming thread.

use parking_lot::Mutex;
use ringbuf::traits::{Consumer as ConsumerT, Observer as ObserverT, Producer as ProducerT, Split};
use ringbuf::HeapRb;
use std::sync::OnceLock;

pub const SAMPLE_RATE: u32 = 48_000;
pub const CHANNELS: usize = 2;
pub const RING_SECONDS: usize = 4;
pub const RING_CAPACITY: usize = SAMPLE_RATE as usize * CHANNELS * RING_SECONDS;

type RingProducer = ringbuf::wrap::caching::Caching<std::sync::Arc<ringbuf::SharedRb<ringbuf::storage::Heap<i16>>>, true, false>;
type RingConsumer = ringbuf::wrap::caching::Caching<std::sync::Arc<ringbuf::SharedRb<ringbuf::storage::Heap<i16>>>, false, true>;

pub struct AudioRing {
    pub producer: Mutex<RingProducer>,
    pub consumer: Mutex<RingConsumer>,
}

static RING: OnceLock<AudioRing> = OnceLock::new();

pub fn ring() -> &'static AudioRing {
    RING.get_or_init(|| {
        let rb = HeapRb::<i16>::new(RING_CAPACITY);
        let (producer, consumer) = rb.split();
        AudioRing {
            producer: Mutex::new(producer),
            consumer: Mutex::new(consumer),
        }
    })
}

/// Push interleaved stereo samples (L, R, L, R, ...). Called from native audio callback.
/// Drops oldest samples if the consumer is behind (slow path, should not happen normally).
pub fn push_interleaved(samples: &[i16]) -> usize {
    let r = ring();
    let mut prod = r.producer.lock();
    let pushed = prod.push_slice(samples);
    if pushed < samples.len() {
        // Consumer is behind; drop oldest by consuming + re-pushing remainder.
        let mut cons = r.consumer.lock();
        let drop_n = samples.len() - pushed;
        let mut sink = vec![0i16; drop_n];
        let _ = cons.pop_slice(&mut sink);
        drop(cons);
        prod.push_slice(&samples[pushed..]);
    }
    samples.len()
}

/// Drain up to `n` interleaved samples into `out`. Returns actual count.
pub fn pop_interleaved(out: &mut [i16]) -> usize {
    let r = ring();
    let mut cons = r.consumer.lock();
    cons.pop_slice(out)
}

/// Available samples (interleaved count).
pub fn available() -> usize {
    let r = ring();
    let cons = r.consumer.lock();
    cons.occupied_len()
}
