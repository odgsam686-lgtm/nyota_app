// main.dart
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nyota_app/pages/public_profile_page.dart';
import 'package:nyota_app/services/deep_link_services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'settings_page.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'offline/offline_manager.dart';
import 'offline/offline_manager.dart'as legacy; // DraftOfflineManager
import 'offline_manager.dart'; // legacy OfflineManager for products
import 'models/product_hive.dart';
import 'hive_helper.dart';
import 'package:nyota_app/conversations_list_screen.dart';
import 'pages/feed_page.dart';
import 'pages/catalogue_page.dart';
import 'pages/profil_page.dart';
import 'pages/cart_page.dart';
import 'pages/wallet_page.dart';
import 'pages/seller_profile_page.dart';
import 'pages/comments_page.dart';
import 'pages/product_page.dart';
import 'pages/add_post_page.dart';
import 'package:nyota_app/pages/home_page_with_online_status.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;
import 'package:nyota_app/pages/forgot_password_phone_page.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

void main() async {
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  widgetsBinding.addObserver(LifecycleEventHandler(
    resumeCallBack: () async {},
  ));
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  await Hive.initFlutter();
  await Hive.openBox('cacheBox');
  await HiveHelper.initHive();

  _initOfflineFlushListener();

  await setupFCM();

  // Test Hive
  var box = HiveHelper.conversationsBox;
  box.put('user1', 'Bonjour');
  print(box.get('user1'));

  // SUPABASE
  await supa.Supabase.initialize(
    url: 'https://uczycvteyfgdhfjeuglw.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVjenljdnRleWZnZGhmamV1Z2x3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjMxMzA1NzMsImV4cCI6MjA3ODcwNjU3M30.4KVurTgyZRaqox9q0NcS0G9_zX5TADsDE4hw8BUhI5E',
  );

  runApp(const MyApp());
}

void _initOfflineFlushListener() {
  bool wasOffline = false;
  final connectivity = Connectivity();

  connectivity.onConnectivityChanged.listen((result) {
    if (result == ConnectivityResult.none) {
      wasOffline = true;
      return;
    }

    if (wasOffline) {
      DraftOfflineManager.flushQueuedDrafts();
      wasOffline = false;
    }
  });
}

Future<void> setupFCM() async {
  FirebaseMessaging messaging = FirebaseMessaging.instance;

  await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );

  // Listener des notifications en premier plan
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    if (message.notification != null) {
      print('Notification reçue: ${message.notification!.title}');
    }
  });

  // Listener quand on ouvre une notification
  FirebaseMessaging.onMessageOpenedApp.listen((message) {
    print('Notification ouverte: ${message.notification?.title}');
  });

  // 🔥 Le token doit être protégé
  try {
    String? token = await messaging.getToken();
    print('FCM Token: $token');
  } catch (e) {
    print("⚠️ Impossible d'obtenir le token FCM : $e");
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: [routeObserver],
      title: 'Nyota',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.deepPurple),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasData) {
            return KeyedSubtree(
              key: ValueKey(snapshot.data!.uid), // ✅ FORCE la reconstruction
              child: HomePage(user: snapshot.data!),
            );
          } else {
            return const LoginPage();
          }
        },
      ),
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/seller':
            final sellerId = settings.arguments as String;
            return MaterialPageRoute(
              builder: (_) => SellerProfilePage(sellerId: sellerId),
            );

          case '/comments':
            final postId = settings.arguments as String;
            return MaterialPageRoute(
              builder: (_) => CommentsPage(postId: postId),
            );

          case '/product':
            final data = settings.arguments as Map<String, dynamic>;
            return MaterialPageRoute(
              builder: (_) => ProductPage(data: data),
            );

          case '/addPost':
            return MaterialPageRoute(
              builder: (_) => const AddPostPage(),
            );

          case '/messages':
            return MaterialPageRoute(
              builder: (_) => ConversationsListScreen(
                currentUserId: FirebaseAuth.instance.currentUser!.uid,
              ),
            );
          case '/publicProfile':
            final sellerId = settings.arguments as String;
            return MaterialPageRoute(
              builder: (_) => PublicProfilePage(sellerId: sellerId),
            );

          default:
            return null;
        }
      },
    );
  }
}

class HomePageWithOnlineStatus extends StatefulWidget {
  final User user;
  const HomePageWithOnlineStatus({Key? key, required this.user})
      : super(key: key);

  @override
  _HomePageWithOnlineStatusState createState() =>
      _HomePageWithOnlineStatusState();
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
    await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.user.uid)
        .update({
      'online': isOnline,
      'lastSeen': FieldValue.serverTimestamp(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nyota - Utilisateurs'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('users').snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final users = snapshot.data!.docs
              .where((doc) => doc.id != widget.user.uid)
              .toList();

          return ListView.builder(
            itemCount: users.length,
            itemBuilder: (context, index) {
              final userDoc = users[index];
              final data = Map<String, dynamic>.from(userDoc.data() as Map);
              final isOnline = data['online'] ?? false;

              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: isOnline ? Colors.green : Colors.grey,
                  radius: 8,
                ),
                title: Text(data['name'] ?? 'Utilisateur'),
                subtitle: Text(isOnline
                    ? 'En ligne'
                    : 'Dernière connexion : ${data['lastSeen'] != null ? (data['lastSeen'] as Timestamp).toDate() : 'Inconnue'}'),
                onTap: () {
                  // Ici tu peux naviguer vers la page de chat
                },
              );
            },
          );
        },
      ),
    );
  }
}

