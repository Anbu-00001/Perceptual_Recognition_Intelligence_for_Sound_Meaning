// HAND-WRITTEN STUB — replaced by `./scripts/codegen.sh`.

class SessionPaths {
  SessionPaths({required this.wavPath, required this.imuPath});

  final String wavPath;
  final String imuPath;
}

Future<SessionPaths> startSession({
  required String documentsDir,
  required String tsLabel,
}) async {
  // Stub returns a placeholder. Real impl lives in Rust after codegen runs.
  return SessionPaths(
    wavPath: '$documentsDir/sessions/session_$tsLabel.wav',
    imuPath: '$documentsDir/sessions/imu_$tsLabel.csv',
  );
}

Future<SessionPaths> stopSession() async {
  return SessionPaths(wavPath: '', imuPath: '');
}
