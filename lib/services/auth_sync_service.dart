import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;

class AuthSyncService {
  static final _supabase = supa.Supabase.instance.client;

  /// 🔄 Synchronise l'utilisateur Firebase avec Supabase
  static Future<void> syncUser(User firebaseUser) async {
    try {
      final uid = firebaseUser.uid;
      final email = firebaseUser.email;

      // Vérifier si l'utilisateur existe déjà dans Supabase
      final existing = await _supabase
          .from('users')
          .select('id')
          .eq('firebase_uid', uid)
          .maybeSingle();

      if (existing == null) {
        // Créer l'utilisateur côté Supabase
        await _supabase.from('users').insert({
          'firebase_uid': uid,
          'email': email,
          'is_seller': false,
          'created_at': DateTime.now().toIso8601String(),
        });
      }
    } catch (e) {
      print('❌ AuthSyncService error: $e');
    }
  }
}
