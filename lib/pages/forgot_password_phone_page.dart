import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ForgotPasswordPhonePage extends StatefulWidget {
  const ForgotPasswordPhonePage({Key? key}) : super(key: key);

  @override
  State<ForgotPasswordPhonePage> createState() =>
      _ForgotPasswordPhonePageState();
}

class _ForgotPasswordPhonePageState extends State<ForgotPasswordPhonePage> {
  int step = 0; // 0 = phone | 1 = otp | 2 = new password

  final phoneCtrl = TextEditingController();
  final otpCtrl = TextEditingController();
  final passCtrl = TextEditingController();

  bool obscure = true;
  bool isLoading = false;

  String verificationId = '';

  // ================== STEP 1 : ENVOI OTP ==================
  Future<void> _sendOtp() async {
    final phone = phoneCtrl.text.trim();
    if (phone.isEmpty) return;

    setState(() => isLoading = true);

    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: phone,
      verificationCompleted: (_) {},
      verificationFailed: (e) {
        setState(() => isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Erreur')),
        );
      },
      codeSent: (id, _) {
        verificationId = id;
        setState(() {
          step = 1;
          isLoading = false;
        });
      },
      codeAutoRetrievalTimeout: (_) {
        setState(() => isLoading = false);
      },
    );
  }

  // ================== STEP 2 : VERIF OTP ==================
  Future<void> _verifyOtp() async {
    final code = otpCtrl.text.trim();
    if (code.length < 6) return;

    setState(() => isLoading = true);

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: code,
      );

      await FirebaseAuth.instance.signInWithCredential(credential);

      setState(() {
        step = 2;
        isLoading = false;
      });
    } catch (_) {
      setState(() => isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Code incorrect')),
      );
    }
  }

  // ================== STEP 3 : NOUVEAU MDP ==================
  Future<void> _resetPassword() async {
    final pass = passCtrl.text.trim();
    if (pass.length < 6) return;

    setState(() => isLoading = true);

    try {
      await FirebaseAuth.instance.currentUser!.updatePassword(pass);
      await FirebaseAuth.instance.signOut();

      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mot de passe mis à jour')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur : $e')),
      );
    } finally {
      setState(() => isLoading = false);
    }
  }

  // ================== UI ==================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mot de passe oublié')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            if (step == 0) ...[
              const Text('Entrez votre numéro'),
              const SizedBox(height: 20),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Téléphone',
                  hintText: '+226xxxxxxxx',
                ),
              ),
              const SizedBox(height: 30),
              _button('Recevoir le code', _sendOtp),
            ],

            if (step == 1) ...[
              const Text('Entrez le code SMS'),
              const SizedBox(height: 20),
              TextField(
                controller: otpCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Code OTP'),
              ),
              const SizedBox(height: 30),
              _button('Vérifier', _verifyOtp),
            ],

            if (step == 2) ...[
              const Text('Nouveau mot de passe'),
              const SizedBox(height: 20),
              TextField(
                controller: passCtrl,
                obscureText: obscure,
                decoration: InputDecoration(
                  labelText: 'Mot de passe',
                  suffixIcon: IconButton(
                    icon: Icon(
                        obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () =>
                        setState(() => obscure = !obscure),
                  ),
                ),
              ),
              const SizedBox(height: 30),
              _button('Confirmer', _resetPassword),
            ],
          ],
        ),
      ),
    );
  }

  Widget _button(String text, VoidCallback onTap) {
    return isLoading
        ? const CircularProgressIndicator()
        : SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: onTap,
              child: Text(text),
            ),
          );
  }
}
