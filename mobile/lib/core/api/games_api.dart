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
  final String? mapPackUrl;

  const JoinResult({
    required this.gameId,
    required this.gameName,
    required this.sideId,
    required this.sideName,
    required this.sideColor,
    required this.callsign,
    required this.role,
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
  final List<CreatedSide> sides;
  const CreatedGame({
    required this.id,
    required this.name,
    required this.joinCode,
    required this.status,
    required this.sides,
  });
  factory CreatedGame.fromJson(Map<String, dynamic> j) => CreatedGame(
        id: j['id'] as String,
        name: j['name'] as String,
        joinCode: j['join_code'] as String,
        status: j['status'] as String,
        sides: (j['sides'] as List)
            .map((e) => CreatedSide.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
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
  }) async {
    final res = await _dio.post('/games', data: {
      'name': name,
      'sides': sides.map((s) => s.toJson()).toList(),
      if (bboxMinLng != null) 'bbox_min_lng': bboxMinLng,
      if (bboxMinLat != null) 'bbox_min_lat': bboxMinLat,
      if (bboxMaxLng != null) 'bbox_max_lng': bboxMaxLng,
      if (bboxMaxLat != null) 'bbox_max_lat': bboxMaxLat,
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
}

final gamesApiProvider = Provider<GamesApi>((ref) {
  return GamesApi(ref.read(apiClientProvider).dio);
});
