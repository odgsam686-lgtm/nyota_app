import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:qr_flutter/qr_flutter.dart';

class QRCodePage extends StatelessWidget {
  const QRCodePage({super.key});

  @override
  Widget build(BuildContext context) {
    final User? user = FirebaseAuth.instance.currentUser;

    // Si l'utilisateur n'est pas connecté
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ton Code QR')),
        body: const Center(
          child: Text(
            'Utilisateur non connecté',
            style: TextStyle(fontSize: 16),
          ),
        ),
      );
    }

    // Si l'utilisateur est connecté
    return Scaffold(
      appBar: AppBar(title: const Text('Ton Code QR')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'Scanne ce QR pour me trouver sur Nyota',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),

            // QR CODE avec l’UID Firebase
            QrImageView(
              data: user.uid,
              version: QrVersions.auto,
              size: 250.0,
              gapless: false,
            ),

            const SizedBox(height: 20),

            Text(
              "UID : ${user.uid}",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
