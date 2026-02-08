import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_page.dart';

class SellerProfilePage extends StatefulWidget {
  final String sellerId;
  const SellerProfilePage({super.key, required this.sellerId});

  @override
  State<SellerProfilePage> createState() => _SellerProfilePageState();
}

class _SellerProfilePageState extends State<SellerProfilePage> {
  final currentUser = FirebaseAuth.instance.currentUser;
  final supabase = Supabase.instance.client;

  bool isFollowing = false;
  int followersCount = 0;
  double averageRating = 0.0;

  String sellerName = "";
  String sellerPhoto = "";

  @override
  void initState() {
    super.initState();
    _loadSellerInfo();
    _loadFollowStatus();
    _loadFollowersCount();
    _loadAverageRating();
  }

  // ---------------------------------------------------------------------------
  // LOAD SELLER INFO (Firestore)
  // ---------------------------------------------------------------------------
  Future<void> _loadSellerInfo() async {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.sellerId)
        .get();

    if (doc.exists) {
      final data = doc.data()!;
      setState(() {
        sellerName =
            "${data['firstName'] ?? ''} ${data['lastName'] ?? ''}".trim();
        sellerPhoto = data['photoUrl'] ?? "";
      });
    }
  }

  // ---------------------------------------------------------------------------
  // FOLLOW SYSTEM (Firestore)
  // ---------------------------------------------------------------------------
  Future<void> _loadFollowStatus() async {
    if (currentUser == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('followers')
        .doc(widget.sellerId)
        .collection('list')
        .doc(currentUser!.uid)
        .get();

    setState(() {
      isFollowing = doc.exists;
    });
  }

  Future<void> _loadFollowersCount() async {
    final snap = await FirebaseFirestore.instance
        .collection('followers')
        .doc(widget.sellerId)
        .collection('list')
        .get();

    setState(() {
      followersCount = snap.docs.length;
    });
  }

  Future<void> _toggleFollow() async {
    if (currentUser == null) return;

    final ref = FirebaseFirestore.instance
        .collection('followers')
        .doc(widget.sellerId)
        .collection('list')
        .doc(currentUser!.uid);

    if (isFollowing) {
      await ref.delete();
      setState(() {
        isFollowing = false;
        followersCount--;
      });
    } else {
      await ref.set({"timestamp": FieldValue.serverTimestamp()});
      setState(() {
        isFollowing = true;
        followersCount++;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // RATINGS (Firestore)
  // ---------------------------------------------------------------------------
  Future<void> _loadAverageRating() async {
    final snap = await FirebaseFirestore.instance
        .collection('reviews')
        .doc(widget.sellerId)
        .collection('list')
        .get();

    if (snap.docs.isEmpty) {
      setState(() => averageRating = 0.0);
      return;
    }

    double total = 0;
    for (var d in snap.docs) {
      total += (d['rating'] ?? 0).toDouble();
    }

    setState(() {
      averageRating = total / snap.docs.length;
    });
  }

  // ---------------------------------------------------------------------------
  // 💬 CHAT SUPABASE (LOGIQUE WHATSAPP)
  // ---------------------------------------------------------------------------
  Future<void> _openChatWithSeller() async {
    if (currentUser == null) return;

    final myId = currentUser!.uid;
    final sellerId = widget.sellerId;

    // 1️⃣ Vérifier si conversation existe
    final existing = await supabase
        .from('conversations')
        .select()
        .or(
          'and(user_a.eq.$myId,user_b.eq.$sellerId),'
          'and(user_a.eq.$sellerId,user_b.eq.$myId)',
        )
        .maybeSingle();

    String conversationId;

    if (existing != null) {
      conversationId = existing['id'];
    } else {
      // 2️⃣ Créer la conversation
      final created = await supabase
          .from('conversations')
          .insert({
            'user_a': myId,
            'user_b': sellerId,
          })
          .select()
          .single();

      conversationId = created['id'];
    }

    if (!mounted) return;

    // 3️⃣ Ouvrir le chat
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(
          conversationId: conversationId,
          otherUserId: sellerId,
          otherUsername: sellerName.isNotEmpty ? sellerName : 'Vendeur',
          otherAvatar: sellerPhoto.isNotEmpty ? sellerPhoto : null,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final postsQuery = FirebaseFirestore.instance
        .collection('posts')
        .where('sellerId', isEqualTo: widget.sellerId)
        .orderBy('timestamp', descending: true);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Profil Vendeur"),
        actions: [
          IconButton(
            icon: const Icon(Icons.message),
            onPressed: _openChatWithSeller, // ✅ SUPABASE CHAT
          )
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------------- SELLER HEADER ----------------
          Row(
            children: [
              CircleAvatar(
                radius: 40,
                backgroundImage: (sellerPhoto.isNotEmpty)
                    ? NetworkImage(sellerPhoto)
                    : const AssetImage("assets/images/avatar.png")
                        as ImageProvider,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sellerName.isNotEmpty ? sellerName : "Vendeur",
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text("Abonnés : $followersCount"),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.star, color: Colors.amber),
                        Text(
                          averageRating.toStringAsFixed(1),
                          style: const TextStyle(fontSize: 16),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            ],
          ),

          const SizedBox(height: 18),

          ElevatedButton(
            onPressed: _toggleFollow,
            child: Text(isFollowing ? "Se désabonner" : "Suivre"),
          ),

          const SizedBox(height: 20),
          const Divider(),

          // ---------------- POSTS ----------------
          const Text(
            "Publications",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),

          StreamBuilder<QuerySnapshot>(
            stream: postsQuery.snapshots(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: Text("Aucune publication")),
                );
              }

              return Column(
                children: docs.map((doc) {
                  final data = Map<String, dynamic>.from(doc.data() as Map);
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    child: ListTile(
                      leading: data['mediaUrl'] != null
                          ? Image.network(
                              data['mediaUrl'],
                              width: 70,
                              height: 70,
                              fit: BoxFit.cover,
                            )
                          : const Icon(Icons.image, size: 50),
                      title: Text(
                        data['description'] ?? 'Publication',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(data['isVideo'] ? "Vidéo" : "Photo"),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}
