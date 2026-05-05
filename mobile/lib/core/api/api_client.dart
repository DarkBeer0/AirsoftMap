import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';

/// Dio-клиент к Go-бэку. JWT добавляется автоматически из Supabase-сессии.
class ApiClient {
  final Dio dio;

  ApiClient._(this.dio);

  factory ApiClient.create() {
    final dio = Dio(BaseOptions(
      baseUrl: '${SupabaseConfig.apiBaseUrl}/api/v1',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));

    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final token = Supabase.instance.client.auth.currentSession?.accessToken;
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
    ));

    return ApiClient._(dio);
  }
}

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient.create());
