import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';

/// Результат POST /games/join.
class JoinResult {
  final String gameId;
  final String gameName;
  final String sideId;
  final String sideName;
  final String sideColor;
  final String callsign;
  final String role;
  final int respawnSeconds;
  final String? mapPackUrl;

  const JoinResult({
    required this.gameId,
    required this.gameName,
    required this.sideId,
    required this.sideName,
    required this.sideColor,
    required this.callsign,
    required this.role,
    this.respawnSeconds = 60,
    this.mapPackUrl,
  });

  factory JoinResult.fromJson(Map<String, dynamic> j) => JoinResult(
        gameId: j['game_id'] as String,
        gameName: j['game_name'] as String,
        sideId: j['side_id'] as String,
        sideName: j['side_name'] as String,
        sideColor: j['side_color'] as String,
        callsign: j['callsign'] as String,
        role: j['role'] as String,
        respawnSeconds: (j['respawn_seconds'] as num?)?.toInt() ?? 60,
        mapPackUrl: j['map_pack_url'] as String?,
      );
}

class SideInput {
  final String name;
  final String color;
  const SideInput({required this.name, required this.color});
  Map<String, dynamic> toJson() => {'name': name, 'color': color};
}

class CreatedSide {
  final String id;
  final String name;
  final String color;
  final String? joinCode;
  const CreatedSide({required this.id, required this.name, required this.color, this.joinCode});
  factory CreatedSide.fromJson(Map<String, dynamic> j) => CreatedSide(
        id: j['id'] as String,
        name: j['name'] as String,
        color: j['color'] as String,
        joinCode: j['join_code'] as String?,
      );
}

class CreatedGame {
  final String id;
  final String name;
  final String joinCode;
  final String status;
  final int respawnSeconds;
  final List<CreatedSide> sides;
  const CreatedGame({
    required this.id,
    required this.name,
    required this.joinCode,
    required this.status,
    required this.sides,
    this.respawnSeconds = 60,
  });
  factory CreatedGame.fromJson(Map<String, dynamic> j) => CreatedGame(
        id: j['id'] as String,
        name: j['name'] as String,
        joinCode: j['join_code'] as String,
        status: j['status'] as String,
        respawnSeconds: (j['respawn_seconds'] as num?)?.toInt() ?? 60,
        sides: (j['sides'] as List)
            .map((e) => CreatedSide.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );
}

/// DTO стороны (из GET /games/:id/sides).
class SideInfo {
  final String id;
  final String name;
  final String color;
  final String? joinCode;
  const SideInfo({
    required this.id,
    required this.name,
    required this.color,
    this.joinCode,
  });
  factory SideInfo.fromJson(Map<String, dynamic> j) => SideInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        color: j['color'] as String,
        joinCode: j['join_code'] as String?,
      );
}

/// DTO отряда.
class SquadInfo {
  final String id;
  final String sideId;
  final String name;
  const SquadInfo({required this.id, required this.sideId, required this.name});
  factory SquadInfo.fromJson(Map<String, dynamic> j) => SquadInfo(
        id: j['id'] as String,
        sideId: j['side_id'] as String,
        name: j['name'] as String,
      );
}

/// DTO члена игры (из GET /games/:id/members).
class MemberInfo {
  final String id;
  final String userId;
  final String? sideId;
  final String? squadId;
  final String callsign;
  final String role; // organizer | side_commander | squad_leader | soldier
  final String status; // alive | dead | respawning
  final double? lastLng;
  final double? lastLat;
  const MemberInfo({
    required this.id,
    required this.userId,
    required this.callsign,
    required this.role,
    required this.status,
    this.sideId,
    this.squadId,
    this.lastLng,
    this.lastLat,
  });
  factory MemberInfo.fromJson(Map<String, dynamic> j) => MemberInfo(
        id: j['id'] as String,
        userId: j['user_id'] as String,
        sideId: j['side_id'] as String?,
        squadId: j['squad_id'] as String?,
        callsign: j['callsign'] as String,
        role: j['role'] as String,
        status: j['status'] as String,
        lastLng: (j['last_lng'] as num?)?.toDouble(),
        lastLat: (j['last_lat'] as num?)?.toDouble(),
      );
}

