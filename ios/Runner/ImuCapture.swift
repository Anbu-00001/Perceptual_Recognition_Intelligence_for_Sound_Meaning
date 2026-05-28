import CoreMotion
import Foundation

/// 100 Hz device motion capture on iOS (iOS hardware caps deviceMotion at ~100 Hz on
/// most devices; some recent iPhones support 200 Hz via accelerometer/gyro raw streams).
final class ImuCapture {

    static let shared = ImuCapture()
    private init() {}

    private let manager = CMMotionManager()
    private let queue = OperationQueue()

    func start() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated

        manager.deviceMotionUpdateInterval = 1.0 / 200.0 // ask for 200 Hz; iOS may clamp
        if manager.isDeviceMotionAvailable {
            manager.startDeviceMotionUpdates(to: queue) { motion, _ in
                guard let m = motion else { return }
                let ts = UInt64(m.timestamp * 1_000_000_000)
                let acc = m.userAcceleration
                let rot = m.rotationRate
                prism_push_imu(
                    ts,
                    Float(acc.x), Float(acc.y), Float(acc.z),
                    Float(rot.x), Float(rot.y), Float(rot.z)
                )
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
