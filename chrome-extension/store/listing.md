# Fiche Chrome Web Store — français

**Nom :** Quota Display — Companion

**Résumé :** Les quotas Codex et Claude de votre Companion Mac, dans Chrome. Client de l’API du Mac source.

**Description :**

Retrouvez les quotas de votre Companion Mac directement dans Chrome, avec la même présentation que son tableau de bord.

- Pourcentages disponibles sur les périodes de 5 heures et de la semaine, selon les données fournies par le Mac.
- Forfaits, compte à rebours des remises à zéro et quota Fable lorsque disponible.
- Resets en banque et dates d’expiration fournies par chaque compte.
- Pourcentage au choix sur l’icône de l’extension et ouverture dans une fenêtre permanente.
- Actualisation à la demande, affichage des fournisseurs et réglage de veille des mini-écrans via le Mac source.

Un Mac avec le Companion Quota Display et son API accessible est requis. Copiez sa configuration API dans les paramètres de l’extension, puis autorisez l’accès à ce Mac. Utilisez un réseau local ou un VPN de confiance.

L’extension est uniquement cliente du Companion Mac. Elle ne se connecte pas directement aux comptes Codex ou Claude : l’authentification, la collecte des quotas et le Designer restent gérés sur le Mac. Les réglages d’affichage et de veille sont partagés avec les autres clients et mini-écrans de cette source.

L’adresse du Mac et sa clé API restent dans le stockage local du profil Chrome. L’extension n’intègre aucun service de publicité ni de télémétrie et ne lit ni les pages consultées ni les conversations.

Les captures utilisent l’interface réelle de l’extension avec des données de démonstration. Les forfaits, quotas et resets disponibles dépendent du compte et des données renvoyées par le Mac.

**Catégorie suggérée :** Productivité

## Visuels

- `screenshot-dashboard-1280x800.png` — vue réelle des quotas.
- `screenshot-resets-1280x800.png` — détail réel des resets Codex en banque.
- `promo-440x280.png` — vignette promotionnelle.

Les trois PNG sont produits à leur taille finale, avec fond RGB opaque, puis inspectés visuellement.

**Provenance :** captures du 21 octobre 2026 avec Chrome 155.0.8059.85 et Playwright installé, dans un contexte de navigateur jetable. Les fichiers réels `popup.html`, `popup.js`, `dashboard.js` et leurs styles ont été chargés sans modification dans une iframe. Seules les API Chrome de stockage et de messagerie ont reçu des réponses simulées dans ce contexte. Les titres promotionnels entourent l’interface réelle. Le détail des resets a été ouvert avec le véritable bouton de l’interface. Aucune erreur de page n’a été observée.

Les données sont fictives, horodatées au 21 octobre 2026 à 12 h 30, avec l’hôte générique `mac-source.local:8788`. Aucune configuration personnelle ni donnée de compte réel n’a été lue; aucune requête n’a été envoyée à un Mac ou à un fournisseur. Les scripts de capture temporaires et le profil jetable n’entrent pas dans le paquet de l’extension.

Cette fiche prépare la soumission; elle ne confirme aucune publication sur le Store.
