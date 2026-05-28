package com.prism.prism

import com.prism.audio.AudioCapturePlugin
import com.prism.audio.RustBindings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // One-time native init.
        RustBindings.ensureLoaded()
        // Wire the MethodChannel for native audio + IMU control.
        AudioCapturePlugin.register(flutterEngine, this)
    }
}
