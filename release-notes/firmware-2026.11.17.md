Firmware Quota Display — 17 novembre 2026

Ajoute les crédits API mensuels OpenAI à la carte Codex : montant utilisé / réellement accordé en USD et date d’expiration UTC, séparément des crédits Work/Codex. Le premier versement peut être proratisé; aucun solde de 200 $ n’est présumé. Une donnée inconnue reste **--**; après quinze minutes sans lecture réussie, le dernier solde est marqué **~** et affiché en ambre.

Le Companion Mac source doit utiliser la version 1.1.17 ou une version plus récente. Choisissez **Paramètres → API et connexions → Connexions → Connecter OpenAI Platform…** sur ce Mac et sélectionnez l’organisation liée à l’abonnement ChatGPT. Le mini-écran reçoit les soldes par l’API existante; la session OpenAI Platform reste sur le Mac source.

Pour mettre à jour un mini-écran déjà configuré, écrivez uniquement **quota-display-openai-2026.11.17-app.bin à 0x10000**, sans effacer la flash. Cette méthode conserve les réglages Wi-Fi, la clé API, le Designer et l’horaire de veille.

L’image **quota-display-openai-2026.11.17-full.bin à 0x0** est destinée à une première installation et recouvre aussi la zone des réglages. Les deux images et leurs sommes SHA-256 sont incluses.

Cette version n’a pas été flashée sur les mini-écrans du projet. La validation visuelle et tactile sur le matériel reste à effectuer.
