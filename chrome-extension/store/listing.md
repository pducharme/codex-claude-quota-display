# Fiche Chrome Web Store — français

**Nom :** Quota Display — Companion

**Résumé :** Vos quotas Codex, Claude et crédits API dans Chrome, via vos sessions web ou un Companion Mac.

**Description :**

Suivez vos quotas Codex et Claude directement dans Chrome. Le mode sessions web
fonctionne sans Mac. Le mode Companion Mac reste disponible pour retrouver les
données de votre installation existante.

- Pourcentages disponibles sur les périodes de 5 heures et de la semaine, lorsque fournis par le compte.
- Forfaits, compte à rebours des remises à zéro et quota Fable lorsque disponible.
- Resets en banque et dates d’expiration, en lecture seule.
- Crédits OpenAI Work/Codex et crédits API OpenAI et Claude en USD, avec le montant mensuel utilisé / accordé et son expiration.
- Pourcentage au choix sur l’icône de l’extension et fenêtre permanente.
- Actualisation automatique et à la demande, avec indication des données non actualisées.

**Sessions web :** connectez les services souhaités depuis les paramètres de
l’extension. Chaque accès est facultatif. Connectez-vous une fois aux sites
officiels, puis fermez les onglets : les quotas sont actualisés en arrière-plan
toutes les cinq minutes. Une session expirée demande une reconnexion. Ce mode
affiche uniquement les données dans Chrome et ne pilote pas les mini-écrans.

**Companion Mac :** copiez sa configuration API dans les paramètres et autorisez
l’accès au Mac source. Utilisez un réseau local ou un VPN de confiance. Dans ce
mode, les choix d’affichage et les réglages de veille sont partagés avec le Mac
et ses mini-écrans; le Designer reste dans le Companion.

Vos préférences restent dans ce profil Chrome, sans synchronisation avec Google.
Les lectures du mode web se limitent aux quotas et crédits des services autorisés.
Les sessions Codex et Claude utilisent les cookies gérés par Chrome. Pour les
crédits API OpenAI, le jeton de session Platform est conservé localement afin de
lire le solde sans onglet ouvert; il est supprimé avec Déconnecter. Aucune
conversation ni historique de navigation n’est collecté; aucun service
publicitaire ou de télémétrie n’est intégré.

Les forfaits, quotas, resets et crédits disponibles dépendent du compte et des
données fournies par le service. Les crédits API liés à ChatGPT Pro sont distincts
des crédits Work/Codex; le premier montant accordé peut être calculé au prorata.

**Catégorie suggérée :** Productivité

## Visuels

- `screenshot-dashboard-1280x800.png` — vue réelle des quotas.
- `screenshot-resets-1280x800.png` — détail réel des resets Codex en banque.
- `promo-440x280.png` — vignette promotionnelle.

Les trois PNG sont produits à leur taille finale, avec fond RGB opaque, puis inspectés visuellement.

**Provenance :** captures du 21 octobre 2026 avec Chrome 155.0.8059.85 et Playwright installé, dans un contexte de navigateur jetable. Les fichiers réels `popup.html`, `popup.js`, `dashboard.js` et leurs styles ont été chargés sans modification dans une iframe. Seules les API Chrome de stockage et de messagerie ont reçu des réponses simulées dans ce contexte. Les titres promotionnels entourent l’interface réelle. Le détail des resets a été ouvert avec le véritable bouton de l’interface. Aucune erreur de page n’a été observée.

Les données sont fictives, horodatées au 21 octobre 2026 à 12 h 30, avec l’hôte générique `mac-source.local:8788`. Aucune configuration personnelle ni donnée de compte réel n’a été lue; aucune requête n’a été envoyée à un Mac ou à un fournisseur. Les scripts de capture temporaires et le profil jetable n’entrent pas dans le paquet de l’extension.

Cette fiche prépare la soumission; elle ne confirme aucune publication sur le Store.
