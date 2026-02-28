import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:nyota_app/pages/notifications_page.dart';
import 'package:nyota_app/pages/settings_page.dart' as app_settings;

class PrivateProfileMenu extends StatelessWidget {
  const PrivateProfileMenu({super.key});

  void _openMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _item(context, "Paramètres & confidentialité", Icons.lock,
                const app_settings.SettingsPage()),
            _item(context, "Ton code QR", Icons.qr_code, const QRCodePage()),
            _item(context, "Conditions d’utilisation", Icons.description,
                const TermsPage()),
            _item(context, "Politique de confidentialité", Icons.privacy_tip,
                const PrivacyPolicyPage()),
            _item(context, "À propos de Nyota", Icons.info, const AboutPage()),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text("Déconnexion",
                  style: TextStyle(color: Colors.red)),
              onTap: () async {
                await FirebaseAuth.instance.signOut();
                if (!context.mounted) return;
                Navigator.popUntil(context, (r) => r.isFirst);
              },
            ),
          ],
        );
      },
    );
  }

  ListTile _item(
      BuildContext context, String title, IconData icon, Widget page) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      onTap: () {
        Navigator.pop(context);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => page),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.more_vert),
      onPressed: () => _openMenu(context),
    );
  }
}

////////////////////////////////////////////////////////////
/// PAGES INTERNES — TOUT DANS CE FICHIER
////////////////////////////////////////////////////////////

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _page(
      context,
      "Paramètres & confidentialité",
      [
        const ListTile(title: Text("Modifier le profil")),
        const ListTile(title: Text("Changer mot de passe")),
        ListTile(
          title: const Text("Notifications"),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const NotificationsPage(),
              ),
            );
          },
        ),
        const ListTile(title: Text("Bloquer des utilisateurs")),
        ListTile(
          title: const Text("Supprimer le compte",
              style: TextStyle(color: Colors.red)),
          onTap: () {},
        ),
      ],
    );
  }
}

class QRCodePage extends StatelessWidget {
  const QRCodePage({super.key});

  @override
  Widget build(BuildContext context) {
    final userId = FirebaseAuth.instance.currentUser!.uid;
    final profileLink = "https://nyota.africa/profile/$userId";

    return _page(
      context,
      "Ton code QR",
      [
        // 🔳 QR CODE
        Center(
          child: QrImageView(
            data: profileLink,
            size: 220,
          ),
        ),

        const SizedBox(height: 20),

        const Text(
          "Partage ton profil Nyota",
          textAlign: TextAlign.center,
        ),

        const SizedBox(height: 24),

        // 🔘 BOUTONS (comme TikTok)
        Row(
          children: [
            // 🔗 Copier le lien
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.link),
                label: const Text("Copier le lien"),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: profileLink),
                  );
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Lien copié")),
                  );
                },
              ),
            ),

            const SizedBox(width: 12),

            // 📤 Partager le lien
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.share),
                label: const Text("Partager le lien"),
                onPressed: () {
                  Share.share(
                    profileLink,
                    subject: "Découvre mon profil Nyota",
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}


class TermsPage extends StatelessWidget {
  const TermsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _page(
      context,
      "Conditions d’utilisation",
      const [
        Text(
          "CONDITIONS D’UTILISATION DE NYOTA\n\n"
          "1. Présentation\n"
          "Nyota est une plateforme de mise en relation entre vendeurs et acheteurs, "
          "facilitant la vente de produits et services ainsi que la livraison.\n\n"
          "2. Rôle de Nyota\n"
          "Nyota agit comme intermédiaire technique. La plateforme ne fabrique, "
          "ne stocke et ne vend aucun produit.\n\n"
          "3. Responsabilité des vendeurs\n"
          "Chaque vendeur est seul responsable des produits publiés, de leur conformité, "
          "de leur qualité et de leur légalité.\n\n"
          "4. Responsabilité des acheteurs\n"
          "L’acheteur s’engage à fournir des informations exactes et à respecter "
          "les conditions de paiement et de livraison.\n\n"
          "5. Paiements et livraisons\n"
          "Les modalités de paiement et de livraison peuvent évoluer. Nyota met en place "
          "des mécanismes pour renforcer la sécurité des transactions.\n\n"
          "6. Suspension et suppression de compte\n"
          "Nyota se réserve le droit de suspendre ou supprimer tout compte en cas "
          "d’utilisation abusive ou frauduleuse.\n\n"
          "7. Acceptation\n"
          "L’utilisation de l’application vaut acceptation pleine et entière "
          "des présentes conditions.",
          style: TextStyle(fontSize: 14, height: 1.5),
        )
      ],
    );
  }
}

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _page(
      context,
      "Politique de confidentialité",
      const [
        Text(
          "POLITIQUE DE CONFIDENTIALITÉ DE NYOTA\n\n"
          "1. Données collectées\n"
          "Nyota collecte uniquement les données nécessaires au fonctionnement "
          "de la plateforme : identité, contact, publications et activités.\n\n"
          "2. Utilisation des données\n"
          "Les données sont utilisées pour assurer la sécurité, améliorer l’expérience "
          "utilisateur et faciliter les transactions.\n\n"
          "3. Partage des données\n"
          "Nyota ne revend aucune donnée personnelle. Certaines informations peuvent "
          "être partagées uniquement pour le bon fonctionnement du service "
          "(livraison, sécurité, obligations légales).\n\n"
          "4. Sécurité\n"
          "Nyota met en œuvre des mesures techniques pour protéger les données "
          "contre les accès non autorisés.\n\n"
          "5. Droits des utilisateurs\n"
          "Chaque utilisateur peut demander l’accès, la modification ou la suppression "
          "de ses données.\n\n"
          "6. Conservation des données\n"
          "Les données sont conservées aussi longtemps que le compte est actif "
          "ou selon les obligations légales.\n\n"
          "7. Mise à jour\n"
          "Cette politique peut être mise à jour à tout moment. "
          "Les utilisateurs seront informés en cas de changement important.",
          style: TextStyle(fontSize: 14, height: 1.5),
        )
      ],
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _page(
      context,
      "À propos",
      const [
        Text(
          "Nyota\nVersion 1.0.0\n\nPlateforme africaine de commerce sécurisé.",
        ),
      ],
    );
  }
}

////////////////////////////////////////////////////////////
/// WIDGET UTILITAIRE
////////////////////////////////////////////////////////////

Widget _page(BuildContext context, String title, List<Widget> children) {
  return Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: children,
      ),
    ),
  );
}
