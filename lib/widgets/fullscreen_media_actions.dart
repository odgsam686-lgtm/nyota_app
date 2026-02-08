import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// ===============================
/// 🔥 COLONNE ACTIONS PLEIN ÉCRAN
/// ===============================
class FullScreenMediaActions extends StatelessWidget {
  final String postId;
  final String sellerId;
  final String? avatarUrl;

  final int likesCount;
  final int commentsCount;
  final bool isLiked;

  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onOpenProfile;

  const FullScreenMediaActions({
    super.key,
    required this.postId,
    required this.sellerId,
    required this.likesCount,
    required this.commentsCount,
    required this.isLiked,
    required this.onLike,
    required this.onComment,
    required this.onOpenProfile,
    this.avatarUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 12,
      top: MediaQuery.of(context).size.height * 0.25,

      /// 🔥 AJOUT : DOUBLE TAP = LIKE
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onDoubleTap: onLike,

        child: Column(
          children: [
            /// 👤 PROFIL PUBLIC + FOLLOW
            Stack(
              alignment: Alignment.bottomCenter,
              children: [
                GestureDetector(
                  onTap: onOpenProfile,
                  child: CircleAvatar(
                    radius: 26,
                    backgroundImage: avatarUrl != null && avatarUrl!.isNotEmpty
                        ? NetworkImage(avatarUrl!)
                        : const AssetImage("assets/images/avatar.png")
                            as ImageProvider,
                  ),
                ),
                Positioned(
                  bottom: -6,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.add,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            /// ❤️ LIKE
            _LikeButton(
              isLiked: isLiked,
              likesCount: likesCount,
              onTap: onLike,
            ),

            const SizedBox(height: 16),

            /// 💬 COMMENTAIRE
            _CommentButton(
              commentsCount: commentsCount,
              onTap: onComment,
            ),
          ],
        ),
      ),
    );
  }
}

/// ===============================
/// ❤️ LIKE BUTTON
/// ===============================
class _LikeButton extends StatefulWidget {
  final bool isLiked;
  final int likesCount;
  final VoidCallback onTap;

  const _LikeButton({
    required this.isLiked,
    required this.likesCount,
    required this.onTap,
  });

  @override
  State<_LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends State<_LikeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );

    _scale = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
  }

  @override
  void didUpdateWidget(covariant _LikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLiked && !oldWidget.isLiked) {
      _controller.forward().then((_) => _controller.reverse());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ScaleTransition(
          scale: _scale,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onTap,
            child: Icon(
              Icons.favorite,
              color: widget.isLiked ? Colors.red : Colors.white,
              size: 36,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          widget.likesCount.toString(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// ===============================
/// 💬 COMMENT BUTTON
/// ===============================
class _CommentButton extends StatelessWidget {
  final int commentsCount;
  final VoidCallback onTap;

  const _CommentButton({
    required this.commentsCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: SvgPicture.asset(
            'assets/icons/comment.svg',
            width: 32,
            height: 32,
            colorFilter: const ColorFilter.mode(
              Color(0xFFB0B0B0),
              BlendMode.srcIn,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          commentsCount.toString(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