class GamesApi {
  final Dio _dio;
  GamesApi(this._dio);

  Future<CreatedGame> create({
    required String name,
    required List<SideInput> sides,
    double? bboxMinLng,
    double? bboxMinLat,
    double? bboxMaxLng,
    double? bboxMaxLat,
    int? respawnSeconds,
  }) async {
    final res = await _dio.post('/games', data: {
      'name': name,
      'sides': sides.map((s) => s.toJson()).toList(),
      if (bboxMinLng != null) 'bbox_min_lng': bboxMinLng,
      if (bboxMinLat != null) 'bbox_min_lat': bboxMinLat,
      if (bboxMaxLng != null) 'bbox_max_lng': bboxMaxLng,
      if (bboxMaxLat != null) 'bbox_max_lat': bboxMaxLat,
      if (respawnSeconds != null) 'respawn_seconds': respawnSeconds,
    });
    return CreatedGame.fromJson(res.data as Map<String, dynamic>);
  }

  Future<JoinResult> joinBySideCode(String sideJoinCode, {String? callsign}) async {
    final res = await _dio.post('/games/join', data: {
      'side_join_code': sideJoinCode.toUpperCase().trim(),
      if (callsign != null && callsign.isNotEmpty) 'callsign': callsign,
    });
    return JoinResult.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<SideInfo>> listSides(String gameId) async {
    final res = await _dio.get('/games/$gameId/sides');
    final raw = (res.data['sides'] as List).cast<Map<String, dynamic>>();
    return raw.map(SideInfo.fromJson).toList(growable: false);
  }

  Future<List<SquadInfo>> listSquads(String gameId) async {
    final res = await _dio.get('/games/$gameId/squads');
    final raw = (res.data['squads'] as List).cast<Map<String, dynamic>>();
    return raw.map(SquadInfo.fromJson).toList(growable: false);
  }

  Future<SquadInfo> createSquad(
    String gameId, {
    required String sideId,
    required String name,
  }) async {
    final res = await _dio.post('/games/$gameId/squads', data: {
      'side_id': sideId,
      'name': name,
    });
    return SquadInfo.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<MemberInfo>> listMembers(String gameId) async {
    final res = await _dio.get('/games/$gameId/members');
    final raw = (res.data['members'] as List).cast<Map<String, dynamic>>();
    return raw.map(MemberInfo.fromJson).toList(growable: false);
  }

  /// PATCH /games/:id/members/:uid. Все поля опциональны.
  Future<MemberInfo> updateMember(
    String gameId,
    String memberId, {
    String? sideId,
    String? squadId,
    String? role,
    String? callsign,
  }) async {
    final res = await _dio.patch(
      '/games/$gameId/members/$memberId',
      data: {
        if (sideId != null) 'side_id': sideId,
        if (squadId != null) 'squad_id': squadId,
        if (role != null) 'role': role,
        if (callsign != null) 'callsign': callsign,
      },
    );
    return MemberInfo.fromJson(res.data as Map<String, dynamic>);
  }

  /// PATCH-эквивалент: POST /games/:id/map-pack. Доступно только организатору.
  Future<void> setMapPack({
    required String gameId,
    required String mapPackUrl,
    double? bboxMinLng,
    double? bboxMinLat,
    double? bboxMaxLng,
    double? bboxMaxLat,
  }) async {
    await _dio.post('/games/$gameId/map-pack', data: {
      'map_pack_url': mapPackUrl,
      if (bboxMinLng != null) 'bbox_min_lng': bboxMinLng,
      if (bboxMinLat != null) 'bbox_min_lat': bboxMinLat,
      if (bboxMaxLng != null) 'bbox_max_lng': bboxMaxLng,
      if (bboxMaxLat != null) 'bbox_max_lat': bboxMaxLat,
    });
  }
}

final gamesApiProvider = Provider<GamesApi>((ref) {
  return GamesApi(ref.read(apiClientProvider).dio);
});
