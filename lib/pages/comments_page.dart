import 'package:flutter/material.dart';
import 'dart:async';
import 'package:nyota_app/pages/public_profile_page.dart';
import 'package:nyota_app/widgets/nyota_background.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';

enum CommentSortMode { relevance, recent }

Future<void> openComments(BuildContext context, String postId,
    {int? initialCount}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CommentBottomSheet(
      postId: postId,
      initialCount: initialCount,
    ),
  );
}

class CommentsPage extends StatefulWidget {
  final String postId;

  const CommentsPage({super.key, required this.postId});

  @override
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: NyotaBackground(
        child: CommentBottomSheet(
          postId: widget.postId,
        ),
      ),
    );
  }
}

class CommentNode {
  final Map<String, dynamic> comment;
  final List<CommentNode> children = [];

  CommentNode(this.comment);

  String get id => comment['id']?.toString() ?? '';
  String? get parentId => comment['parent_id']?.toString();
}

class VisibleComment {
  final CommentNode node;
  final int level;

  VisibleComment(this.node, this.level);
}

class CommentBottomSheet extends StatefulWidget {
  final String postId;
  final int? initialCount;

  const CommentBottomSheet({
    super.key,
    required this.postId,
    this.initialCount,
  });

  @override
  State<CommentBottomSheet> createState() => _CommentBottomSheetState();
}

class _CommentBottomSheetState extends State<CommentBottomSheet> {
  final supabase = Supabase.instance.client;
  final user = FirebaseAuth.instance.currentUser;

  final TextEditingController _commentCtrl = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  bool _sendingMedia = false;
  File? _pendingImageFile;
  Set<String> _likedByMe = {};
  CommentSortMode _sortMode = CommentSortMode.relevance;
  StreamSubscription<List<Map<String, dynamic>>>? _commentsSub;
  StreamSubscription<List<Map<String, dynamic>>>? _likesSub;

  List<Map<String, dynamic>> _allComments = [];
  List<CommentNode> _roots = [];
  Map<String, bool> expandedById = {};
  bool loading = true;

  @override
  void initState() {
    super.initState();
    loadComments();
    _listenCommentsRealtime();
    _listenLikesRealtime();
  }

