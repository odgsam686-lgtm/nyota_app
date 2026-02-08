// lib/settings_page.dart
import 'package:flutter/material.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paramètres')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Compte'),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Confidentialité'),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Notifications'),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Libérer l’espace / économiseur de données'),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Signaler un problème'),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Assistance'),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Conditions et politique'),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Changer de compte'),
            onTap: () {},
          ),
          ListTile(
            title: const Text('Se déconnecter'),
            onTap: () async {
              // Ici on déconnecte l’utilisateur
              // Nécessite import firebase_auth dans main.dart
              // FirebaseAuth.instance.signOut();
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }
}
