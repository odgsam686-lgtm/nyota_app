import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';

class HiveHelper {
  static Box? _conversationsBox;
  static Box? _draftsBox;

  /// Initialisation de Hive et ouverture de la box
  static Future<void> initHive() async {
    await Hive.initFlutter();
    _conversationsBox = await Hive.openBox('conversationsList');
    _draftsBox = await Hive.openBox('draftsBox');
  }

  /// Getter pour accéder à la box
  static Box get conversationsBox {
    if (_conversationsBox == null) {
      throw Exception('Hive n\'a pas encore été initialisé');
    }
    return _conversationsBox!;
  }

  /// Getter pour accéder à la box des brouillons
  static Box get draftsBox {
    if (_draftsBox == null) {
      throw Exception('Hive n\'a pas encore initialisé');
    }
    return _draftsBox!;
  }
}