  @override
  void dispose() {
    _commentsSub?.cancel();
    _likesSub?.cancel();
    super.dispose();
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

  Future<void> loadComments() async {
    setState(() => loading = true);

    final data = await supabase
        .from('comments')
        .select()
        .eq('post_id', widget.postId)
        .order('root_id')
        .order('created_at');

    _allComments = List<Map<String, dynamic>>.from(data);
    await _syncCommentsCount();
    resetExpandState();
    _roots = buildCommentTree(_allComments);
    await _loadMyLikes();

    setState(() => loading = false);
  }

  void _listenCommentsRealtime() {
    _commentsSub?.cancel();
    _commentsSub = supabase
        .from('comments')
        .stream(primaryKey: ['id'])
        .eq('post_id', widget.postId)
        .listen((rows) {
      _allComments = List<Map<String, dynamic>>.from(rows);
      _roots = buildCommentTree(_allComments);
      if (mounted) setState(() {});
    }, onError: (e) {
      debugPrint('comments realtime error: $e');
    });
  }

  void _listenLikesRealtime() {
    final uid = user?.uid;
    if (uid == null) return;
    _likesSub?.cancel();
    _likesSub = supabase
        .from('comment_likes')
        .stream(primaryKey: ['id'])
        .eq('user_id', uid)
        .listen((rows) {
      final set = <String>{};
      for (final r in rows) {
        final id = r['comment_id']?.toString();
        if (id != null && id.isNotEmpty) set.add(id);
      }
      if (mounted) {
        setState(() {
          _likedByMe = set;
        });
      } else {
        _likedByMe = set;
      }
    }, onError: (e) {
      debugPrint('likes realtime error: $e');
    });
  }

  Future<void> _loadMyLikes() async {
    final uid = user?.uid;
    if (uid == null) return;
    try {
      final rows = await supabase
          .from('comment_likes')
          .select('comment_id')
          .eq('user_id', uid);
      final set = <String>{};
      for (final r in rows) {
        final id = r['comment_id']?.toString();
        if (id != null && id.isNotEmpty) set.add(id);
      }
      _likedByMe = set;
    } catch (e) {
      debugPrint('load likes error: $e');
    }
  }

  Future<void> sendComment({String? parentId}) async {
    if (user == null) return;
    final text = _commentCtrl.text.trim();
    final file = _pendingImageFile;
    if (text.isEmpty && file == null) return;

    _commentCtrl.clear();
    _clearPendingImage();

    String content = text;
    if (file != null) {
      final imageUrl = await _uploadImage(file);
      if (imageUrl == null) {
        if (content.isEmpty) return;
      } else {
        content = _mergeTextAndImage(text, imageUrl);
      }
    }

    await sendCommentWithContent(content, parentId: parentId);
  }

  Future<void> sendCommentWithContent(String content,
      {String? parentId}) async {
    if (content.trim().isEmpty || user == null) return;

    String? rootId;

    if (parentId != null) {
      final parent = await supabase
          .from('comments')
          .select('root_id')
          .eq('id', parentId)
          .single();

      rootId = parent['root_id'];
    }

    final res = await supabase
        .from('comments')
        .insert({
          "post_id": widget.postId,
          "user_id": user!.uid,
          "content": content.trim(),
          "parent_id": parentId,
          "root_id": rootId,
        })
        .select()
        .single();

    if (parentId == null) {
      await supabase
          .from('comments')
          .update({"root_id": res['id']}).eq('id', res['id']);
    }

    await _syncCommentsCount();
    await loadComments();
  }

  Future<void> _syncCommentsCount() async {
    try {
      final rows = await supabase
          .from('comments')
          .select('id')
          .eq('post_id', widget.postId);
      final count = rows.length;
      await supabase
          .from('posts')
          .update({'comments_count': count}).eq('id', widget.postId);
    } catch (e) {
      debugPrint('sync comments_count error: $e');
    }
  }

  Future<void> _pickImage() async {
    if (_sendingMedia) return;
    if (user == null) return;
    try {
      final XFile? picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 1280,
      );
      if (picked == null) return;
      setState(() {
        _pendingImageFile = File(picked.path);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur image: $e")),
      );
    }
  }

  void _clearPendingImage() {
    if (_pendingImageFile == null) return;
    setState(() {
      _pendingImageFile = null;
    });
  }

  String _mergeTextAndImage(String text, String imageUrl) {
    if (text.trim().isEmpty) return imageUrl;
    return "$text\n$imageUrl";
  }

  Future<String?> _uploadImage(File file) async {
    if (_sendingMedia) return null;
    if (user == null) return null;
    _sendingMedia = true;
    try {
      final path = file.path;
      final ext = path.split('.').last.toLowerCase();
      final safeExt = ext.isEmpty ? 'jpg' : ext;
      final fileName =
          "comments/${widget.postId}/${DateTime.now().millisecondsSinceEpoch}.${safeExt}";

      final storage = supabase.storage.from('posts');
      final uploadRes = await storage.upload(
        fileName,
        file,
        fileOptions: const FileOptions(upsert: false),
      );

      if (uploadRes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Echec upload image")),
          );
        }
        return null;
      }

      return storage.getPublicUrl(fileName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur image: $e")),
        );
      }
      return null;
    } finally {
      _sendingMedia = false;
    }
  }

  void showReplyInput(String parentId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return AnimatedPadding(
          duration: const Duration(milliseconds: 200),
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: SafeArea(
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: CommentInputBar(
                controller: _commentCtrl,
                pendingImage: _pendingImageFile,
                onRemoveImage: _clearPendingImage,
                onSend: () {
                  Navigator.pop(context);
                  sendComment(parentId: parentId);
                },
                onPickImage: () {
                  _pickImage();
                },
              ),
            ),
          ),
        );
      },
    );
  }

  List<CommentNode> buildCommentTree(List<Map<String, dynamic>> comments) {
    final Map<String, CommentNode> map = {};
    for (final c in comments) {
      final id = c['id']?.toString();
      if (id == null || id.isEmpty) continue;
      map[id] = CommentNode(c);
    }

    final List<CommentNode> roots = [];
    for (final node in map.values) {
      final pid = node.parentId;
      if (pid != null && map.containsKey(pid)) {
        map[pid]!.children.add(node);
      } else {
        roots.add(node);
      }
    }
    return roots;
  }

  int countDirectReplies(CommentNode node) => node.children.length;
  int countAllReplies(CommentNode node) {
    int count = 0;
    for (final child in node.children) {
      count += 1;
      count += countAllReplies(child);
    }
    return count;
  }

  List<VisibleComment> flattenTree(
      List<CommentNode> roots, Map<String, bool> expanded) {
    final List<VisibleComment> out = [];

    void addAllDescendants(CommentNode node, int level) {
      for (final child in node.children) {
        out.add(VisibleComment(child, level));
        addAllDescendants(child, level + 1);
      }
    }

    for (final root in roots) {
      out.add(VisibleComment(root, 0));
      if (expanded[root.id] == true) {
        addAllDescendants(root, 1);
      }
    }
    return out;
  }

  void toggleExpand(String id) {
    setState(() {
      expandedById[id] = !(expandedById[id] ?? false);
    });
  }

  void resetExpandState() {
    expandedById = {};
  }

  int _totalCount() => _allComments.length;

  List<CommentNode> _sortedRoots() {
    final list = List<CommentNode>.from(_roots);
    if (_sortMode == CommentSortMode.recent) {
      list.sort((a, b) {
        final da = DateTime.tryParse(a.comment['created_at']?.toString() ?? '');
        final db = DateTime.tryParse(b.comment['created_at']?.toString() ?? '');
        return (db ?? DateTime(1970))
            .compareTo(da ?? DateTime(1970));
      });
      return list;
    }
    int score(CommentNode n) {
      final likes = n.comment['likes_count'] ?? n.comment['likes'] ?? 0;
      final likeCount =
          likes is int ? likes : int.tryParse(likes.toString()) ?? 0;
      return likeCount + countAllReplies(n);
    }
    list.sort((a, b) => score(b).compareTo(score(a)));
    return list;
  }

  void _openSortSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Pertinence'),
                leading: Icon(
                  _sortMode == CommentSortMode.relevance
                      ? Icons.check
                      : Icons.sort,
                ),
                onTap: () {
                  setState(() => _sortMode = CommentSortMode.relevance);
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                title: const Text('Plus recents'),
                leading: Icon(
                  _sortMode == CommentSortMode.recent
                      ? Icons.check
                      : Icons.schedule,
                ),
                onTap: () {
                  setState(() => _sortMode = CommentSortMode.recent);
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _toggleLike(Map<String, dynamic> comment) async {
    final uid = user?.uid;
    final id = comment['id']?.toString();
    if (uid == null || id == null || id.isEmpty) return;
    final isLiked = _likedByMe.contains(id);
    debugPrint('toggle like: comment_id=$id user_id=$uid liked=$isLiked');
    final hasLikesCount = comment.containsKey('likes_count');
    final currentLikes = comment['likes_count'] ?? comment['likes'] ?? 0;
    final current = currentLikes is int
        ? currentLikes
        : int.tryParse(currentLikes.toString()) ?? 0;
    final next = isLiked ? (current - 1) : (current + 1);
    final newValue = next < 0 ? 0 : next;
    final key = hasLikesCount ? 'likes_count' : 'likes';

    setState(() {
      if (isLiked) {
        _likedByMe.remove(id);
      } else {
        _likedByMe.add(id);
      }
      for (final c in _allComments) {
        if (c['id']?.toString() == id) {
          c[key] = newValue;
          break;
        }
      }
      comment[key] = newValue;
    });
    try {
      if (isLiked) {
        final res = await supabase
            .from('comment_likes')
            .delete()
            .match({'comment_id': id, 'user_id': uid})
            .select('comment_id');
        debugPrint('comment_likes delete ok: $res');
      } else {
        final res = await supabase
            .from('comment_likes')
            .insert({'comment_id': id, 'user_id': uid})
            .select('comment_id');
        debugPrint('comment_likes insert ok: $res');
      }
      await supabase.from('comments').update({
        key: newValue,
      }).eq('id', id);
    } catch (e) {
      debugPrint('toggle like error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.85;
    final visibleItems = flattenTree(_sortedRoots(), expandedById);

    return AnimatedPadding(
      duration: const Duration(milliseconds: 200),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          height: height,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              CommentHeader(
                count: widget.initialCount ?? _totalCount(),
                onClose: () => Navigator.pop(context),
                onOpenSort: _openSortSheet,
              ),
              const Divider(height: 1),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : CommentList(
                        items: visibleItems,
                        expandedById: expandedById,
                        countDirectReplies: countAllReplies,
                        buildProfile: fetchUserProfile,
                        onReply: showReplyInput,
                        onToggleExpand: toggleExpand,
                        likedByMe: _likedByMe,
                        onLike: _toggleLike,
                      ),
              ),
              CommentInputBar(
                controller: _commentCtrl,
                pendingImage: _pendingImageFile,
                onRemoveImage: _clearPendingImage,
                onSend: () => sendComment(),
                onPickImage: () => _pickImage(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CommentHeader extends StatelessWidget {
  final int count;
  final VoidCallback onClose;
  final VoidCallback onOpenSort;

  const CommentHeader({
    super.key,
    required this.count,
    required this.onClose,
    required this.onOpenSort,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          const SizedBox(width: 32),
          Expanded(
            child: Center(
              child: Text(
                "$count commentaires",
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.sort),
            onPressed: onOpenSort,
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class CommentList extends StatelessWidget {
  final List<VisibleComment> items;
  final Map<String, bool> expandedById;
  final int Function(CommentNode node) countDirectReplies;
  final Future<Map<String, dynamic>?> Function(String userId) buildProfile;
  final void Function(String commentId) onReply;
  final void Function(String id) onToggleExpand;
  final Set<String> likedByMe;
  final void Function(Map<String, dynamic> comment) onLike;

  const CommentList({
    super.key,
    required this.items,
    required this.expandedById,
    required this.countDirectReplies,
    required this.buildProfile,
    required this.onReply,
    required this.onToggleExpand,
    required this.likedByMe,
    required this.onLike,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final node = item.node;
        final id = node.id;
        final level = item.level;
        final replyCount = countDirectReplies(node);
        final isExpanded = expandedById[id] == true;
        final isRoot = level == 0;

        return CommentItem(
          comment: node.comment,
          level: level,
          replyCount: replyCount,
          isExpanded: isExpanded,
          buildProfile: buildProfile,
          onReply: () => onReply(id),
          onToggleExpand:
              (isRoot && replyCount > 0) ? () => onToggleExpand(id) : null,
          isLiked: likedByMe.contains(id),
          onLike: () => onLike(node.comment),
        );
      },
    );
  }
}

class CommentItem extends StatelessWidget {
  final Map<String, dynamic> comment;
  final int level;
  final int replyCount;
  final bool isExpanded;
  final Future<Map<String, dynamic>?> Function(String userId) buildProfile;
  final VoidCallback onReply;
  final VoidCallback? onToggleExpand;
  final bool isLiked;
  final VoidCallback onLike;

  const CommentItem({
    super.key,
    required this.comment,
    required this.level,
    required this.replyCount,
    required this.isExpanded,
    required this.buildProfile,
    required this.onReply,
    required this.onToggleExpand,
    required this.isLiked,
    required this.onLike,
  });

  @override
  Widget build(BuildContext context) {
    final userId = comment['user_id']?.toString() ?? '';
    final content = comment['content']?.toString() ?? '';
    final createdAt = comment['created_at']?.toString();
    final isCreator = comment['is_creator'] == true;
    final likes = comment['likes_count'] ?? comment['likes'] ?? 0;
    final indent = 12.0 + (level * 16.0);

    return Padding(
      padding:
          EdgeInsets.only(left: indent, right: 12, top: 8, bottom: 8),
      child: FutureBuilder<Map<String, dynamic>?>(
        future: buildProfile(userId),
        builder: (context, snapshot) {
          final profile = snapshot.data;
          final username = profile?['username'] ?? 'Utilisateur';
          final avatarUrl = profile?['avatar_url'];

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                child: CircleAvatar(
                  radius: 16,
                  backgroundImage:
                      avatarUrl != null ? NetworkImage(avatarUrl) : null,
                  backgroundColor: Colors.grey.shade300,
                  child: avatarUrl == null
                      ? const Icon(Icons.person,
                          size: 18, color: Colors.black54)
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          username,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.black,
                          ),
                        ),
                        if (isCreator)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text(
                              "Créateur",
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.black54,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    _buildCommentContent(content),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          _formatTime(createdAt),
                          style:
                              const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                        const SizedBox(width: 12),
                        GestureDetector(
                          onTap: onReply,
                          child: const Text(
                            "Répondre",
                            style: TextStyle(
                                color: Colors.grey, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                    if (replyCount > 0 && onToggleExpand != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: GestureDetector(
                          onTap: onToggleExpand,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                isExpanded
                                    ? "Masquer les réponses"
                                    : "Voir $replyCount réponse(s)",
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 12),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                isExpanded
                                    ? Icons.keyboard_arrow_up
                                    : Icons.keyboard_arrow_down,
                                size: 16,
                                color: Colors.grey,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Column(
                children: [
                  GestureDetector(
                    onTap: onLike,
                    child: Icon(
                      isLiked ? Icons.favorite : Icons.favorite_border,
                      size: 18,
                      color:
                          isLiked ? Colors.lightBlueAccent : Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    likes.toString(),
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class CommentInputBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback? onPickImage;
  final File? pendingImage;
  final VoidCallback? onRemoveImage;

  const CommentInputBar({
    super.key,
    required this.controller,
    required this.onSend,
    this.onPickImage,
    this.pendingImage,
    this.onRemoveImage,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Colors.grey.shade300)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pendingImage != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        pendingImage!,
                        height: 120,
                        width: 180,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: onRemoveImage,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.all(4),
                          child:
                              const Icon(Icons.close, size: 16, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    style: const TextStyle(color: Colors.black, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: "Ajouter un commentaire???",
                      hintStyle: const TextStyle(color: Colors.grey),
                      filled: true,
                      fillColor: Colors.grey.shade100,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: onPickImage,
                            child: const Icon(Icons.image_outlined,
                                size: 20, color: Colors.black54),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    final canSend =
                        value.text.trim().isNotEmpty || pendingImage != null;
                    return IconButton(
                      icon: Icon(Icons.send,
                          color: canSend ? Colors.blueAccent : Colors.grey),
                      onPressed: canSend ? onSend : null,
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatTime(String? raw) {
  if (raw == null) return "";
  DateTime? date;
  try {
    date = DateTime.parse(raw);
  } catch (_) {
    return "";
  }
  final now = DateTime.now();
  final diff = now.difference(date);
  if (diff.inMinutes < 1) return "à l’instant";
  if (diff.inMinutes < 60) return "${diff.inMinutes} min";
  if (diff.inHours < 24) return "${diff.inHours} h";
  return "${diff.inDays} j";
}

Widget _buildCommentContent(String content) {
  final c = content.trim();
  if (c.isEmpty) return const SizedBox.shrink();
  final regex = RegExp(r'(https?:\/\/\S+\.(?:jpg|jpeg|png|webp|gif))',
      caseSensitive: false);
  final match = regex.firstMatch(c);
  String? url;
  String text = c;
  if (match != null) {
    url = match.group(0);
    if (url != null) {
      text = c.replaceAll(url, '').trim();
    }
  }
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (url != null)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(
              url!,
              height: 140,
              width: 180,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Text(
                "Image indisponible",
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          ),
        ),
      if (text.isNotEmpty)
        Text(
          text,
          style: const TextStyle(
            color: Colors.black87,
            fontSize: 14,
          ),
        ),
    ],
  );
}
