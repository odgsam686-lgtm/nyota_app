import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'home_page.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _formKey = GlobalKey<FormState>();
  bool isLogin = true;
  bool showPassword = false;

  String emailOrPhone = '';
  String password = '';
  String firstName = '';
  String lastName = '';
  String phone = '';
  String address = '';
  String errorMessage = '';

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String _hashPassword(String password) {
    var bytes = utf8.encode(password);
    var digest = sha256.convert(bytes);
    return digest.toString();
  }

  // -------- Connexion / Inscription --------
  Future<void> _submit() async {
    print("▶️ Tentative d'inscription/connexion");

    if (!_formKey.currentState!.validate()) return;

    setState(() => errorMessage = '');

    try {
      if (isLogin) {
        if (emailOrPhone.contains('@')) {
          // Connexion par email
          UserCredential cred = await _auth.signInWithEmailAndPassword(
            email: emailOrPhone,
            password: password,
          );
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => HomePage(userEmail: emailOrPhone)),
          );
        } else {
          // Connexion par téléphone
          await _auth.verifyPhoneNumber(
            phoneNumber: emailOrPhone,
            verificationCompleted: (PhoneAuthCredential credential) async {
              await _auth.signInWithCredential(credential);
            },
            verificationFailed: (e) {
              setState(() => errorMessage = e.message ?? 'Erreur téléphone');
            },
            codeSent: (verificationId, resendToken) {
              _showSmsCodeDialog(verificationId);
            },
            codeAutoRetrievalTimeout: (verificationId) {},
          );
        }
      } else {
        // Inscription
        UserCredential cred = await _auth.createUserWithEmailAndPassword(
          email: emailOrPhone,
          password: password,
        );

        await _firestore.collection('users').doc(cred.user!.uid).set({
          'firstName': firstName,
          'lastName': lastName,
          'phone': phone,
          'address': address,
          'email': emailOrPhone,
          'passwordHash': _hashPassword(password),
        });

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => HomePage(userEmail: emailOrPhone)),
        );
      }
    } catch (e) {
      setState(() => errorMessage = e.toString());
    }
  }

  // -------- Localisation --------
  Future<void> _getCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => errorMessage = "Activez la localisation");
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    Position position = await Geolocator.getCurrentPosition();
    List<Placemark> placemarks =
        await placemarkFromCoordinates(position.latitude, position.longitude);
    if (placemarks.isNotEmpty) {
      Placemark place = placemarks.first;
      setState(() {
        address = "${place.street}, ${place.locality}";
      });
    }
  }

  // -------- Réinitialisation mot de passe --------
  void _showPasswordResetDialog() {
    String input = '';
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Réinitialiser le mot de passe"),
        content: TextFormField(
          decoration: const InputDecoration(labelText: "Email ou téléphone"),
          onChanged: (val) => input = val.trim(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Annuler"),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                if (input.contains('@')) {
                  await _auth.sendPasswordResetEmail(email: input);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Email de réinitialisation envoyé !")),
                  );
                } else {
                  await _auth.verifyPhoneNumber(
                    phoneNumber: input,
                    verificationCompleted: (PhoneAuthCredential credential) {},
                    verificationFailed: (FirebaseAuthException e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(e.message ?? 'Erreur')),
                      );
                    },
                    codeSent: (verificationId, int? resendToken) {
                      _showSmsCodeDialog(verificationId);
                    },
                    codeAutoRetrievalTimeout: (String verificationId) {},
                  );
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(e.toString())),
                );
              }
            },
            child: const Text("Envoyer"),
          ),
        ],
      ),
    );
  }

  // -------- Dialog pour code SMS et nouveau mot de passe --------
  void _showSmsCodeDialog(String verificationId) {
    String smsCode = '';
    String newPassword = '';
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Code SMS reçu"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              decoration: const InputDecoration(labelText: "Code SMS"),
              onChanged: (val) => smsCode = val.trim(),
            ),
            TextFormField(
              decoration: const InputDecoration(labelText: "Nouveau mot de passe"),
              obscureText: true,
              onChanged: (val) => newPassword = val.trim(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Annuler"),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                PhoneAuthCredential credential = PhoneAuthProvider.credential(
                  verificationId: verificationId,
                  smsCode: smsCode,
                );
                await _auth.currentUser?.updatePassword(newPassword);
                await _auth.signInWithCredential(credential);

                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Mot de passe réinitialisé !")),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(e.toString())),
                );
              }
            },
            child: const Text("Valider"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(isLogin ? "Connexion" : "Inscription")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              if (!isLogin) ...[
                TextFormField(
                  decoration: const InputDecoration(labelText: "Prénom"),
                  onChanged: (val) => firstName = val.trim(),
                  validator: (val) => val!.isEmpty ? "Entrez votre prénom" : null,
                ),
                TextFormField(
                  decoration: const InputDecoration(labelText: "Nom"),
                  onChanged: (val) => lastName = val.trim(),
                  validator: (val) => val!.isEmpty ? "Entrez votre nom" : null,
                ),
                TextFormField(
                  decoration: const InputDecoration(labelText: "Téléphone"),
                  onChanged: (val) => phone = val.trim(),
                  validator: (val) => val!.isEmpty ? "Entrez votre téléphone" : null,
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: TextEditingController(text: address),
                        decoration: const InputDecoration(labelText: "Adresse"),
                        onChanged: (val) => address = val,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.my_location),
                      onPressed: _getCurrentLocation,
                    ),
                  ],
                ),
              ],
              TextFormField(
                decoration: const InputDecoration(labelText: "Email ou téléphone"),
                onChanged: (val) => emailOrPhone = val.trim(),
                validator: (val) => val!.isEmpty ? "Entrez votre email ou téléphone" : null,
              ),
              TextFormField(
                obscureText: !showPassword,
                decoration: InputDecoration(
                  labelText: "Mot de passe",
                  suffixIcon: IconButton(
                    icon: Icon(showPassword ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => showPassword = !showPassword),
                  ),
                ),
                onChanged: (val) => password = val,
                validator: (val) => val!.length < 4 ? "Au moins 4 caractères" : null,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _submit,
                child: Text(isLogin ? "Se connecter" : "S’inscrire"),
              ),
              TextButton(
                onPressed: () => setState(() => isLogin = !isLogin),
                child: Text(isLogin ? "Pas de compte ? S’inscrire" : "Déjà un compte ? Se connecter"),
              ),
              TextButton(
                onPressed: _showPasswordResetDialog,
                child: const Text("Mot de passe oublié ?"),
              ),
              const SizedBox(height: 10),
              Text(errorMessage, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ),
    );
  }
}