// =================== LOGIN PAGE ===================
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController emailCtrl = TextEditingController();
  final TextEditingController passCtrl = TextEditingController();
  bool enableForgotPassword = false; // 🔒 désactivé pour l’instant
  bool isLoading = false;
  bool obscure = true;

  Future<void> _login() async {
    final email = emailCtrl.text.trim();
    final pass = passCtrl.text;

    if (email.isEmpty || pass.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Email et mot de passe requis')),
      );
      return;
    }

    setState(() => isLoading = true);

   try {
  print('🟡 STEP 1 : Début login');

  // 1) Login Firebase
  final userCred = await FirebaseAuth.instance
      .signInWithEmailAndPassword(email: email, password: pass);

  print('🟢 STEP 2 : Firebase login OK');

  final firebaseUser = userCred.user;
  if (firebaseUser == null) {
    throw Exception("Utilisateur Firebase nul");
  }

  final uid = firebaseUser.uid;
  print('🟢 STEP 3 : UID Firebase = $uid');

  // 🔥 TOKEN
  final firebaseIdToken = await firebaseUser.getIdToken();
  print('🟢 STEP 4 : Token Firebase récupéré');

  // 2) Appel Edge Function
  final res = await supa.Supabase.instance.client.functions.invoke(
  'verify-firebase-token',
  headers: {
    'Authorization': 'Bearer $firebaseIdToken',
  },
);

print('🔥 Edge status = ${res.status}');
print('🔥 Edge data = ${res.data}');

if (res.status != 200) {
  throw Exception('Edge Function error (status ${res.status})');
}


  print('🟢 STEP 6 : Edge OK');

  // 3) USERS
  final row = await supa.Supabase.instance.client
      .from('users')
      .select()
      .eq('firebase_uid', uid)
      .maybeSingle();

  print('🟡 STEP 7 : Vérif users');

  if (row == null) {
    await supa.Supabase.instance.client.from('users').insert({
      'firebase_uid': uid,
      'email': email,
      'first_name': '',
      'last_name': '',
      'phone': '',
      'address': '',
      'is_seller': false,
    });
    print('🟢 STEP 8 : User créé');
  }

  // 4) PROFIL PUBLIC
  final publicProfile = await supa.Supabase.instance.client
      .from('public_profiles')
      .select()
      .eq('user_id', uid)
      .maybeSingle();

  print('🟡 STEP 9 : Vérif public_profiles');

  if (publicProfile == null) {
    await supa.Supabase.instance.client.from('public_profiles').insert({
      'user_id': uid,
      'username': email.split('@')[0],
      'avatar_url': null,
      'bio': '',
      'is_seller': false,
    });
    print('🟢 STEP 10 : Profil public créé');
  }

  print('🟢 STEP 11 : Navigation');

  Navigator.pushReplacement(
    context,
    MaterialPageRoute(
      builder: (_) => HomePage(user: firebaseUser),
    ),
  );
}catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Erreur : $e")));
    } finally {
      setState(() => isLoading = false);
    }
  }

  void _forgotPassword() {
    final controller = TextEditingController(text: emailCtrl.text.trim());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mot de passe oublié'),
        content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Entrez votre email')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler')),
          ElevatedButton(
            onPressed: () async {
              final e = controller.text.trim();
              if (e.isEmpty) return;
              Navigator.pop(ctx);
              try {
                await FirebaseAuth.instance.sendPasswordResetEmail(email: e);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Email de réinitialisation envoyé')));
              } on FirebaseAuthException catch (err) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(err.message ?? 'Erreur')));
              }
            },
            child: const Text('Envoyer'),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const bgColor = Color(0xFF0B1C2D); // bleu nuit
    const gold = Color(0xFFD4AF37);
    const cardColor = Color(0xFFEFE6D8); // vieux parchemin

    InputDecoration deco(String label, IconData icon, {Widget? suffix}) {
      return InputDecoration(
        prefixIcon: Icon(icon, color: gold, size: 20),
        suffixIcon: suffix,
        labelText: label,
        labelStyle: const TextStyle(
          color: Color(0xFF5A4A2F),
          fontWeight: FontWeight.w500,
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 0),
        border: InputBorder.none,
      );
    }

    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          // 🌌 FOND
          Positioned.fill(
            child: Image.asset(
              'assets/images/gold_dust.png',
              fit: BoxFit.cover,
            ),
          ),

          SafeArea(
            child: Stack(
              children: [
                // ⭐ LOGO (NE BOUGE PAS)
                Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: Image.asset(
                      'assets/images/nyota_logo.png',
                      height: 220, // garde ta taille
                      fit: BoxFit.contain,
                    ),
                  ),
                ),

                // 🧾 CARTE BLANCHE (ON LA FAIT JUSTE MONTER)
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 80, // 🔥 ICI TU AJUSTES (ex: 60, 70, 90)
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      children: [
                        TextField(
                          controller: emailCtrl,
                          decoration: deco('Email', Icons.email),
                          keyboardType: TextInputType.emailAddress,
                        ),
                        const Divider(),
                        TextField(
                          controller: passCtrl,
                          obscureText: obscure,
                          decoration: deco(
                            'Mot de passe',
                            Icons.lock,
                            suffix: IconButton(
                              icon: Icon(
                                obscure
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                size: 20,
                                color: Colors.black54,
                              ),
                              onPressed: () =>
                                  setState(() => obscure = !obscure),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (enableForgotPassword)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const ForgotPasswordPhonePage(),
                                  ),
                                );
                              },
                              child: const Text(
                                'Mot de passe oublié ?',
                                style: TextStyle(
                                  color: Color(0xFF5A4A2F),
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 16),
                        isLoading
                            ? const CircularProgressIndicator()
                            : SizedBox(
                                width: double.infinity,
                                height: 48,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: gold,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(30),
                                    ),
                                  ),
                                  onPressed: _login,
                                  child: const Text(
                                    'Se connecter',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.black,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const RegisterPage()),
                          ),
                          child: const Text(
                            'Créer un compte',
                            style: TextStyle(
                              color: Color(0xFF5A4A2F),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =================== REGISTER PAGE ===================
class RegisterPage extends StatefulWidget {
  const RegisterPage({Key? key}) : super(key: key);

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();

  final firstCtrl = TextEditingController();
  final lastCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  final addressCtrl = TextEditingController();
  final emailCtrl = TextEditingController();
  final passCtrl = TextEditingController();

  final FocusNode emailFocus = FocusNode();

  bool obscure = true;
  bool isLoading = false;

  List<String> emailSuggestions = [];

  // 🎨 Couleurs Nyota
  static const bgColor = Color(0xFF0B1C2D);
  static const gold = Color(0xFFD4AF37);
  static const parchment = Color(0xFFEFE6D8);
  static const parchmentTitle = Color(0xFFD8CBB5);

  @override
  void initState() {
    super.initState();

    emailFocus.addListener(() {
      if (emailFocus.hasFocus) {
        _generateEmailSuggestions();
      } else {
        setState(() => emailSuggestions = []);
      }
    });
  }

  void _generateEmailSuggestions() {
    if (emailCtrl.text.trim().isNotEmpty) return;

    final first = firstCtrl.text.trim().toLowerCase();
    final last = lastCtrl.text.trim().toLowerCase();

    if (first.isEmpty || last.isEmpty) {
      setState(() => emailSuggestions = []);
      return;
    }

    final seed = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      emailSuggestions = [
        '$first.$last${seed % 100}@gmail.com',
        '${first[0]}$last${seed % 1000}@gmail.com',
        '$last.$first${(seed ~/ 7) % 100}@gmail.com',
      ];
    });
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => isLoading = true);
    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: emailCtrl.text.trim(),
        password: passCtrl.text,
      );

      final uid = cred.user!.uid;

      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'firstName': firstCtrl.text.trim(),
        'lastName': lastCtrl.text.trim(),
        'phone': phoneCtrl.text.trim(),
        'address': addressCtrl.text.trim(),
        'email': emailCtrl.text.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });

      await supa.Supabase.instance.client.from('users').insert({
        'firebase_uid': uid,
        'first_name': firstCtrl.text.trim(),
        'last_name': lastCtrl.text.trim(),
        'phone': phoneCtrl.text.trim(),
        'address': addressCtrl.text.trim(),
        'email': emailCtrl.text.trim(),
        'is_seller': false,
      });

      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur : $e')),
      );
    } finally {
      setState(() => isLoading = false);
    }
  }

  InputDecoration _decoration(String label, IconData icon, {Widget? suffix}) {
    return InputDecoration(
      prefixIcon: Padding(
        padding: const EdgeInsets.only(left: 6, right: 6),
        child: Icon(
          icon,
          color: gold,
          size: 18,
        ),
      ),
      prefixIconConstraints: const BoxConstraints(
        minWidth: 34,
      ),

      suffixIcon: suffix,

      // 🟡 TEXTE PLUS PRONONCÉ
      labelText: label,
      labelStyle: const TextStyle(
        color: Colors.black87, // 🔥 plus visible
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),

      // 🟡 TEXTE SAISI PLUS LISIBLE
      floatingLabelStyle: const TextStyle(
        color: Colors.black87,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),

      isDense: true,

      // 🔥🔥 ESPACES ULTRA CONTRÔLÉS (traits rapprochés)
      contentPadding: const EdgeInsets.only(
        top: 4,
        bottom: 4,
      ),

      border: InputBorder.none,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Stack(
          children: [
            // 🌌 Fond bleu
            Container(color: bgColor),

            // ✨ Poussière dorée
            Positioned.fill(
              child: Opacity(
                opacity: 0.35, // 👈 important (augmente si besoin)
                child: Image.asset(
                  'assets/images/gold_dust.png',
                  fit: BoxFit.cover,
                ),
              ),
            ),

            // 📦 Contenu principal
            SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
              child: Column(
                children: [
                  const SizedBox(height: 50),
                  const Text(
                    'Inscription',
                    style: TextStyle(
                      color: parchmentTitle,
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5, // touche luxe
                    ),
                  ),

                  const SizedBox(height: 40),

                  // 🧱 Carte
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: parchment, // 👈 blanc sale
                      borderRadius: BorderRadius.circular(26),
                    ),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          TextFormField(
                            controller: firstCtrl,
                            decoration: _decoration('Prénom', Icons.person),
                            validator: (v) => v!.isEmpty ? 'Obligatoire' : null,
                          ),
                          const Divider(),

                          TextFormField(
                            controller: lastCtrl,
                            decoration:
                                _decoration('Nom', Icons.person_outline),
                            validator: (v) => v!.isEmpty ? 'Obligatoire' : null,
                          ),
                          const Divider(color: Colors.black26),

                          TextFormField(
                            controller: phoneCtrl,
                            decoration: _decoration('Téléphone', Icons.phone),
                            validator: (v) => v!.isEmpty ? 'Obligatoire' : null,
                          ),
                          const Divider(color: Colors.black26),

                          TextFormField(
                            controller: addressCtrl,
                            decoration:
                                _decoration('Adresse', Icons.location_on),
                            validator: (v) => v!.isEmpty ? 'Obligatoire' : null,
                          ),
                          const Divider(color: Colors.black26),

                          TextFormField(
                            controller: emailCtrl,
                            focusNode: emailFocus,
                            decoration: _decoration('Email', Icons.email),
                            validator: (v) => v!.isEmpty ? 'Obligatoire' : null,
                          ),

                          // ✨ Suggestions email
                          if (emailSuggestions.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Column(
                              children: emailSuggestions.map((e) {
                                return Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 4),
                                  child: InkWell(
                                    onTap: () {
                                      emailCtrl.text = e;
                                      emailFocus.unfocus();
                                      setState(() => emailSuggestions = []);
                                    },
                                    child: Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 10, horizontal: 14),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(18),
                                      ),
                                      child: Text(
                                        e,
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],

                          const Divider(color: Colors.black26),

                          TextFormField(
                            controller: passCtrl,
                            obscureText: obscure,
                            decoration: _decoration(
                              'Mot de passe',
                              Icons.lock,
                              suffix: IconButton(
                                icon: Icon(
                                  obscure
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                  color: Colors.black45,
                                ),
                                onPressed: () =>
                                    setState(() => obscure = !obscure),
                              ),
                            ),
                            validator: (v) =>
                                v!.length < 4 ? 'Trop court' : null,
                          ),

                          const SizedBox(height: 26),

                          isLoading
                              ? const CircularProgressIndicator()
                              : SizedBox(
                                  width: double.infinity,
                                  height: 52,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: gold,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(30),
                                      ),
                                    ),
                                    onPressed: _register,
                                    child: const Text(
                                      'Créer mon compte',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: Colors.black,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),

                          const SizedBox(height: 14),

                          const Text(
                            'Gratuit • Sécurisé • Annulable à tout moment',
                            style:
                                TextStyle(fontSize: 12, color: Colors.black54),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =================== MODELS ===================
class Product {
  String id;
  String name;
  File? media;
  double price;
  bool isVideo;
  double? latitude;
  double? longitude;
  bool isPromo;
  bool isTrending;

  Product({
    required this.id,
    required this.name,
    this.media,
    this.price = 0.0,
    this.isVideo = false,
    this.latitude,
    this.longitude,
    this.isPromo = false,
    this.isTrending = false,
  });
}

class TransactionModel {
  String description;
  double amount;
  DateTime date;

  TransactionModel(
      {required this.description, required this.amount, required this.date});
}

// =================== HOME PAGE ===================
class HomePage extends StatefulWidget {
  final User user;
  const HomePage({Key? key, required this.user}) : super(key: key);

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  Position? userPosition;
  Map<String, dynamic>? userData;
  bool isLoading = true;

  List<Product> feedProducts = List.generate(
    15,
    (i) => Product(
      id: 'p$i',
      name: 'Produit ${i + 1}',
      price: (i + 1) * 5.0,
      isPromo: i % 4 == 0,
      isTrending: i % 5 == 0,
      latitude: 12.34 + i * 0.01,
      longitude: -1.23 + i * 0.01,
    ),
  );

  List<Product> products = [];
  List<Product> drafts = [];
  List<Product> cart = [];
  double walletBalance = 50.0;
  List<TransactionModel> transactions = [];

  int pointsFidelite = 0;
  int commandesRecues = 0;
  int commandesEnAttente = 0;
  int commandesNonRecues = 0;

  int _currentIndex = 0;
  String searchQuery = '';
  bool isSeller = false;

  final ImagePicker _picker = ImagePicker();
  final DeepLinkService _deepLinkService =DeepLinkService();

  @override
  void initState() {
    super.initState();
    _loadUserData();
    _getUserLocation();
    _deepLinkService.init(context);
    // charger les produits locaux immédiatement (si box contient)
    final localProducts = legacy.OfflineManager.getLocalProducts();
    if (localProducts.isNotEmpty) {
      setState(() {
        // convertir ProductHive -> Product (ton modèle existant)
        feedProducts = localProducts
            .map((ph) => Product(
                  id: ph.id,
                  name: ph.name,
                  media: ph.localMediaPath != null
                      ? File(ph.localMediaPath!)
                      : null,
                  price: ph.price,
                  isVideo: ph.isVideo,
                  latitude: ph.latitude,
                  longitude: ph.longitude,
                  isPromo: ph.isPromo,
                  isTrending: ph.isTrending,
                ))
            .toList();
      });
    }

    // lance une sync en tâche de fond (si connecté)
    legacy.OfflineManager.syncProductsWithFirestore()
        .catchError((e) => debugPrint('Sync err: $e'));
  }

  Future<void> _loadUserData() async {
    try {
      DocumentSnapshot doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.user.uid)
          .get();
      if (doc.exists) userData = doc.data() as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Erreur chargement user: $e');
    } finally {
      setState(() => isLoading = false);
    }
  }

  Future<void> _getUserLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied)
        permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.deniedForever) return;

      Position pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      setState(() => userPosition = pos);
    } catch (e) {
      debugPrint('Erreur localisation: $e');
    }
  }

  double _distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const double R = 6371;
    double dLat = (lat2 - lat1) * pi / 180;
    double dLon = (lon2 - lon1) * pi / 180;
    double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLon / 2) *
            sin(dLon / 2);
    double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  Future<List<Product>> getUserFeed() async {
    List<Product> local = [];
    List<Product> promos = [];
    List<Product> trending = [];
    List<Product> others = [];

    for (var p in feedProducts) {
      bool isLocal = false;
      if (userPosition != null && p.latitude != null && p.longitude != null) {
        double d = _distanceKm(userPosition!.latitude, userPosition!.longitude,
            p.latitude!, p.longitude!);
        if (d <= 10) isLocal = true;
      }

      if (isLocal)
        local.add(p);
      else if (p.isPromo)
        promos.add(p);
      else if (p.isTrending)
        trending.add(p);
      else
        others.add(p);
    }

    List<Product> finalFeed = [];
    finalFeed.addAll(local);
    finalFeed.addAll(promos);
    finalFeed.addAll(trending);
    finalFeed.addAll(others);
    return finalFeed;
  }

  // =================== PICK MEDIA ===================
  Future<void> _pickMediaAndAddDraft(
      {required bool fromCamera, required bool isVideo}) async {
    try {
      XFile? file;
      if (fromCamera) {
        file = isVideo
            ? await _picker.pickVideo(
                source: ImageSource.camera,
                maxDuration: const Duration(seconds: 60))
            : await _picker.pickImage(
                source: ImageSource.camera, maxWidth: 1920, maxHeight: 1080);
      } else {
        file = isVideo
            ? await _picker.pickVideo(source: ImageSource.gallery)
            : await _picker.pickImage(
                source: ImageSource.gallery, maxWidth: 1920, maxHeight: 1080);
      }

      if (file != null) {
        final f = File(file.path);
        setState(() {
          drafts.add(Product(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              name: 'Brouillon',
              media: f,
              isVideo: isVideo));
        });
      }
    } catch (e) {
      debugPrint('Erreur pick media: $e');
    }
  }

  void _openPickMediaModal() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Wrap(
        children: [
          ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Prendre une photo'),
              onTap: () {
                Navigator.pop(context);
                _pickMediaAndAddDraft(fromCamera: true, isVideo: false);
              }),
          ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('Filmer une vidéo'),
              onTap: () {
                Navigator.pop(context);
                _pickMediaAndAddDraft(fromCamera: true, isVideo: true);
              }),
          ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Importer depuis la galerie (photo)'),
              onTap: () {
                Navigator.pop(context);
                _pickMediaAndAddDraft(fromCamera: false, isVideo: false);
              }),
          ListTile(
              leading: const Icon(Icons.video_library),
              title: const Text('Importer depuis la galerie (vidéo)'),
              onTap: () {
                Navigator.pop(context);
                _pickMediaAndAddDraft(fromCamera: false, isVideo: true);
              }),
        ],
      ),
    );
  }

  void _publishDraft(Product draft) {
    final nameCtrl = TextEditingController(
        text: draft.name == 'Brouillon' ? '' : draft.name);
    final priceCtrl = TextEditingController(
        text: draft.price > 0 ? draft.price.toStringAsFixed(2) : '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Publier le brouillon'),
        content: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                  controller: nameCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Nom (optionnel)')),
              TextField(
                  controller: priceCtrl,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Prix (optionnel)')),
              const SizedBox(height: 8),
              const Text('Vous pouvez publier sans remplir les champs.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                final newProd = Product(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: 'Publication ${products.length + 1}',
                  media: draft.media,
                  price: 0.0,
                  isVideo: draft.isVideo,
                );
                products.insert(0, newProd);
                feedProducts.insert(0, newProd);
                drafts.removeWhere((d) => d.id == draft.id);
              });
              Navigator.pop(context);
            },
            child: const Text('Publier sans remplir'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          ElevatedButton(
            onPressed: () {
              final name = nameCtrl.text.trim().isEmpty
                  ? 'Publication ${products.length + 1}'
                  : nameCtrl.text.trim();
              final price = double.tryParse(priceCtrl.text.trim()) ?? 0.0;
              setState(() async {
                final newProd = Product(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: name,
                  media: draft.media,
                  price: price,
                  isVideo: draft.isVideo,
                );
                products.insert(0, newProd);
                feedProducts.insert(0, newProd);
                drafts.removeWhere((d) => d.id == draft.id);
                final ph = ProductHive(
                  id: newProd.id,
                  name: newProd.name,
                  localMediaPath: newProd.media?.path,
                  price: newProd.price,
                  isVideo: newProd.isVideo,
                  latitude: newProd.latitude,
                  longitude: newProd.longitude,
                  isPromo: newProd.isPromo,
                  isTrending: newProd.isTrending,
                );
                await legacy.OfflineManager.saveLocalProduct(ph);
                legacy.OfflineManager.syncProductsWithFirestore(); // fire & forget
              });
              Navigator.pop(context);
            },
            child: const Text('Publier'),
          ),
        ],
      ),
    );
  }

  void _deleteDraft(Product draft) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer le brouillon ?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Non')),
          ElevatedButton(
            onPressed: () {
              setState(() => drafts.removeWhere((d) => d.id == draft.id));
              Navigator.pop(context);
            },
            child: const Text('Oui, supprimer'),
          )
        ],
      ),
    );
  }

  void _shareProduct(Product p) async {
    if (p.media != null) {
      final fx = XFile(p.media!.path);
      try {
        await Share.shareXFiles([fx],
            text:
                'Regarde ce produit: ${p.name} - \$${p.price.toStringAsFixed(2)}');
      } catch (e) {
        // fallback
        await Share.share(
            'Regarde ce produit: ${p.name} - \$${p.price.toStringAsFixed(2)}');
      }
    } else {
      await Share.share(
          'Regarde ce produit: ${p.name} - \$${p.price.toStringAsFixed(2)}');
    }
  }

  // PLACE THIS INSIDE YOUR STATE CLASS (above build)
  List<Widget> tabs = [
    const FeedPage(),
    const CatalogPage(),
    const ProfilPage(),
    const CartPage(),
    const WalletPage(),
  ];

