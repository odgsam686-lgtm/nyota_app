import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

class AuthPage extends StatefulWidget {
  final Map<String, String> users; // email -> password
  final Function(String) onLogin;

  const AuthPage({super.key, required this.users, required this.onLogin});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  bool isLogin = true;
  String? selectedUser;

  final _formKey = GlobalKey<FormState>();
  String email = '';
  String password = '';
  String firstName = '';
  String lastName = '';
  String phone = '';
  String address = '';
  String errorMessage = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(isLogin ? "Connexion" : "Inscription")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            if (widget.users.isNotEmpty && isLogin)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Connexion rapide :"),
                  DropdownButton<String>(
                    hint: const Text('Sélectionner un compte'),
                    value: selectedUser,
                    items: widget.users.keys
                        .map((e) => DropdownMenuItem(
                              value: e,
                              child: Text(e),
                            ))
                        .toList(),
                    onChanged: (val) {
                      setState(() {
                        selectedUser = val!;
                        widget.onLogin(selectedUser!);
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            Form(
              key: _formKey,
              child: Column(
                children: [
                  if (!isLogin) ...[
                    TextFormField(
                      decoration: const InputDecoration(labelText: "Prénom"),
                      onChanged: (val) => firstName = val.trim(),
                      validator: (val) =>
                          val!.isEmpty ? "Entrez votre prénom" : null,
                    ),
                    TextFormField(
                      decoration: const InputDecoration(labelText: "Nom"),
                      onChanged: (val) => lastName = val.trim(),
                      validator: (val) =>
                          val!.isEmpty ? "Entrez votre nom" : null,
                    ),
                    TextFormField(
                      decoration: const InputDecoration(labelText: "Téléphone"),
                      onChanged: (val) => phone = val.trim(),
                      validator: (val) =>
                          val!.isEmpty ? "Entrez votre téléphone" : null,
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: TextEditingController(text: address),
                            decoration:
                                const InputDecoration(labelText: "Adresse"),
                            onChanged: (val) => address = val,
                            validator: (val) =>
                                val!.isEmpty ? "Adresse requise" : null,
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
                    decoration: const InputDecoration(labelText: "Email"),
                    onChanged: (val) => email = val.trim(),
                    validator: (val) =>
                        val!.isEmpty ? "Entrez votre email" : null,
                  ),
                  TextFormField(
                    obscureText: true,
                    decoration: const InputDecoration(labelText: "Mot de passe"),
                    onChanged: (val) => password = val,
                    validator: (val) =>
                        val!.length < 4 ? "Au moins 4 caractères" : null,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _submit,
                    child: Text(isLogin ? "Se connecter" : "S’inscrire"),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    child: Text(
                        isLogin ? "Créer un compte" : "J’ai déjà un compte"),
                    onPressed: () => setState(() {
                      isLogin = !isLogin;
                      errorMessage = '';
                    }),
                  ),
                  const SizedBox(height: 12),
                  Text(errorMessage,
                      style: const TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      if (isLogin) {
        if (!widget.users.containsKey(email)) {
          setState(() {
            errorMessage = "Compte inexistant. Veuillez vous inscrire d'abord.";
          });
        } else if (widget.users[email] != password) {
          setState(() {
            errorMessage = "Mot de passe incorrect.";
          });
        } else {
          widget.onLogin(email);
        }
      } else {
        if (widget.users.containsKey(email)) {
          setState(() {
            errorMessage = "Un compte avec cet email existe déjà";
          });
        } else {
          widget.users[email] = password;
          widget.onLogin(email);
        }
      }
    }
  }

  Future<void> _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => errorMessage = "Activez la localisation pour continuer");
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() => errorMessage = "Permission de localisation refusée");
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() => errorMessage = "Autorisation refusée définitivement");
      return;
    }

    Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
    List<Placemark> placemarks =
        await placemarkFromCoordinates(position.latitude, position.longitude);

    if (placemarks.isNotEmpty) {
      Placemark place = placemarks.first;
      setState(() {
        address =
            "${place.street}, ${place.locality}, ${place.postalCode}, ${place.country}";
      });
    }
  }
}
