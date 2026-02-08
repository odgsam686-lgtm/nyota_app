// main.dart
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_storage/firebase_storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nyota',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.deepPurple),
      home: FirebaseAuth.instance.currentUser == null
          ? const LoginPage()
          : HomePage(user: FirebaseAuth.instance.currentUser!),
    );
  }
}

class ChatPage extends StatefulWidget {
  final String sellerId;
  final String sellerName;
  final String sellerPhoto;

  const ChatPage({super.key, required this.sellerId, required this.sellerName, required this.sellerPhoto});

  @override
  _ChatPageState createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _textCtrl = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  final currentUser = FirebaseAuth.instance.currentUser!;
  String chatId = '';

  @override
  void initState() {
    super.initState();
    // chatId unique entre l'utilisateur et le vendeur
    chatId = currentUser.uid.compareTo(widget.sellerId) > 0
        ? '${currentUser.uid}_${widget.sellerId}'
        : '${widget.sellerId}_${currentUser.uid}';
  }

  Future<void> _sendMessage({String? text, File? media}) async {
    String? mediaUrl;
    if (media != null) {
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('chat_media/$chatId/${DateTime.now().millisecondsSinceEpoch}');
      await storageRef.putFile(media);
      mediaUrl = await storageRef.getDownloadURL();
    }

    if ((text != null && text.trim().isNotEmpty) || mediaUrl != null) {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add({
        'senderId': currentUser.uid,
        'receiverId': widget.sellerId,
        'text': text ?? '',
        'mediaUrl': mediaUrl ?? '',
        'timestamp': FieldValue.serverTimestamp(),
      });
      _textCtrl.clear();
    }
  }

