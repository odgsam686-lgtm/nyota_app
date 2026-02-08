 return FutureBuilder(
      future: Supabase.instance.client
          .from('users')
          .select()
          .eq('firebase_uid', firebaseUser.uid)
          .single(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final userData = snapshot.data as Map<String, dynamic>;

        final fullName =
            "${userData['first_name'] ?? ''} ${userData['last_name'] ?? ''}"
                .trim();

        final bool isSeller = userData['is_seller'] == true;

        return Scaffold(
          appBar: AppBar(
            title: const Text("Mon Profil"),
            actions: [
              IconButton(
                icon: const Icon(Icons.more_vert),
                onPressed: () {
                  showModalBottomSheet(
                    context: context,
                    shape: const RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(20)),
                    ),
                    builder: (_) => const PrivateProfileMenu(),
                  );
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: Stack(
                  children: [
                    GestureDetector(
                      onTap: () {
                        final photoUrl = userData['photo_url'];
                        if (photoUrl == null || (photoUrl as String).isEmpty)
                          return;

                        showDialog(
                          context: context,
                          builder: (context) {
                            return Scaffold(
                              backgroundColor: Colors.black,
                              appBar: AppBar(
                                backgroundColor: Colors.black,
                                iconTheme:
                                    const IconThemeData(color: Colors.white),
                                actions: [
                                  IconButton(
                                    icon: const Icon(Icons.delete,
                                        color: Colors.red),
                                    onPressed: () async {
                                      final confirm = await showDialog<bool>(
                                        context: context,
                                        barrierDismissible: false,
                                        builder: (context) {
                                          return AlertDialog(
                                            title: const Text(
                                                "Supprimer la photo"),
                                            content: const Text(
                                                "Voulez-vous vraiment supprimer votre photo de profil ?"),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                    context, false),
                                                child: const Text("Annuler"),
                                              ),
                                              ElevatedButton(
                                                style: ElevatedButton.styleFrom(
                                                    backgroundColor:
                                                        Colors.red),
                                                onPressed: () => Navigator.pop(
                                                    context, true),
                                                child: const Text("Supprimer"),
                                              ),
                                            ],
                                          );
                                        },
                                      );

                                      if (confirm == true) {
                                        Navigator.pop(
                                            context); // ferme la preview
                                        await _deleteAvatar(); // ✅ ta fonction déjà prête
                                      }
                                    },
                                  ),
                                ],
                              ),
                              body: Center(
                                child: Image.network(
                                  photoUrl,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            );
                          },
                        );
                      },
                      child: CircleAvatar(
                        radius: 55,
                        backgroundColor: Colors.grey.shade300,
                        backgroundImage: (userData['photo_url'] != null &&
                                (userData['photo_url'] as String).isNotEmpty)
                            ? NetworkImage(userData['photo_url'])
                            : const AssetImage("assets/images/avatar.png")
                                as ImageProvider,
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: InkWell(
                        onTap: _pickAndUploadPhoto,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(
                            color: Colors.deepPurple,
                            shape: BoxShape.circle,
                          ),
                          child:
                              const Icon(Icons.camera_alt, color: Colors.white),
                        ),
                      ),
                    )
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  displayName != null && displayName!.isNotEmpty
                      ? displayName!
                      : (userData['email'] ?? "Utilisateur"),
                  style: TextStyle(
                    fontSize: displayName != null && displayName!.isNotEmpty
                        ? 22
                        : 14,
                    fontWeight: displayName != null && displayName!.isNotEmpty
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: displayName != null && displayName!.isNotEmpty
                        ? Colors.black
                        : Colors.grey.shade500,
                  ),
                ),
              ),
              if (displayName == null || displayName!.isEmpty)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GestureDetector(
                      onTap: _editDisplayName,
                      child: Row(
                        children: const [
                          Icon(Icons.add, size: 18),
                          SizedBox(width: 4),
                          Text(
                            "Ajouter un nom",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          SizedBox(width: 6),
                          Icon(Icons.keyboard_arrow_down, size: 18),
                        ],
                      ),
                    ),
                  ],
                ),
              if (displayName != null && displayName!.isNotEmpty)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GestureDetector(
                      onTap: _editDisplayName,
                      child: const Icon(Icons.edit, size: 18),
                    ),
                  ],
                ),
              GestureDetector(
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text("Modifier la bio"),
                      content: const Text("Voulez-vous modifier votre bio ?"),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text("Non"),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text("Oui"),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true) {
                    _editBio();
                  }
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      bio == null || bio!.isEmpty
                          ? "Ajouter une bio"
                          : "bio : $bio",
                      style: TextStyle(
                        fontSize: 14,
                        color: bio == null || bio!.isEmpty
                            ? Colors.grey
                            : Colors.black,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.edit, size: 16),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (showBusinessStats)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _stat("Reçues", commandesRecues),
                    _stat("En attente", commandesEnAttente),
                    _stat("Non reçues", commandesNonRecues),
                    _stat("Points", pointsFidelite),
                  ],
                ),
              if (showBusinessStats) const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Column(
                    children: [
                      Text(
                        "$followersCount",
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        "Abonnés",
                        style: TextStyle(color: Colors.black),
                      ),
                    ],
                  ),
                  const SizedBox(width: 30),
                  Column(
                    children: [
                      Text(
                        "$followingCount",
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        "Suivis",
                        style: TextStyle(color: Colors.black),
                      ),
                    ],
                  ),
                  const SizedBox(width: 30),
                  Column(
                    children: [
                      Text(
                        "$creatorViews",
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        "Vues",
                        style: TextStyle(color: Colors.black),
                      ),
                    ],
                  ),
                  const SizedBox(width: 30),
                  Column(
                    children: [
                      Text(
                        "$creatorLikes",
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        "Likes",
                        style: TextStyle(color: Colors.black),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (!isSeller)
                ElevatedButton.icon(
                  icon: const Icon(Icons.store),
                  label: const Text("Activer Vendre"),
                  onPressed: _activateSellerFlow,
                )
              else
                _sellerPanel(),
              const SizedBox(height: 40),
            ],
          ),
        );
      },
    );                