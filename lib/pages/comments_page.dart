import 'package:flutter/material.dart';
import 'package:nyota_app/pages/public_profile_page.dart';
import 'package:nyota_app/widgets/nyota_background.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';

class CommentsPage extends StatefulWidget {
  final String postId;

  const CommentsPage({super.key, required this.postId});

  @override
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  final supabase = Supabase.instance.client;
  final user = FirebaseAuth.instance.currentUser;

  final TextEditingController _commentCtrl = TextEditingController();

  List<Map<String, dynamic>> mainComments = [];
  Map<String, List<Map<String, dynamic>>> replies = {};
  late Set<String> expandedComments;

  bool loading = true;

  @override
  void initState() {
    super.initState();
    expandedComments = {};
    loadComments();
  }

  Future<Map<String, dynamic>?> fetchUserProfile(String userId) async {
    try {
      final res = await supabase
          .from('public_profiles')
          .select('username, avatar_url')
          .eq('user_id', userId)
          .single();
      return res;
    } catch (_) {
      return null;
    }
  }

  // 🔥 Load all comments for this post
  Future<void> loadComments() async {
    setState(() => loading = true);

    final data = await supabase
        .from('comments')
        .select()
        .eq('post_id', widget.postId)
        .order('root_id')
        .order('created_at');

    mainComments.clear();
    replies.clear();

    for (var c in data) {
      if (c['parent_id'] == null) {
        mainComments.add(c);
      } else {
        final pid = c['parent_id'];
        replies.putIfAbsent(pid, () => []);
        replies[pid]!.add(c);
      }
    }

    setState(() => loading = false);
  }

  // 🔥 publish a comment
  Future<void> sendComment({String? parentId}) async {
    if (_commentCtrl.text.trim().isEmpty || user == null) return;

    final text = _commentCtrl.text.trim();
    _commentCtrl.clear();

    String? rootId;

    // 👉 Si c’est une réponse, récupérer le root_id du parent
    if (parentId != null) {
      final parent = await supabase
          .from('comments')
          .select('root_id')
          .eq('id', parentId)
          .single();

      rootId = parent['root_id'];
    }

    // 👉 Insertion
    final res = await supabase
        .from('comments')
        .insert({
          "post_id": widget.postId,
          "user_id": user!.uid,
          "content": text,
          "parent_id": parentId,
          "root_id": rootId, // temporaire pour les réponses
        })
        .select()
        .single();

    // 👉 Si c’est un commentaire principal, root_id = id
    if (parentId == null) {
      await supabase
          .from('comments')
          .update({"root_id": res['id']}).eq('id', res['id']);
    }

    await loadComments();
  }

  Widget buildCommentItem(Map<String, dynamic> comment,
      {bool isReply = false}) {
    final String id = comment['id'];
    final String content = comment['content'];
    final String userId = comment['user_id'];

    return Padding(
      padding: EdgeInsets.only(left: isReply ? 40 : 10, right: 10, top: 10),
      child: FutureBuilder<Map<String, dynamic>?>(
        future: fetchUserProfile(userId),
        builder: (context, snapshot) {
          final profile = snapshot.data;
          final username = profile?['username'] ?? 'Utilisateur';
          final avatarUrl = profile?['avatar_url'];

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              /// 👤 AVATAR + USERNAME (cliquable)
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PublicProfilePage(
                        sellerId: userId,
                      ),
                    ),
                  );
                },
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundImage:
                          avatarUrl != null ? NetworkImage(avatarUrl) : null,
                      backgroundColor: Colors.grey.shade300,
                      child: avatarUrl == null
                          ? const Icon(Icons.person,
                              size: 18, color: Colors.black54)
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      username,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 5),

              /// 💬 CONTENU
              Text(
                content,
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 14,
                ),
              ),

              const SizedBox(height: 5),

              /// ↩️ RÉPONDRE
              GestureDetector(
                onTap: () => showReplyInput(id),
                child: const Text(
                  "Répondre",
                  style: TextStyle(color: Colors.blueAccent),
                ),
              ),

              /// 🔽 VOIR / MASQUER RÉPONSES
              if (!isReply && replies[id] != null)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      expandedComments.contains(id)
                          ? expandedComments.remove(id)
                          : expandedComments.add(id);
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      expandedComments.contains(id)
                          ? "Masquer les réponses ▲"
                          : "Voir ${replies[id]!.length} réponses ▼",
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                ),

              /// 📌 RÉPONSES INLINE (TikTok-style)
              if (expandedComments.contains(id) && replies[id] != null)
                Column(
                  children: replies[id]!
                      .map((r) => buildCommentItem(r, isReply: true))
                      .toList(),
                ),
            ],
          );
        },
      ),
    );
  }

  void showReplyInput(String parentId) {
    showModalBottomSheet(
      backgroundColor: Colors.black87,
      context: context,
      builder: (_) {
        return SafeArea(
          child: Container(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _commentCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: "Votre réponse...",
                      hintStyle: TextStyle(color: Colors.white54),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.blueAccent),
                  onPressed: () {
                    Navigator.pop(context);
                    sendComment(parentId: parentId);
                  },
                )
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text(
          "Commentaires",
          style: TextStyle(color: Colors.black),
        ),
        elevation: 1,
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: NyotaBackground(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  /// 📜 LISTE DES COMMENTAIRES
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      children: [
                        for (var c in mainComments) buildCommentItem(c),
                      ],
                    ),
                  ),

                  /// ✍️ ZONE DE SAISIE
                  SafeArea(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border(
                          top: BorderSide(color: Colors.grey.shade300),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _commentCtrl,
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 14,
                              ),
                              decoration: InputDecoration(
                                hintText: "Ajouter un commentaire...",
                                hintStyle: TextStyle(
                                  color: Colors.grey,
                                ),
                                filled: true,
                                fillColor: Colors.grey.shade100,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(
                              Icons.send,
                              color: Colors.blueAccent,
                            ),
                            onPressed: () => sendComment(),
                          )
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
