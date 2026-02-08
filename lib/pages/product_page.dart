import 'package:flutter/material.dart';

class ProductPage extends StatelessWidget {
  final Map<String, dynamic> data;
  const ProductPage({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(data['description'] ?? 'Produit')),
      body: Column(
        children: [
          data['mediaUrl'] != null
              ? Image.network(data['mediaUrl'], height: 300, fit: BoxFit.cover)
              : Container(height: 300, color: Colors.grey),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(data['description'] ?? '', style: const TextStyle(fontSize: 18)),
          ),
          ElevatedButton(
            onPressed: () {
              // Ajouter au panier
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Produit ajouté au panier')),
              );
            },
            child: const Text('Ajouter au panier'),
          )
        ],
      ),
    );
  }
}
