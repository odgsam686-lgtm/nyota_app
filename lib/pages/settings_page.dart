import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:nyota_app/main.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;


class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _logout(BuildContext context) async {
    // ✅ 1. Déconnexion Firebase
    await FirebaseAuth.instance.signOut();

    // ✅ 2. Déconnexion Supabase
    await supa.Supabase.instance.client.auth.signOut();
    if (!context.mounted) return;

    // ✅ 3. Redirection PROPRE (reset navigation)
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paramètres et confidentialité'),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 12),

          const ListTile(
            leading: Icon(Icons.person_outline),
            title: Text('Compte'),
          ),

          const ListTile(
            leading: Icon(Icons.lock_outline),
            title: Text('Sécurité'),
          ),

          ListTile(
            leading: const Icon(Icons.notifications_none),
            title: const Text('Notifications'),
            onTap: () {
              Navigator.of(context).pushNamed('/notifications');
            },
          ),

          const Divider(height: 32),

          /// 🔴 DÉCONNEXION (TON CODE)
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text(
              'Déconnexion',
              style: TextStyle(color: Colors.red),
            ),
            onTap: () => _logout(context),
          ),
        ],
      ),
    );
  }
}
