import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/supabase_config.dart';

enum WsConnectionState { idle, connecting, connected, reconnecting, closed }

/// WebSocket-клиент. Подключается с JWT, шлёт позиции (троттлинг 3с),
/// принимает позиции союзников и события (метки, kill, respawn).
///
/// Reconnect — exp-backoff с jitter, бесконечно (пока не вызван disconnect()):
/// 1→2→4→8→16→30 секунд. Heartbeat ping раз в 25с; если нет ни одного
/// входящего сообщения 60с — рвём и переподключаемся (роутер мог тихо умереть).
class WsService {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  String? _gameId;
  bool _intentionalDisconnect = false;
  int _backoffStep = 0;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _watchdogTimer;
  DateTime _lastIncoming = DateTime.now();

  Timer? _throttle;
  Map<String, dynamic>? _pendingPosition;

  final _incoming = StreamController<Map<String, dynamic>>.broadcast();
  final _state = StreamController<WsConnectionState>.broadcast();
  WsConnectionState _currentState = WsConnectionState.idle;

  Stream<Map<String, dynamic>> get incoming => _incoming.stream;
  Stream<WsConnectionState> get state => _state.stream;
  WsConnectionState get currentState => _currentState;

  /// Подключиться к игре. Идемпотентно: повторный вызов с тем же gameId
  /// сбрасывает backoff и переподключается.
  Future<void> connect(String gameId) async {
    _gameId = gameId;
    _intentionalDisconnect = false;
    _backoffStep = 0;
    await _open();
  }

  Future<void> _open() async {
    if (_gameId == null || _intentionalDisconnect) return;

    _setState(WsConnectionState.connecting);
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) {
      _setState(WsConnectionState.closed);
      throw StateError('No JWT for WS connect');
    }

    final uri = Uri.parse(
      '${SupabaseConfig.wsBaseUrl}/api/v1/ws?game=$_gameId&token=$token',
    );

    try {
      _channel = WebSocketChannel.connect(uri);
      _lastIncoming = DateTime.now();
      _sub = _channel!.stream.listen(
        _onMessage,
        onDone: _onClosed,
        onError: (_) => _onClosed(),
        cancelOnError: true,
      );
      _setState(WsConnectionState.connected);
      _startHeartbeat();
      _startWatchdog();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic data) {
    _lastIncoming = DateTime.now();
    try {
      final decoded = jsonDecode(data as String);
      if (decoded is Map<String, dynamic>) {
        // Сервер может прислать ping/pong (пока не использует, но
        // защищаемся на будущее).
        if (decoded['type'] == 'pong') return;
        _incoming.add(decoded);
      }
    } catch (_) {/* битый JSON — игнор */}
  }

  void _onClosed() {
    _stopHeartbeat();
    _stopWatchdog();
    _sub?.cancel();
    _sub = null;
    _channel = null;
    if (_intentionalDisconnect) {
      _setState(WsConnectionState.closed);
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_intentionalDisconnect) return;
    _reconnectTimer?.cancel();
    _setState(WsConnectionState.reconnecting);

    // backoff: 1, 2, 4, 8, 16, 30, 30, ... + jitter ±25%
    const baseSeq = [1, 2, 4, 8, 16, 30];
    final base = baseSeq[_backoffStep.clamp(0, baseSeq.length - 1)];
    final jitter = (base * 0.25 * (Random().nextDouble() * 2 - 1)).round();
    final delay = Duration(seconds: (base + jitter).clamp(1, 60));
    _backoffStep++;

    _reconnectTimer = Timer(delay, _open);
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_channel == null) return;
      try {
        _channel!.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {
        _onClosed();
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (DateTime.now().difference(_lastIncoming).inSeconds > 60) {
        // Мёртвый канал — TCP не успел заметить (NAT timeout / sleep).
        try {
          _channel?.sink.close();
        } catch (_) {}
        _onClosed();
      }
    });
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _setState(WsConnectionState s) {
    if (_currentState == s) return;
    _currentState = s;
    _state.add(s);
  }

  /// Троттлинг позиций (3с). Последняя записанная — полетит на следующем тике.
  void sendPosition({required double lng, required double lat, double? heading}) {
    _pendingPosition = {
      'type': 'position',
      'payload': {
        'lng': lng,
        'lat': lat,
        if (heading != null) 'heading': heading,
      },
    };
    _throttle ??= Timer.periodic(const Duration(seconds: 3), (_) {
      final pending = _pendingPosition;
      if (pending != null && _channel != null) {
        try {
          _channel!.sink.add(jsonEncode(pending));
          _pendingPosition = null;
        } catch (_) {/* следующий тик повторит */}
      }
    });
  }

  void send(Map<String, dynamic> packet) {
    try {
      _channel?.sink.add(jsonEncode(packet));
    } catch (_) {/* потеряли — клиент пересоздаст из локального состояния */}
  }

  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _stopHeartbeat();
    _stopWatchdog();
    _throttle?.cancel();
    _throttle = null;
    _pendingPosition = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _setState(WsConnectionState.closed);
  }
}

final wsServiceProvider = Provider<WsService>((ref) {
  final svc = WsService();
  ref.onDispose(svc.disconnect);
  return svc;
});
