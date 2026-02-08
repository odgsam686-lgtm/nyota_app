// lib/models/chat_message.dart
import 'package:hive/hive.dart';

part 'chat_message.g.dart';

@HiveType(typeId: 2)
class ChatMessageHive extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String chatId;

  @HiveField(2)
  String senderId;

  @HiveField(3)
  String receiverId;

  @HiveField(4)
  String text;

  @HiveField(5)
  String? mediaLocalPath;

  @HiveField(6)
  String? mediaRemoteUrl;

  @HiveField(7)
  int timestamp; // epoch millis

  ChatMessageHive({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.receiverId,
    this.text = '',
    this.mediaLocalPath,
    this.mediaRemoteUrl,
    int? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
        'id': id,
        'chatId': chatId,
        'senderId': senderId,
        'receiverId': receiverId,
        'text': text,
        'mediaRemoteUrl': mediaRemoteUrl ?? '',
        'timestamp': timestamp,
      };

  factory ChatMessageHive.fromMap(Map<String, dynamic> m) {
    return ChatMessageHive(
      id: m['id'] ?? '',
      chatId: m['chatId'] ?? '',
      senderId: m['senderId'] ?? '',
      receiverId: m['receiverId'] ?? '',
      text: m['text'] ?? '',
      mediaLocalPath: m['mediaLocalPath'],
      mediaRemoteUrl: m['mediaRemoteUrl'],
      timestamp: m['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
    );
  }
}
