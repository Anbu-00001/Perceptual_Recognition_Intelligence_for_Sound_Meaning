#import "GeneratedPluginRegistrant.h"

#include <stddef.h>
#include <stdint.h>

// C-ABI surface of the Rust `prism_dsp` library.
// Mirrors the `#[no_mangle] extern "C"` functions declared in rust/src/ffi/mod.rs and ios.rs.
#ifdef __cplusplus
extern "C" {
#endif

void prism_init_logger(void);
size_t prism_push_audio_interleaved(const short *samples_interleaved, size_t len);
void prism_push_imu(uint64_t ts_ns,
                    float ax, float ay, float az,
                    float gx, float gy, float gz);

#ifdef __cplusplus
}
#endif
