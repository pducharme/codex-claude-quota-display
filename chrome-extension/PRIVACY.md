# Confidentialité — Quota Display pour Chrome

Dernière mise à jour : 17 novembre 2026.

Quota Display affiche vos quotas et crédits Codex et Claude, ainsi que les quotas Gemini et Grok. Vous choisissez
entre les sessions web de ce profil Chrome et l’API d’un Companion Mac.

## Données utilisées

- Le mode choisi, les services autorisés, les préférences d’affichage et, si vous
  utilisez un Companion Mac, son adresse et sa clé API sont conservés dans
  `chrome.storage.local`. Ces données ne sont pas synchronisées avec Google.
- Les quotas, forfaits, soldes de crédits, identifiants de compte ou d’organisation,
  états de connexion et dates de remise à zéro ou d’expiration sont conservés
  temporairement dans `chrome.storage.session`. Ce cache disparaît à la fin de
  la session du navigateur. Les dernières valeurs peuvent rester visibles avec
  une indication lorsqu’elles ne sont plus actualisées.
- En mode sessions web, la connexion initiale s’effectue sur les sites officiels.
  Vous pouvez ensuite fermer les onglets. Pour les quotas Codex, Claude, Gemini et Grok et les
  crédits Claude, l’extension utilise les cookies gérés par Chrome. Le jeton
  d’accès ChatGPT nécessaire aux quotas Codex reste uniquement en mémoire
  pendant la lecture; il n’est pas enregistré dans le stockage de l’extension.
- Pour les crédits API OpenAI, une lecture ponctuelle de la page de facturation
  récupère le jeton de session OpenAI Platform et l’organisation sélectionnée.
  Ce jeton est conservé dans `chrome.storage.local`, sans synchronisation avec
  Google, pour permettre les lectures après fermeture de l’onglet et redémarrage
  de Chrome. Il est supprimé lorsque vous déconnectez ce service. Il sert
  uniquement aux requêtes de lecture prévues vers `api.openai.com`, sans suivre
  les redirections. Il n’est jamais envoyé au Companion Mac ni affiché dans
  le tableau de bord ou ses erreurs.
- Pour Gemini, la page Utilisation est lue puis seuls ses blocs de quotas sont conservés. Le reste du document est ignoré. Une empreinte irréversible de session permet de séparer les comptes Gemini et Grok; les cookies eux-mêmes ne sont pas enregistrés.
- L’extension ne conserve ni vos conversations, ni votre historique de navigation,
  ni le contenu des autres pages que vous consultez.

## Communications et permissions

En mode sessions web, l’extension demande votre autorisation séparément pour
ChatGPT (`chatgpt.com`), Claude (`claude.ai`), OpenAI Platform
(`platform.openai.com` et `api.openai.com`) et Claude Console
(`platform.claude.com`), Gemini (`gemini.google.com`) et Grok (`grok.com`), selon les services que vous connectez. La permission
`cookies` permet de retrouver les sessions et organisations concernées dans ce
profil. Pour OpenAI Platform, la permission `scripting` permet uniquement la
capture initiale de la session sur la page de facturation autorisée; cette
capture est désactivée ensuite. Aucun code distant n’est téléchargé pour être
exécuté par l’extension.

L’extension lit les routes de quotas et de crédits prévues en arrière-plan,
toutes les cinq minutes, même si les onglets sont fermés. Si une session expire,
elle vous invite à vous reconnecter. Elle n’effectue aucun achat, ne consomme
aucun reset et ne modifie aucun réglage de votre abonnement. Les choix
d’affichage de ce mode s’appliquent uniquement à Chrome; il ne transmet rien
aux mini-écrans.

En mode Companion Mac, les requêtes vont à l’adresse que vous avez configurée,
avec sa clé API dans l’en-tête `Authorization`. L’accès HTTP ou HTTPS à cet hôte
est demandé lors de l’enregistrement. Les commandes d’actualisation, d’affichage
et de veille sont transmises au Mac; les réglages d’affichage et de veille sont
partagés avec ses autres clients et mini-écrans. Les diagnostics du Companion
suivent ses propres réglages, indépendamment de l’extension.

Les permissions `storage` et `alarms` servent à conserver la configuration et
à actualiser les données en arrière-plan. Aucun service publicitaire, de suivi
ou de télémétrie n’est intégré. Les données ne sont ni vendues ni utilisées
pour d’autres fonctions que l’affichage demandé.

**Copier la configuration API** place l’adresse et la clé du Companion dans
votre presse-papiers uniquement lorsque vous le demandez. Avec une adresse HTTP,
ces données circulent sans chiffrement applicatif. Utilisez un réseau de
confiance ou un VPN, ou une adresse HTTPS; n’exposez pas le port HTTP sur Internet.

L’utilisation des données respecte la Politique relative aux données utilisateur
du Chrome Web Store, y compris ses exigences d’utilisation limitée.

## Suppression et contact

**Déconnecter** un service web retire son activation, ses données en cache et
son éventuel jeton enregistré, puis révoque les permissions qui ne sont plus
utilisées par une autre connexion. Cela ne ferme pas votre session sur le site officiel.
**Déconnecter** le Companion supprime son adresse, sa clé et son cache, puis
retire les permissions qui ne sont plus utilisées. Changer de mode conserve
les connexions enregistrées, mais l’extension lit seulement la source choisie.
Désinstaller l’extension supprime son stockage Chrome.

Pour toute question ou demande, utilisez les
[issues du projet](https://github.com/pducharme/codex-claude-quota-display/issues).
Ne joignez jamais de clé API, de jeton de session ou de données personnelles
à une demande publique.
