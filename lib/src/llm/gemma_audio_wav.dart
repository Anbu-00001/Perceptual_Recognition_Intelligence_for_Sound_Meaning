import 'dart:typed_data';

/// Mono Int16 PCM → WAV container. Shared by [GemmaAudioReasoner] and
/// [CaptionGenerator]. Avoids pulling in the `wav` package for what amounts
/// to 60 bytes of header.
Uint8List pcmToWav(Int16List samples, {required int sampleRate}) {
  const channels = 1;
  const bitsPerSample = 16;
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final blockAlign = channels * bitsPerSample ~/ 8;
  final dataLen = samples.length * 2;
  final fileLen = 36 + dataLen;
  final b = BytesBuilder();

  void w32(int x) {
    b.add([x & 0xff, (x >> 8) & 0xff, (x >> 16) & 0xff, (x >> 24) & 0xff]);
  }

  void w16(int x) => b.add([x & 0xff, (x >> 8) & 0xff]);

  b.add('RIFF'.codeUnits);
  w32(fileLen);
  b.add('WAVE'.codeUnits);
  b.add('fmt '.codeUnits);
  w32(16);
  w16(1);
  w16(channels);
  w32(sampleRate);
  w32(byteRate);
  w16(blockAlign);
  w16(bitsPerSample);
  b.add('data'.codeUnits);
  w32(dataLen);
  final little = ByteData(dataLen);
  for (var i = 0; i < samples.length; i++) {
    little.setInt16(i * 2, samples[i], Endian.little);
  }
  b.add(little.buffer.asUint8List());
  return b.toBytes();
}
