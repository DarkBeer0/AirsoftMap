import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/supabase_config.dart';

/// WebSocket-клиент. Подключается с JWT, шлёт позиции (троттлинг 3с),
/// принимает позиции союзников и события (метки, kill, respawn).
class WsService {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final _incoming = StreamController<Map<String, dynamic>>.broadcast();
  Timer? _throttle;
  Map<String, dynamic>? _pendingPosition;

  Stream<Map<String, dynamic>> get incoming => _incoming.stream;

  Future<void> connect(String gameId) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) throw StateError('No JWT for WS connect');

    final uri = Uri.parse(
      '${SupabaseConfig.wsBaseUrl}/api/v1/ws?game=$gameId&token=$token',
    );
    _channel = WebSocketChannel.connect(uri);
    _sub = _channel!.stream.listen(
      (data) {
        try {
          _incoming.add(jsonDecode(data as String) as Map<String, dynamic>);
        } catch (_) {}
      },
      onDone: () {/* TODO: reconnect with backoff */},
      onError: (_) {/* TODO: reconnect with backoff */},
    );
  }

  /// Троттлинг позиций (3с). Последняя записанная — полетит на следующем тике.
  void sendPosition({required double lng, required double lat, double? heading}) {
    _pendingPosition = {
      'type': 'position',
      'lng': lng,
      'lat': lat,
      if (heading != null) 'heading': heading,
      'ts': DateTime.now().toUtc().toIso8601String(),
    };
    _throttle ??= Timer.periodic(const Duration(seconds: 3), (_) {
      if (_pendingPosition != null && _channel != null) {
        _channel!.sink.add(jsonEncode(_pendingPosition));
        _pendingPosition = null;
      }
    });
  }

  void send(Map<String, dynamic> packet) {
    _channel?.sink.add(jsonEncode(packet));
  }

  Future<void> disconnect() async {
    _throttle?.cancel();
    _throttle = null;
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }
}

final wsServiceProvider = Provider<WsService>((ref) {
  final svc = WsService();
  ref.onDispose(svc.disconnect);
  return svc;
});
