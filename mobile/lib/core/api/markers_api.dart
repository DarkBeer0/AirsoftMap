import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';

/// Категории меток. Канонический список — на сервере (поле kind свободное,
/// но клиент рисует только известные); расширяй здесь и в _kindIcon карты.
enum MarkerKind { enemy, ally, danger, objective, support, note }

extension MarkerKindExt on MarkerKind {
  String get wire => switch (this) {
        MarkerKind.enemy => 'enemy',
        MarkerKind.ally => 'ally',
        MarkerKind.danger => 'danger',
        MarkerKind.objective => 'objective',
        MarkerKind.support => 'support',
        MarkerKind.note => 'note',
      };
}

enum MarkerVisibility { self, squad, side, organizers, all }

extension MarkerVisibilityExt on MarkerVisibility {
  String get wire => switch (this) {
        MarkerVisibility.self => 'self',
        MarkerVisibility.squad => 'squad',
        MarkerVisibility.side => 'side',
        MarkerVisibility.organizers => 'organizers',
        MarkerVisibility.all => 'all',
      };
}

class MarkerInfo {
  final String id;
  final String gameId;
  final String authorId;
  final String kind;
  final String visibility;
  final String? sideId;
  final String? squadId;
  final double lng;
  final double lat;
  final String? label;
  final DateTime createdAt;
  final DateTime? expiresAt;

  const MarkerInfo({
    required this.id,
    required this.gameId,
    required this.authorId,
    required this.kind,
    required this.visibility,
    required this.lng,
    required this.lat,
    required this.createdAt,
    this.sideId,
    this.squadId,
    this.label,
    this.expiresAt,
  });

  factory MarkerInfo.fromJson(Map<String, dynamic> j) => MarkerInfo(
        id: j['id'] as String,
        gameId: j['game_id'] as String,
        authorId: j['author_id'] as String,
        kind: j['kind'] as String,
        visibility: j['visibility'] as String,
        sideId: j['side_id'] as String?,
        squadId: j['squad_id'] as String?,
        lng: (j['lng'] as num).toDouble(),
        lat: (j['lat'] as num).toDouble(),
        label: j['label'] as String?,
        createdAt: DateTime.parse(j['created_at'] as String),
        expiresAt: j['expires_at'] != null
            ? DateTime.parse(j['expires_at'] as String)
            : null,
      );
}

class MarkersApi {
  final Dio _dio;
  MarkersApi(this._dio);

  Future<MarkerInfo> create(
    String gameId, {
    required MarkerKind kind,
    required MarkerVisibility visibility,
    required double lng,
    required double lat,
    String? label,
    Duration? ttl,
  }) async {
    final res = await _dio.post('/games/$gameId/markers', data: {
      'kind': kind.wire,
      'visibility': visibility.wire,
      'lng': lng,
      'lat': lat,
      if (label != null && label.isNotEmpty) 'label': label,
      if (ttl != null)
        'expires_at': DateTime.now().toUtc().add(ttl).toIso8601String(),
    });
    return MarkerInfo.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<MarkerInfo>> list(String gameId) async {
    final res = await _dio.get('/games/$gameId/markers');
    final raw = (res.data['markers'] as List).cast<Map<String, dynamic>>();
    return raw.map(MarkerInfo.fromJson).toList(growable: false);
  }
}

final markersApiProvider = Provider<MarkersApi>((ref) {
  return MarkersApi(ref.read(apiClientProvider).dio);
});
