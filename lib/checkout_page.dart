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

class CheckoutPage extends StatefulWidget {
  final String productName;
  final double productPrice;
  final String sellerId;
  final String sellerName;
  final String sellerPhone;

  const CheckoutPage({
    super.key,
    required this.productName,
    required this.productPrice,
    required this.sellerId,
    required this.sellerName,
    required this.sellerPhone,
  });

  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  final GlobalKey qrKey = GlobalKey();
  bool _loading = false;
  bool _orderConfirmed = false;

  User? get currentUser => FirebaseAuth.instance.currentUser;

  late String orderId;
  Map<String, dynamic>? qrData;

  @override
  void initState() {
    super.initState();
    _createOrder();
  }

  Future<void> _createOrder() async {
    if (currentUser == null) return;

    setState(() => _loading = true);

    try {
      final docRef = await FirebaseFirestore.instance.collection("orders").add({
        "product_name": widget.productName,
        "product_price": widget.productPrice,
        "seller_id": widget.sellerId,
        "seller_name": widget.sellerName,
        "seller_phone": widget.sellerPhone,
        "client_id": currentUser!.uid,
        "client_name": currentUser!.displayName ?? "Anonyme",
        "client_phone": currentUser!.phoneNumber ?? "",
        "status": "pending", // pending -> delivered -> confirmed
        "created_at": FieldValue.serverTimestamp(),
      });

      orderId = docRef.id;

      qrData = {
        "order_id": orderId,
        "product_name": widget.productName,
        "product_price": widget.productPrice,
        "client_name": currentUser!.displayName ?? "Anonyme",
        "client_phone": currentUser!.phoneNumber ?? "",
        "seller_name": widget.sellerName,
        "seller_phone": widget.sellerPhone,
        "status": "pending",
      };
    } catch (e) {
      debugPrint("Erreur création commande: $e");
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Erreur création commande")));
    } finally {
      setState(() => _loading = false);
    }
  }

  // ✅ Confirmer commande par le client
  Future<void> _confirmOrder() async {
    if (orderId.isEmpty || currentUser == null) return;

    setState(() => _loading = true);

    try {
      await FirebaseFirestore.instance
          .collection("orders")
          .doc(orderId)
          .update({"status": "confirmed"});

      setState(() {
        _orderConfirmed = true;
        qrData = {
          "referral": "Invite tes amis !",
        }; // QR redevient outil de parrainage
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Commande confirmée ✅")),
      );
    } catch (e) {
      debugPrint("Erreur confirmation: $e");
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Erreur confirmation")));
    } finally {
      setState(() => _loading = false);
    }
  }

  // Sauvegarde QR
  Future<void> _saveQr() async {
    if (!await Permission.storage.request().isGranted) return;

    try {
      RenderRepaintBoundary boundary =
          qrKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      Uint8List pngBytes = byteData!.buffer.asUint8List();

      final directory = await getDownloadsDirectory();
      final filePath = '${directory!.path}/nyota_order_$orderId.png';
      final file = File(filePath);
      await file.writeAsBytes(pngBytes);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('QR Code sauvegardé 🎉\nDossier : $filePath')),
      );
    } catch (e) {
      debugPrint("Erreur sauvegarde QR: $e");
    }
  }

  // Partage QR
  Future<void> _shareQr() async {
    try {
      RenderRepaintBoundary boundary =
          qrKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      Uint8List pngBytes = byteData!.buffer.asUint8List();

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/nyota_order_$orderId.png');
      await file.writeAsBytes(pngBytes);

      await Share.shareXFiles([XFile(file.path)], text: "Voici mon QR Nyota 🚀");
    } catch (e) {
      debugPrint("Erreur partage QR: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (currentUser == null) {
      return const Scaffold(
        body: Center(child: Text("Utilisateur non connecté")),
      );
    }

    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text("Checkout & QR")),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text("Produit : ${widget.productName}"),
            Text("Prix : ${widget.productPrice}"),
            Text("Vendeur : ${widget.sellerName}"),
            const SizedBox(height: 20),

            RepaintBoundary(
              key: qrKey,
              child: QrImageView(
                data: qrData != null ? qrData.toString() : "",
                size: 250,
                backgroundColor: Colors.white,
              ),
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
            const SizedBox(height: 20),
            _orderConfirmed
                ? const Text("Commande confirmée ✅")
                : ElevatedButton(
                    onPressed: _confirmOrder,
                    child: const Text("Confirmer la commande"),
                  ),
          ],
        ),
      ),
    );
  }
}
