import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/rendering.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

class PremiumQRCodeAnimatedPage extends StatefulWidget {
  const PremiumQRCodeAnimatedPage({super.key});

  @override
  State<PremiumQRCodeAnimatedPage> createState() => _PremiumQRCodeAnimatedPageState();
}

class _PremiumQRCodeAnimatedPageState extends State<PremiumQRCodeAnimatedPage> {
  final GlobalKey qrKey = GlobalKey();
  final TextEditingController referralController = TextEditingController();
  bool _loading = false;

  User? get currentUser => FirebaseAuth.instance.currentUser;

  // ================= QR DATA =================
  Map<String, dynamic> _currentOrderData = {};
  bool _orderCompleted = false;

  Future<Map<String, dynamic>> _generateQRCodeData() async {
    if (_orderCompleted) return {"type": "referral", "uid": currentUser!.uid};

    // Vérifier s'il y a une commande active pour ce client
    final orders = await FirebaseFirestore.instance
        .collection("orders")
        .where("clientId", isEqualTo: currentUser!.uid)
        .where("status", isEqualTo: "en_cours")
        .get();

    if (orders.docs.isEmpty) {
      return {"type": "referral", "uid": currentUser!.uid};
    }

    final order = orders.docs.first.data();
    _currentOrderData = order;

    return {
      "type": "order",
      "clientName": order["clientName"],
      "clientPhone": order["clientPhone"],
      "product": order["productName"],
      "price": order["price"],
      "sellerName": order["sellerName"],
      "sellerPhone": order["sellerPhone"],
      "orderId": orders.docs.first.id
    };
  }

  // ================= SAVE QR =================
  Future<void> _saveQr() async {
    if (!await Permission.storage.request().isGranted) return;

    try {
      RenderRepaintBoundary boundary =
          qrKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      Uint8List pngBytes = byteData!.buffer.asUint8List();

      final directory = await getDownloadsDirectory();
      final filePath = '${directory!.path}/nyota_qr.png';
      final file = File(filePath);
      await file.writeAsBytes(pngBytes);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('QR Code sauvegardé 🎉\nDossier : $filePath')),
      );
    } catch (e) {
      debugPrint("Erreur sauvegarde QR: $e");
    }
  }

  // ================= SHARE QR =================
  Future<void> _shareQr() async {
    try {
      RenderRepaintBoundary boundary =
          qrKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      Uint8List pngBytes = byteData!.buffer.asUint8List();

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/nyota_qr.png');
      await file.writeAsBytes(pngBytes);

      await Share.shareXFiles([XFile(file.path)], text: "Voici mon QR Nyota 🚀");
    } catch (e) {
      debugPrint("Erreur partage QR: $e");
    }
  }

  // ================= REFERRAL =================
  Future<void> _submitReferralCode() async {
    final code = referralController.text.trim();
    if (code.isEmpty || currentUser == null) return;

    setState(() => _loading = true);

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection("users")
          .where("referral_code", isEqualTo: code)
          .get();

      if (snapshot.docs.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Code invalide ❌")));
      } else {
        final referrerUid = snapshot.docs.first.id;

        await FirebaseFirestore.instance
            .collection("users")
            .doc(referrerUid)
            .update({
          "referrals": FieldValue.arrayUnion([currentUser!.uid])
        });

        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Parrainage validé 🎉")));
      }
    } catch (e) {
      debugPrint("Erreur parrainage: $e");
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Erreur, réessaye")));
    } finally {
      setState(() => _loading = false);
    }
  }

  // ================= CONFIRM ORDER =================
  Future<void> _confirmOrder() async {
    if (_currentOrderData.isEmpty) return;

    try {
      // Vérifier que le client qui scanne est bien celui de la commande
      final orderId = _currentOrderData["orderId"];
      final clientId = _currentOrderData["clientId"];
      if (currentUser!.uid != clientId) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Erreur: ce QR n'est pas pour vous")));
        return;
      }

      await FirebaseFirestore.instance
          .collection("orders")
          .doc(orderId)
          .update({"status": "reçu", "receivedAt": DateTime.now()});

      // Marquer QR comme redevenu parrainage
      _orderCompleted = true;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Commande confirmée ✅")));
    } catch (e) {
      debugPrint("Erreur confirmation commande: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (currentUser == null) {
      return const Scaffold(
        body: Center(child: Text("Utilisateur non connecté")),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text("QR Premium Nyota")),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Text(
              'Scanne ce QR pour me trouver 🚀',
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 20),

            FutureBuilder<Map<String, dynamic>>(
              future: _generateQRCodeData(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const CircularProgressIndicator();
                }

                final data = snapshot.data!;
                return GestureDetector(
                  onTap: data["type"] == "order" ? _confirmOrder : null,
                  child: RepaintBoundary(
                    key: qrKey,
                    child: QrImageView(
                      data: data.toString(),
                      size: 250,
                      backgroundColor: Colors.white,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _saveQr,
                  icon: const Icon(Icons.save),
                  label: const Text("Sauvegarder"),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: _shareQr,
                  icon: const Icon(Icons.share),
                  label: const Text("Partager"),
                ),
              ],
            ),

            const SizedBox(height: 30),

            TextField(
              controller: referralController,
              decoration: const InputDecoration(
                labelText: "Code de parrainage",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            _loading
                ? const CircularProgressIndicator()
                : ElevatedButton(
                    onPressed: _submitReferralCode,
                    child: const Text("Valider code"),
                  ),

            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LeaderboardPage()),
                );
              },
              child: const Text("Voir classement des parrains 🏆"),
            ),
          ],
        ),
      ),
    );
  }
}

// ================= Leaderboard =================
class LeaderboardPage extends StatelessWidget {
  const LeaderboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Classement des parrains 🚀")),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection("users")
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final docs = snapshot.data!.docs;

          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final data = docs[index].data() as Map<String, dynamic>;
              final name = data["name"] ?? "Anonyme";
              final count = (data["referrals"] as List<dynamic>?)?.length ?? 0;

              return ListTile(
                leading: CircleAvatar(child: Text("${index + 1}")),
                title: Text(name),
                trailing: Text("$count filleuls"),
              );
            },
          );
        },
      ),
    );
  }
}
