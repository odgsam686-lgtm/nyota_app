import 'package:hive/hive.dart';
import '../hive_helper.dart';

class ChatStorage {
  static Box get _box => HiveHelper.conversationsBox;

  /// Sauvegarder un message dans une conversation
  static Future<void> saveMessage(String conversationId, Map<String, dynamic> message) async {
    List messages = _box.get(conversationId, defaultValue: []);
    messages.add(message);
    await _box.put(conversationId, messages);
  }

  /// Récupérer tous les messages d'une conversation
  static List getMessages(String conversationId) {
    return _box.get(conversationId, defaultValue: []);
  }

  /// Supprimer une conversation complète
  static Future<void> deleteConversation(String conversationId) async {
    await _box.delete(conversationId);
  }
}
