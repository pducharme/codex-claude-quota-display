# Chrome Web Store — notes pour la version 1.2.0

## Objectif unique

Afficher les quotas de Codex, Claude, Gemini et Grok ainsi que les crédits API OpenAI et Claude, au choix depuis les
sessions web de ce profil ou l’API d’un Companion Mac. Les connexions, le badge
et les réglages d’affichage servent uniquement cet objectif.

## Justification des permissions

**storage** — Conserve localement le mode, les services connectés, les préférences
et, selon le mode, l’adresse et la clé du Companion Mac ou le jeton de session
OpenAI Platform. Ce jeton permet de lire les crédits API sans garder un onglet
ouvert; il est validé avant enregistrement et supprimé à la déconnexion. Le
stockage local et de session est réservé aux contextes de l’extension
(`TRUSTED_CONTEXTS`), inaccessible aux scripts de contenu. Les jetons Platform
ne sont jamais renvoyés au tableau de bord. Aucune synchronisation Google.

**alarms** — Réveille le service worker environ une fois par minute pour tenir
le badge à jour. Le mode web relit les fournisseurs toutes les cinq minutes,
même si leurs onglets sont fermés, tant que Chrome fonctionne. Le mode Companion
relit l’API du Mac; la collecte auprès des fournisseurs reste alors sur le Mac.

**cookies, facultative** — Identifie le compte ChatGPT (`_account`) ou
l’organisation Claude (`lastActiveOrg`) et détecte les changements de session.
Pour Gemini et Grok, une empreinte de session permet d’identifier un changement de compte. Les cookies d’authentification restent gérés par Chrome et ne sont pas copiés
dans le stockage de l’extension. Les lectures HTTPS autorisées les utilisent
pour les quotas Codex, Claude, Gemini et Grok et les crédits Claude. Le jeton d’accès ChatGPT
obtenu pour les quotas Codex reste en mémoire pendant la lecture.

**scripting, facultative** — Sert uniquement à la connexion explicite aux crédits
API OpenAI. Sur `platform.openai.com`, une capture ponctuelle relève le jeton de
session et l’organisation d’une lecture réussie de la page de facturation.
Elle est arrêtée après la capture, la déconnexion ou dix minutes. Il n’y a aucun
script permanent de collecte dans les onglets et aucune clé API statique à saisir.

**Hôtes HTTP/HTTPS optionnels** — L’accès est demandé uniquement aux services
choisis : `chatgpt.com`, `claude.ai`, `platform.claude.com`, `gemini.google.com`, `grok.com`, ou
`platform.openai.com` et `api.openai.com` pour les crédits OpenAI. Les routes de
session, quotas et crédits prévues sont lues en arrière-plan, sans achat ni
consommation de reset. En mode Companion, l’utilisateur choisit une adresse
inconnue à l’avance; l’extension appelle seulement `/v1/quotas`, `/v1/refresh`
et `/v1/display`. Une permission d’hôte devenue inutile est retirée à la
déconnexion ou au changement de Mac.

## Code distant

**Non.** Tout le JavaScript et les assets sont inclus dans l’extension. Les
réponses JSON et les blocs de quotas incorporés à la page Utilisation de Gemini sont traités comme des données; aucun code distant n’est chargé
ou exécuté par l’extension.

## Données et confidentialité

Politique publique :
[Confidentialité de Quota Display](https://github.com/pducharme/codex-claude-quota-display/blob/main/chrome-extension/PRIVACY.md).

- Déclarer les **informations d’authentification** : clé API du Mac, session
  OpenAI Platform enregistrée localement, et accès aux sessions web autorisées.
  Les secrets sont transmis uniquement au service concerné; les erreurs et
  le tableau de bord ne les affichent pas.
- Déclarer le **contenu de site Web** pour les quotas, forfaits, états, dates de
  remise à zéro, identifiants de compte ou d’organisation et réglages utilisés.
  Les données normalisées sont gardées dans le cache de session Chrome.
- Déclarer les **informations financières et de paiement** pour les soldes de
  crédits API et les montants mensuels. L’extension n’utilise aucun numéro de
  carte ni moyen de paiement; elle affiche les montants et dates des crédits.
- Aucun historique de navigation ni conversation n’est collecté. Aucun service
  publicitaire, de télémétrie ou de collecte du développeur n’est intégré.
  Aucune vente de données ni utilisation pour la publicité ou la solvabilité.
- Ne pas déclarer « aucune donnée traitée » ou « toutes les communications sont
  chiffrées » : une adresse HTTP de Companion transmet la clé et les données sans
  chiffrement applicatif. Utiliser un réseau de confiance, un VPN ou HTTPS.
- **Déconnecter** retire les données et le jeton éventuel du service ainsi que
  les permissions inutilisées. Cela ne ferme pas la session sur le site officiel.
  Changer de mode conserve les connexions, mais seule la source choisie est lue.
  Désinstaller supprime le stockage Chrome de l’extension.

## Instructions de validation avant soumission

Le mode web ne nécessite aucun Mac ni compte auprès du développeur. Les comptes
des fournisseurs doivent disposer des quotas ou crédits à vérifier; une donnée
non fournie reste inconnue. N’inclure aucune véritable clé ni donnée personnelle
dans les captures ou instructions publiques.

1. Dans **Paramètres → API et connexions — Source des quotas**, choisir
   **Sessions web — sans Mac** et connecter séparément les services souhaités.
   Autoriser les accès proposés et terminer la connexion sur les sites officiels.
2. Pour OpenAI Platform, sélectionner l’organisation liée à l’abonnement et
   attendre l’état **À jour**. Vérifier les montants utilisés / accordés et
   l’expiration UTC, séparément des crédits Work/Codex; le premier crédit mensuel
   peut être proratisé.
3. Fermer les onglets des fournisseurs. Vérifier que le tableau de bord et le badge
   continuent à s’actualiser après cinq minutes, puis après un redémarrage de Chrome.
4. Vérifier la reconnexion après expiration, les données inconnues ou périmées,
   puis **Déconnecter** et la suppression des accès et du jeton Platform.
5. Sélectionner **Companion Mac**, copier la configuration API du Mac et choisir
   **Enregistrer et connecter**. Vérifier quotas, crédits, badge et fenêtre
   permanente avec le Companion source actif.
6. Vérifier que l’affichage et la veille du mode Companion sont partagés avec le
   Mac et ses mini-écrans. En mode web, les choix sont propres à Chrome et aucune
   donnée ni commande de veille n’est transmise aux mini-écrans.
7. Ouvrir la deuxième page avec la flèche sous les cartes. Avec un compte connecté, vérifier les deux périodes Gemini et les compteurs Grok par mode. Les sites des fournisseurs peuvent être fermés lors de l’actualisation.