// =================== UI & NAV ===================
  int _bottomIndex = 0; // index VISUEL (0–2 seulement)

  int _mapBottomIndexToPage(int index) {
    switch (index) {
      case 0:
        return 0; // Accueil
      case 1:
        return 1; // Catalogue
      case 2:
        return 2; // Profil
      default:
        return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _currentIndex == 0
              ? 'Accueil'
              : _currentIndex == 4
                  ? 'Solde'
                  : 'Nyota',
        ),
     
      ),
      body: _getBody(),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: Colors.white,
        selectedItemColor: Colors.deepPurple,
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        currentIndex: _bottomIndex,
        onTap: (index) {
          setState(() {
            _bottomIndex = index;
            _currentIndex = _mapBottomIndexToPage(index);
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Accueil',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.store),
            label: 'Catalogue',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Profil',
          ),
        ],
      ),
      floatingActionButton: Stack(
        children: [
          if (_currentIndex == 0 || _currentIndex == 2)
            Positioned(
              bottom: 16,
              right: 16,
              child: FloatingActionButton(
                heroTag: 'chatBtn',
                onPressed: _openConversationsList,
                child: const Icon(Icons.chat),
                tooltip: 'Mes messages',
              ),
            ),
          if (_currentIndex == 2)
            FloatingActionButton(
              heroTag: 'mediaBtn',
              onPressed: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AddPostPage()),
                );

                // ✅ RAFRAÎCHIT AUTOMATIQUEMENT PUBLICATIONS + BROUILLONS
                if (result == true) {
                  setState(() {});
                }
              },
              child: const Icon(Icons.add_a_photo),
              tooltip: 'Prendre / importer (brouillon)',
            ),
        ],
      ),
    );
  }

 

  // ✅ Et ici on déclare la fonction, en dehors du build, mais dans la classe
  void _openConversationsList() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ConversationsListScreen(
          currentUserId: FirebaseAuth.instance.currentUser!.uid,
        ),
      ),
    );
  }

  Widget _getBody() {
    switch (_currentIndex) {
      case 0:
        return const FeedPage();
      case 1:
        return const CatalogPage();
      case 2:
        return const ProfilPage();
      case 3:
        return _buildCart();
      case 4:
        return _buildWallet();
      default:
        return const FeedPage();
    }
  }

  // =================== FEED ===================
  Widget _buildFeed() {
    return FutureBuilder<List<Product>>(
      future: getUserFeed(),
      builder: (context, snapshot) {
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final filtered = snapshot.data!
            .where(
                (p) => p.name.toLowerCase().contains(searchQuery.toLowerCase()))
            .toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextField(
                decoration: const InputDecoration(
                    labelText: 'Rechercher', prefixIcon: Icon(Icons.search)),
                onChanged: (v) => setState(() => searchQuery = v),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final p = filtered[index];
                  return Card(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: ListTile(
                      leading: p.media != null
                          ? Image.file(p.media!,
                              width: 70, height: 70, fit: BoxFit.cover)
                          : const Icon(Icons.image, size: 50),
                      title: Text(p.name),
                      subtitle: Text('\$${p.price.toStringAsFixed(2)}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.add_shopping_cart),
                        onPressed: () {
                          setState(() => cart.add(p));
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('${p.name} ajouté au panier')));
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  // =================== CATALOGUE ===================
  Widget _buildCatalog() {
    final filtered = feedProducts
        .where((p) => p.name.toLowerCase().contains(searchQuery.toLowerCase()))
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            decoration: const InputDecoration(
                labelText: 'Rechercher dans catalogue',
                prefixIcon: Icon(Icons.search)),
            onChanged: (v) => setState(() => searchQuery = v),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: filtered.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 0.7,
            ),
            itemBuilder: (context, i) {
              final p = filtered[i];
              return Card(
                child: Column(
                  children: [
                    Expanded(
                        child: p.media != null
                            ? Image.file(p.media!, fit: BoxFit.cover)
                            : const Icon(Icons.image, size: 40)),
                    Padding(
                      padding: const EdgeInsets.all(6.0),
                      child: Column(children: [
                        Text(p.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text('\$${p.price.toStringAsFixed(2)}')
                      ]),
                    )
                  ],
                ),
              );
            },
          ),
        )
      ],
    );
  }

  // =================== PROFIL ===================
  Widget _buildProfil() {
    final name = (userData?['firstName'] ?? '') +
        ((userData?['lastName'] ?? '').isNotEmpty
            ? ' ${userData?['lastName'] ?? ''}'
            : '');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        CircleAvatar(
          radius: 48,
          backgroundImage: userData != null && userData!['photoUrl'] != null
              ? NetworkImage(userData!['photoUrl'])
              : const AssetImage('assets/images/avatar.png') as ImageProvider,
        ),
        const SizedBox(height: 12),
        Text(name.isNotEmpty ? name : (widget.user.displayName ?? 'Nom'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildStatTile('Commandes reçues', commandesRecues),
            _buildStatTile('En attente', commandesEnAttente),
            _buildStatTile('Non reçues', commandesNonRecues),
            _buildStatTile('Points', pointsFidelite),
          ],
        ),
        const SizedBox(height: 16),
        if (!isSeller)
          ElevatedButton.icon(
            icon: const Icon(Icons.store),
            label: const Text('Activer Vendre'),
            onPressed: _activateSellerFlow,
          )
        else
          // Vendeur: Publications / Brouillons (style TikTok)
          SizedBox(
            height: 460,
            child: DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(8)),
                    child: const TabBar(
                      indicatorColor: Colors.deepPurple,
                      labelColor: Colors.deepPurple,
                      unselectedLabelColor: Colors.black54,
                      tabs: [
                        Tab(text: 'Publications'),
                        Tab(text: 'Brouillons'),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TabBarView(children: [
                      // Publications
                      _buildPublicationsList(),
                      // Brouillons
                      _buildDraftsList(),
                    ]),
                  )
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        const Text('Brouillons récents', style: TextStyle(fontSize: 16)),
        SizedBox(
          height: 120,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: drafts.length,
            itemBuilder: (context, i) {
              final d = drafts[i];
              return GestureDetector(
                onTap: () => _publishDraft(d),
                child: Card(
                  margin: const EdgeInsets.all(8),
                  child: Container(
                    width: 100,
                    color: Colors.grey[200],
                    child: d.media != null
                        ? Image.file(d.media!, fit: BoxFit.cover)
                        : const Icon(Icons.image),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _activateSellerFlow() {
    final shopController = TextEditingController();
    final phoneController =
        TextEditingController(text: userData?['phone'] ?? '');
    final emailController = TextEditingController(
        text: userData?['email'] ?? widget.user.email ?? '');
    final locationController =
        TextEditingController(text: userData?['address'] ?? '');

    bool accepted = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setStateDialog) {
        return AlertDialog(
          title: const Text('Activer profil vendeur'),
          content: SingleChildScrollView(
            child: Column(
              children: [
                const Text(
                    '- Commission : 10%\n- Ajoutez téléphone, email et localisation (obligatoire)'),
                TextField(
                    controller: shopController,
                    decoration: const InputDecoration(
                        labelText: 'Nom boutique (facultatif)')),
                TextField(
                    controller: phoneController,
                    decoration:
                        const InputDecoration(labelText: 'Téléphone *')),
                TextField(
                    controller: emailController,
                    decoration: const InputDecoration(labelText: 'Email *')),
                TextField(
                    controller: locationController,
                    decoration:
                        const InputDecoration(labelText: 'Localisation *')),
                Row(children: [
                  Checkbox(
                      value: accepted,
                      onChanged: (v) =>
                          setStateDialog(() => accepted = v ?? false)),
                  const Expanded(child: Text('J’accepte les conditions')),
                ]),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Annuler')),
            ElevatedButton(
              onPressed: accepted &&
                      phoneController.text.isNotEmpty &&
                      emailController.text.isNotEmpty &&
                      locationController.text.isNotEmpty
                  ? () {
                      setState(() {
                        isSeller = true;
                      });
                      Navigator.pop(ctx);
                    }
                  : null,
              child: const Text('Activer'),
            )
          ],
        );
      }),
    );
  }

  Widget _buildStatTile(String label, int value) {
    return Column(
      children: [
        Text(value.toString(),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        Text(label, textAlign: TextAlign.center),
      ],
    );
  }

  Widget _buildPublicationsList() {
    if (products.isEmpty)
      return const Center(child: Text('Aucune publication'));
    return ListView.builder(
      itemCount: products.length,
      itemBuilder: (context, i) {
        final p = products[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: ListTile(
            leading: p.media != null
                ? Image.file(p.media!, width: 70, height: 70, fit: BoxFit.cover)
                : const Icon(Icons.image, size: 50),
            title: Text(p.name),
            subtitle: Text('\$${p.price.toStringAsFixed(2)}'),
            trailing: PopupMenuButton<String>(
              onSelected: (choice) {
                if (choice == 'Partager') _shareProduct(p);
                if (choice == 'Supprimer')
                  setState(() => products.removeWhere((pr) => pr.id == p.id));
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'Partager', child: Text('Partager')),
                PopupMenuItem(value: 'Supprimer', child: Text('Supprimer')),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDraftsList() {
    if (drafts.isEmpty)
      return Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const SizedBox(height: 30),
        const Text('Aucun brouillon'),
        const SizedBox(height: 8),
        ElevatedButton.icon(
            onPressed: _openPickMediaModal,
            icon: const Icon(Icons.add),
            label: const Text('Créer un brouillon'))
      ]));
    return ListView.builder(
      itemCount: drafts.length,
      itemBuilder: (context, i) {
        final d = drafts[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: ListTile(
            leading: d.media != null
                ? Image.file(d.media!, width: 70, height: 70, fit: BoxFit.cover)
                : const Icon(Icons.image),
            title: Text(d.name),
            subtitle: Text(d.isVideo ? 'Vidéo' : 'Photo'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  icon: const Icon(Icons.share),
                  onPressed: () => _shareProduct(d)),
              IconButton(
                  icon: const Icon(Icons.publish),
                  onPressed: () => _publishDraft(d)),
              IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () => _deleteDraft(d)),
            ]),
          ),
        );
      },
    );
  }

  // =================== CART ===================
  Widget _buildCart() {
    final total = cart.fold(0.0, (s, it) => s + it.price);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: cart.isEmpty
                ? const Center(child: Text('Votre panier est vide'))
                : ListView.builder(
                    itemCount: cart.length,
                    itemBuilder: (context, i) {
                      final it = cart[i];
                      return ListTile(
                        leading: it.media != null
                            ? Image.file(it.media!,
                                width: 50, height: 50, fit: BoxFit.cover)
                            : const Icon(Icons.image),
                        title: Text(it.name),
                        subtitle: Text('\$${it.price.toStringAsFixed(2)}'),
                        trailing: IconButton(
                            icon: const Icon(Icons.remove_circle,
                                color: Colors.red),
                            onPressed: () => setState(() => cart.removeAt(i))),
                      );
                    },
                  ),
          ),
          Text('Total: \$${total.toStringAsFixed(2)}',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: cart.isEmpty
                ? null
                : () {
                    if (walletBalance >= total) {
                      setState(() {
                        walletBalance -= total;
                        commandesRecues += cart.length;
                        pointsFidelite += (total ~/ 10);
                        transactions.add(TransactionModel(
                            description: 'Achat (${cart.length} articles)',
                            amount: total,
                            date: DateTime.now()));
                        cart.clear();
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Paiement effectué')));
                    } else {
                      setState(() {
                        commandesEnAttente += cart.length;
                        transactions.add(TransactionModel(
                            description: 'Commande en attente',
                            amount: total,
                            date: DateTime.now()));
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Solde insuffisant')));
                    }
                  },
            child: const Text('Payer le panier'),
          )
        ],
      ),
    );
  }

  // =================== WALLET ===================
  Widget _buildWallet() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Solde: \$${walletBalance.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ElevatedButton(
            onPressed: _addMoney, child: const Text('Ajouter de l’argent')),
        const SizedBox(height: 12),
        const Text('Historique des transactions',
            style: TextStyle(fontSize: 18)),
        const SizedBox(height: 8),
        ...transactions.map((t) => ListTile(
            title: Text(t.description),
            subtitle: Text('${t.date.day}/${t.date.month}/${t.date.year}'),
            trailing: Text('\$${t.amount.toStringAsFixed(2)}'))),
      ],
    );
  }

  void _addMoney() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ajouter de l’argent'),
        content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Montant')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler')),
          ElevatedButton(
              onPressed: () {
                final v = double.tryParse(ctrl.text) ?? 0;
                if (v > 0) {
                  setState(() {
                    walletBalance += v;
                    transactions.add(TransactionModel(
                        description: 'Ajout de fonds',
                        amount: v,
                        date: DateTime.now()));
                  });
                }
                Navigator.pop(ctx);
              },
              child: const Text('Ajouter')),
        ],
      ),
    );
  }
}

class LifecycleEventHandler extends WidgetsBindingObserver {
  final Future<void> Function()? resumeCallBack;

  LifecycleEventHandler({this.resumeCallBack});

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      if (resumeCallBack != null) {
        await resumeCallBack!();
      }
    }
  }
}
