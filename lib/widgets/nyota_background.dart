import 'package:flutter/material.dart';

class NyotaBackground extends StatelessWidget {
  final Widget child;

  const NyotaBackground({Key? key, required this.child}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 🧱 Fond blanc
        Container(color: Colors.white),

        // 🌫️ NYOTA en gris transparent
        Center(
          child: Text(
            'NYOTA',
            style: TextStyle(
              fontSize: 68,
              fontWeight: FontWeight.w900,
              color: Colors.grey.withOpacity(0.06), // 🔥 très léger
              letterSpacing: 5,
            ),
          ),
        ),

        // 📦 Contenu réel de la page
        child,
      ],
    );
  }
}
