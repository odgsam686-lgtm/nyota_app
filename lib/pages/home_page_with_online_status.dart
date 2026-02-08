import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:nyota_app/pages/feed_page.dart';
import 'package:nyota_app/conversations_list_screen.dart';

class HomePageWithOnlineStatus extends StatefulWidget {
  final User user;
  const HomePageWithOnlineStatus({Key? key, required this.user}) : super(key: key);

  @override
  _HomePageWithOnlineStatusState createState() => _HomePageWithOnlineStatusState();
}

class _HomePageWithOnlineStatusState extends State<HomePageWithOnlineStatus>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setUserOnlineStatus(true);
  }

  @override
  void dispose() {
    _setUserOnlineStatus(false);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setUserOnlineStatus(true);
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _setUserOnlineStatus(false);
    }
  }

  Future<void> _setUserOnlineStatus(bool isOnline) async {
    try {
      await FirebaseFirestore.instance.collection('users').doc(widget.user.uid).update({
        'online': isOnline,
        'lastSeen': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Erreur mise à jour statut en ligne: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: const FeedPage(), // ✅ Ton feed principal TikTok-like ici
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.deepPurple,
        child: const Icon(Icons.message, color: Colors.white),
        onPressed: () {
          // ✅ Bouton pour accéder à la messagerie
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ConversationsListScreen(
                currentUserId: widget.user.uid,
              ),
            ),
          );
        },
      ),
    );
  }
}
