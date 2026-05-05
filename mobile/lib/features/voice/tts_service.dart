import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

enum VoicePriority { critical, tactical, info }

class VoiceMessage {
  final String text;
  final VoicePriority priority;
  VoiceMessage(this.text, this.priority);
}

/// Очередь TTS-сообщений. Critical прерывает текущее, tactical/info ждут очереди.
class TtsService {
  final FlutterTts _tts = FlutterTts();
  final Queue<VoiceMessage> _queue = Queue();
  bool _speaking = false;
  bool _ready = false;

  Future<void> init({String locale = 'ru-RU'}) async {
    await _tts.setLanguage(locale);
    await _tts.setSpeechRate(0.55);
    await _tts.setVolume(1.0);
    _tts.setCompletionHandler(() {
      _speaking = false;
      _drain();
    });
    _ready = true;
  }

  void enqueue(VoiceMessage msg) {
    if (!_ready) return;
    if (msg.priority == VoicePriority.critical) {
      _queue.clear();
      _tts.stop();
      _speaking = false;
    }
    _queue.addLast(msg);
    _drain();
  }

  void _drain() {
    if (_speaking || _queue.isEmpty) return;
    final next = _queue.removeFirst();
    _speaking = true;
    _tts.speak(next.text);
  }

  Future<void> dispose() async {
    await _tts.stop();
    _queue.clear();
  }

  /// Утилита: «Новая метка: противник, 100 метров, северо-запад».
  static String formatMarker({
    required String kind,
    required double distanceM,
    required String azimuth,
  }) {
    final dist = distanceM < 100
        ? '${distanceM.round()} метров'
        : '${(distanceM / 10).round() * 10} метров';
    return 'Новая метка: $kind, $dist, $azimuth';
  }
}

final ttsServiceProvider = Provider<TtsService>((ref) {
  final svc = TtsService();
  ref.onDispose(svc.dispose);
  return svc;
});