  Future<void> _pickMedia(bool isVideo) async {
    XFile? file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        preferredCameraDevice: CameraDevice.rear);
    if (file != null) {
      await _sendMessage(media: File(file.path));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              backgroundImage: widget.sellerPhoto.isNotEmpty
                  ? NetworkImage(widget.sellerPhoto)
                  : const AssetImage('assets/images/avatar.png') as ImageProvider,
            ),
            const SizedBox(width: 12),
            Text(widget.sellerName),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chats')
                  .doc(chatId)
                  .collection('messages')
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                final messages = snapshot.data!.docs;
                return ListView.builder(
                  reverse: true,
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final msg = messages[index];
                    final isMe = msg['senderId'] == currentUser.uid;
                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isMe ? Colors.blue[200] : Colors.grey[300],
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (msg['text'] != null && msg['text'].toString().isNotEmpty)
                              Text(msg['text']),
                            if (msg['mediaUrl'] != null && msg['mediaUrl'].toString().isNotEmpty)
                              GestureDetector(
                                onTap: () {
                                  // On peut ajouter ouverture plein écran
                                },
                                child: msg['mediaUrl'].toString().endsWith('.mp4')
                                    ? Container(
                                        width: 150,
                                        height: 150,
                                        color: Colors.black,
                                        child: const Center(child: Icon(Icons.play_arrow, color: Colors.white, size: 40)),
                                      )
                                    : Image.network(msg['mediaUrl'], width: 150, height: 150, fit: BoxFit.cover),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const Divider(height: 1),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.photo),
                onPressed: () => _pickMedia(false),
              ),
              Expanded(
                child: TextField(
                  controller: _textCtrl,
                  decoration: const InputDecoration(hintText: 'Écrire un message'),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: () => _sendMessage(text: _textCtrl.text.trim()),
              ),
            ],
          ),
        ],
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
  bool isLoading = false;
  bool obscure = true;

  Future<void> _login() async {
    final email = emailCtrl.text.trim();
    final pass = passCtrl.text;
    if (email.isEmpty || pass.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Email et mot de passe requis')));
      return;
    }

    setState(() => isLoading = true);
    try {
      UserCredential userCred = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: pass);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => HomePage(user: userCred.user!)),
      );
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found') {
        // propose la page d'inscription
        final res = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Compte introuvable'),
            content: const Text('Voulez-vous créer un compte avec ces identifiants ?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(_, false), child: const Text('Non')),
              ElevatedButton(onPressed: () => Navigator.pop(_, true), child: const Text('Oui')),
            ],
          ),
        );
        if (res == true) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => RegisterPage(email: email, password: pass)));
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: ${e.message}')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e')));
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
        content: TextField(controller: controller, decoration: const InputDecoration(labelText: 'Entrez votre email')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          ElevatedButton(
            onPressed: () async {
              final e = controller.text.trim();
              if (e.isEmpty) return;
              Navigator.pop(ctx);
              try {
                await FirebaseAuth.instance.sendPasswordResetEmail(email: e);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Email de réinitialisation envoyé')));
              } on FirebaseAuthException catch (err) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.message ?? 'Erreur')));
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
    return Scaffold(
      appBar: AppBar(title: const Text('Connexion')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: emailCtrl, decoration: const InputDecoration(labelText: 'Email'), keyboardType: TextInputType.emailAddress),
                const SizedBox(height: 12),
                TextField(
                  controller: passCtrl,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: 'Mot de passe',
                    suffixIcon: IconButton(
                      icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => obscure = !obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: _forgotPassword, child: const Text('Mot de passe oublié ?')),
                ),
                const SizedBox(height: 12),
                isLoading
                    ? const CircularProgressIndicator()
                    : ElevatedButton(onPressed: _login, child: const Text('Se connecter')),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterPage())),
                  child: const Text('Créer un compte'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =================== REGISTER PAGE ===================
class RegisterPage extends StatefulWidget {
  final String? email;
  final String? password;
  const RegisterPage({Key? key, this.email, this.password}) : super(key: key);

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _form = GlobalKey<FormState>();
  final TextEditingController emailCtrl = TextEditingController();
  final TextEditingController passCtrl = TextEditingController();
  final TextEditingController firstCtrl = TextEditingController();
  final TextEditingController lastCtrl = TextEditingController();
  final TextEditingController phoneCtrl = TextEditingController();
  final TextEditingController addressCtrl = TextEditingController();

  bool isLoading = false;
  bool obscure = true;

  @override
  void initState() {
    super.initState();
    if (widget.email != null) emailCtrl.text = widget.email!;
    if (widget.password != null) passCtrl.text = widget.password!;
  }

  Future<void> _register() async {
    if (!_form.currentState!.validate()) return;
    setState(() => isLoading = true);
    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(email: emailCtrl.text.trim(), password: passCtrl.text);
      await FirebaseFirestore.instance.collection('users').doc(cred.user!.uid).set({
        'firstName': firstCtrl.text.trim(),
        'lastName': lastCtrl.text.trim(),
        'phone': phoneCtrl.text.trim(),
        'address': addressCtrl.text.trim(),
        'email': emailCtrl.text.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => HomePage(user: cred.user!)));
    } on FirebaseAuthException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? 'Erreur')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e')));
    } finally {
      setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Inscription')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              children: [
                TextFormField(controller: firstCtrl, decoration: const InputDecoration(labelText: 'Prénom'), validator: (v) => (v==null || v.trim().isEmpty) ? 'Obligatoire' : null),
                TextFormField(controller: lastCtrl, decoration: const InputDecoration(labelText: 'Nom'), validator: (v) => (v==null || v.trim().isEmpty) ? 'Obligatoire' : null),
                TextFormField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Téléphone'), keyboardType: TextInputType.phone, validator: (v) => (v==null || v.trim().isEmpty) ? 'Obligatoire' : null),
                TextFormField(controller: addressCtrl, decoration: const InputDecoration(labelText: 'Adresse'), validator: (v) => (v==null || v.trim().isEmpty) ? 'Obligatoire' : null),
                TextFormField(controller: emailCtrl, decoration: const InputDecoration(labelText: 'Email'), keyboardType: TextInputType.emailAddress, validator: (v) => (v==null || v.trim().isEmpty) ? 'Obligatoire' : null),
                const SizedBox(height: 12),
                TextFormField(
                  controller: passCtrl,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: 'Mot de passe',
                    suffixIcon: IconButton(icon: Icon(obscure ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => obscure = !obscure)),
                  ),
                  validator: (v) => (v==null || v.length < 4) ? 'Au moins 4 caractères' : null,
                ),
                const SizedBox(height: 20),
                isLoading ? const CircularProgressIndicator() : ElevatedButton(onPressed: _register, child: const Text('S’inscrire')),
              ],
            ),
          ),
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

  TransactionModel({required this.description, required this.amount, required this.date});
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

  @override
  void initState() {
    super.initState();
    _loadUserData();
    _getUserLocation();
  }

  Future<void> _loadUserData() async {
    try {
      DocumentSnapshot doc = await FirebaseFirestore.instance.collection('users').doc(widget.user.uid).get();
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
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.deniedForever) return;

      Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      setState(() => userPosition = pos);
    } catch (e) {
      debugPrint('Erreur localisation: $e');
    }
  }

  double _distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const double R = 6371;
    double dLat = (lat2 - lat1) * pi / 180;
    double dLon = (lon2 - lon1) * pi / 180;
    double a = sin(dLat/2)*sin(dLat/2) +
        cos(lat1*pi/180)*cos(lat2*pi/180)*sin(dLon/2)*sin(dLon/2);
    double c = 2*atan2(sqrt(a), sqrt(1-a));
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
        double d = _distanceKm(userPosition!.latitude, userPosition!.longitude, p.latitude!, p.longitude!);
        if (d <= 10) isLocal = true;
      }

      if (isLocal) local.add(p);
      else if (p.isPromo) promos.add(p);
      else if (p.isTrending) trending.add(p);
      else others.add(p);
    }

    List<Product> finalFeed = [];
    finalFeed.addAll(local);
    finalFeed.addAll(promos);
    finalFeed.addAll(trending);
    finalFeed.addAll(others);
    return finalFeed;
  }

  // =================== PICK MEDIA ===================
  Future<void> _pickMediaAndAddDraft({required bool fromCamera, required bool isVideo}) async {
    try {
      XFile? file;
      if (fromCamera) {
        file = isVideo
            ? await _picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(seconds: 60))
            : await _picker.pickImage(source: ImageSource.camera, maxWidth: 1920, maxHeight: 1080);
      } else {
        file = isVideo
            ? await _picker.pickVideo(source: ImageSource.gallery)
            : await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1920, maxHeight: 1080);
      }

      if (file != null) {
        final f = File(file.path);
        setState(() {
          drafts.add(Product(id: DateTime.now().millisecondsSinceEpoch.toString(), name: 'Brouillon', media: f, isVideo: isVideo));
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
    final nameCtrl = TextEditingController(text: draft.name == 'Brouillon' ? '' : draft.name);
    final priceCtrl = TextEditingController(text: draft.price > 0 ? draft.price.toStringAsFixed(2) : '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Publier le brouillon'),
        content: SingleChildScrollView(
          child: Column(
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Nom (optionnel)')),
              TextField(controller: priceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Prix (optionnel)')),
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          ElevatedButton(
            onPressed: () {
              final name = nameCtrl.text.trim().isEmpty ? 'Publication ${products.length + 1}' : nameCtrl.text.trim();
              final price = double.tryParse(priceCtrl.text.trim()) ?? 0.0;
              setState(() {
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Non')),
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
        await Share.shareXFiles([fx], text: 'Regarde ce produit: ${p.name} - \$${p.price.toStringAsFixed(2)}');
      } catch (e) {
        // fallback
        await Share.share('Regarde ce produit: ${p.name} - \$${p.price.toStringAsFixed(2)}');
      }
    } else {
      await Share.share('Regarde ce produit: ${p.name} - \$${p.price.toStringAsFixed(2)}');
    }
  }

  // =================== UI & NAV ===================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentIndex == 0 ? 'Accueil' : _currentIndex == 4 ? 'Solde' : 'Nyota'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginPage()));
            },
          ),
        ],
      ),
      body: isLoading ? const Center(child: CircularProgressIndicator()) : _getBody(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        type: BottomNavigationBarType.fixed,
        onTap: (i) => setState(() => _currentIndex = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Accueil'),
          BottomNavigationBarItem(icon: Icon(Icons.store), label: 'Catalogue'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profil'),
          BottomNavigationBarItem(icon: Icon(Icons.shopping_cart), label: 'Panier'),
          BottomNavigationBarItem(icon: Icon(Icons.account_balance_wallet), label: 'Solde'),
        ],
      ),
      floatingActionButton: _currentIndex == 2
          ? FloatingActionButton(
              onPressed: _openPickMediaModal,
              child: const Icon(Icons.add_a_photo),
              tooltip: 'Prendre / importer (brouillon)',
            )
          : null,
    );
  }

  Widget _getBody() {
    switch (_currentIndex) {
      case 0:
        return _buildFeed();
      case 1:
        return _buildCatalog();
      case 2:
        return _buildProfil();
      case 3:
        return _buildCart();
      case 4:
        return _buildWallet();
      default:
        return _buildFeed();
    }
  }

  // =================== FEED ===================
  Widget _buildFeed() {
    return FutureBuilder<List<Product>>(
      future: getUserFeed(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final filtered = snapshot.data!.where((p) => p.name.toLowerCase().contains(searchQuery.toLowerCase())).toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextField(
                decoration: const InputDecoration(labelText: 'Rechercher', prefixIcon: Icon(Icons.search)),
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
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: ListTile(
                      leading: p.media != null ? Image.file(p.media!, width: 70, height: 70, fit: BoxFit.cover) : const Icon(Icons.image, size: 50),
                      title: Text(p.name),
                      subtitle: Text('\$${p.price.toStringAsFixed(2)}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.add_shopping_cart),
                        onPressed: () {
                          setState(() => cart.add(p));
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${p.name} ajouté au panier')));
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
    final filtered = feedProducts.where((p) => p.name.toLowerCase().contains(searchQuery.toLowerCase())).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            decoration: const InputDecoration(labelText: 'Rechercher dans catalogue', prefixIcon: Icon(Icons.search)),
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
                    Expanded(child: p.media != null ? Image.file(p.media!, fit: BoxFit.cover) : const Icon(Icons.image, size: 40)),
                    Padding(
                      padding: const EdgeInsets.all(6.0),
                      child: Column(children: [Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis), Text('\$${p.price.toStringAsFixed(2)}')]),
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
    final name = (userData?['firstName'] ?? '') + ((userData?['lastName'] ?? '').isNotEmpty ? ' ${userData?['lastName'] ?? ''}' : '');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        CircleAvatar(
          radius: 48,
          backgroundImage: userData != null && userData!['photoUrl'] != null ? NetworkImage(userData!['photoUrl']) : const AssetImage('assets/images/avatar.png') as ImageProvider,
        ),
        const SizedBox(height: 12),
        Text(name.isNotEmpty ? name : (widget.user.displayName ?? 'Nom'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
                    decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(8)),
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
                    child: d.media != null ? Image.file(d.media!, fit: BoxFit.cover) : const Icon(Icons.image),
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
    final phoneController = TextEditingController(text: userData?['phone'] ?? '');
    final emailController = TextEditingController(text: userData?['email'] ?? widget.user.email ?? '');
    final locationController = TextEditingController(text: userData?['address'] ?? '');

    bool accepted = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setStateDialog) {
        return AlertDialog(
          title: const Text('Activer profil vendeur'),
          content: SingleChildScrollView(
            child: Column(
              children: [
                const Text('- Commission : 10%\n- Ajoutez téléphone, email et localisation (obligatoire)'),
                TextField(controller: shopController, decoration: const InputDecoration(labelText: 'Nom boutique (facultatif)')),
                TextField(controller: phoneController, decoration: const InputDecoration(labelText: 'Téléphone *')),
                TextField(controller: emailController, decoration: const InputDecoration(labelText: 'Email *')),
                TextField(controller: locationController, decoration: const InputDecoration(labelText: 'Localisation *')),
                Row(children: [
                  Checkbox(value: accepted, onChanged: (v) => setStateDialog(() => accepted = v ?? false)),
                  const Expanded(child: Text('J’accepte les conditions')),
                ]),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
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
        Text(value.toString(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        Text(label, textAlign: TextAlign.center),
      ],
    );
  }

  Widget _buildPublicationsList() {
    if (products.isEmpty) return const Center(child: Text('Aucune publication'));
    return ListView.builder(
      itemCount: products.length,
      itemBuilder: (context, i) {
        final p = products[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: ListTile(
            leading: p.media != null ? Image.file(p.media!, width: 70, height: 70, fit: BoxFit.cover) : const Icon(Icons.image, size: 50),
            title: Text(p.name),
            subtitle: Text('\$${p.price.toStringAsFixed(2)}'),
            trailing: PopupMenuButton<String>(
              onSelected: (choice) {
                if (choice == 'Partager') _shareProduct(p);
                if (choice == 'Supprimer') setState(() => products.removeWhere((pr) => pr.id == p.id));
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
    if (drafts.isEmpty) return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const SizedBox(height: 30), const Text('Aucun brouillon'), const SizedBox(height: 8), ElevatedButton.icon(onPressed: _openPickMediaModal, icon: const Icon(Icons.add), label: const Text('Créer un brouillon'))]));
    return ListView.builder(
      itemCount: drafts.length,
      itemBuilder: (context, i) {
        final d = drafts[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: ListTile(
            leading: d.media != null ? Image.file(d.media!, width: 70, height: 70, fit: BoxFit.cover) : const Icon(Icons.image),
            title: Text(d.name),
            subtitle: Text(d.isVideo ? 'Vidéo' : 'Photo'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.share), onPressed: () => _shareProduct(d)),
              IconButton(icon: const Icon(Icons.publish), onPressed: () => _publishDraft(d)),
              IconButton(icon: const Icon(Icons.delete), onPressed: () => _deleteDraft(d)),
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
                        leading: it.media != null ? Image.file(it.media!, width: 50, height: 50, fit: BoxFit.cover) : const Icon(Icons.image),
                        title: Text(it.name),
                        subtitle: Text('\$${it.price.toStringAsFixed(2)}'),
                        trailing: IconButton(icon: const Icon(Icons.remove_circle, color: Colors.red), onPressed: () => setState(() => cart.removeAt(i))),
                      );
                    },
                  ),
          ),
          Text('Total: \$${total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: cart.isEmpty ? null : () {
              if (walletBalance >= total) {
                setState(() {
                  walletBalance -= total;
                  commandesRecues += cart.length;
                  pointsFidelite += (total ~/ 10);
                  transactions.add(TransactionModel(description: 'Achat (${cart.length} articles)', amount: total, date: DateTime.now()));
                  cart.clear();
                });
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Paiement effectué')));
              } else {
                setState(() {
                  commandesEnAttente += cart.length;
                  transactions.add(TransactionModel(description: 'Commande en attente', amount: total, date: DateTime.now()));
                });
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Solde insuffisant')));
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
        Text('Solde: \$${walletBalance.toStringAsFixed(2)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ElevatedButton(onPressed: _addMoney, child: const Text('Ajouter de l’argent')),
        const SizedBox(height: 12),
        const Text('Historique des transactions', style: TextStyle(fontSize: 18)),
        const SizedBox(height: 8),
        ...transactions.map((t) => ListTile(title: Text(t.description), subtitle: Text('${t.date.day}/${t.date.month}/${t.date.year}'), trailing: Text('\$${t.amount.toStringAsFixed(2)}'))),
      ],
    );
  }

  void _addMoney() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ajouter de l’argent'),
        content: TextField(controller: ctrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Montant')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          ElevatedButton(onPressed: () {
            final v = double.tryParse(ctrl.text) ?? 0;
            if (v > 0) {
              setState(() {
                walletBalance += v;
                transactions.add(TransactionModel(description: 'Ajout de fonds', amount: v, date: DateTime.now()));
              });
            }
            Navigator.pop(ctx);
          }, child: const Text('Ajouter')),
        ],
      ),
    );
  }
}

