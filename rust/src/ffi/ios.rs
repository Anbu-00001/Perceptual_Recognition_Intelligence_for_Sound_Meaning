//! iOS-side entry points exposed via C-ABI. Swift consumes these via a bridging header
//! that declares the function signatures (see `ios/Runner/Runner-Bridging-Header.h`).

#![cfg(target_os = "ios")]

/// One-time init for iOS logging.
#[no_mangle]
pub extern "C" fn prism_init_logger() {
    let _ = oslog::OsLogger::new("com.prism.prism")
        .level_filter(log::LevelFilter::Info)
        .init();
    log::info!("PRISM DSP native library initialized (iOS)");
}
