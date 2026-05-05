import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Анонимные сессии Supabase: достаточно для входа по QR.
/// Постоянный аккаунт можно добавить позже (link anonymous → email).
class AuthService {
  final SupabaseClient _client;
  AuthService(this._client);

  Session? get session => _client.auth.currentSession;
  User? get user => _client.auth.currentUser;

  Future<Session> ensureSignedIn() async {
    final existing = _client.auth.currentSession;
    if (existing != null) return existing;
    final res = await _client.auth.signInAnonymously();
    final s = res.session;
    if (s == null) {
      throw StateError('Anonymous sign-in failed: no session returned');
    }
    return s;
  }

  Future<void> signOut() => _client.auth.signOut();
}

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(Supabase.instance.client);
});

final authStateProvider = StreamProvider<AuthState>((ref) {
  return Supabase.instance.client.auth.onAuthStateChange;
});
