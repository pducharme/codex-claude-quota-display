# Confidentialité — Quota Display pour Chrome

Dernière mise à jour : 21 octobre 2026.

Quota Display pour Chrome affiche les quotas fournis par le Companion installé
sur votre Mac. L’extension est uniquement cliente de cette API.

## Données utilisées

- L’adresse du Mac source et sa clé API sont enregistrées dans
  `chrome.storage.local`, dans votre profil Chrome, sans synchronisation avec
  votre compte Google. La préférence du pourcentage affiché sur l’icône y est
  aussi conservée.
- Les quotas, forfaits, états des fournisseurs, dates de remise à zéro et réglages
  reçus du Mac sont conservés temporairement dans `chrome.storage.session` pour
  afficher le tableau de bord, y compris les dernières données si le Mac devient
  inaccessible. Ce cache disparaît à la fin de la session du navigateur.
- L’extension ne lit pas vos identifiants OpenAI ou Anthropic, vos sessions OAuth,
  vos conversations, vos pages visitées ni votre historique de navigation. Les
  connexions aux fournisseurs restent gérées par le Companion Mac.

## Communications et permissions

Les requêtes réseau de l’extension vont uniquement à l’adresse du Mac que vous
avez configurée. Elles contiennent la clé API de ce Companion dans l’en-tête
`Authorization`. Aucun service de collecte, de publicité, de suivi ou de
télémétrie n’est intégré à l’extension. Aucune donnée n’est vendue ou transmise
par l’extension à un service tiers.

La permission de stockage conserve la configuration et le cache. La permission
`alarms` permet de relire les quotas en arrière-plan. L’accès HTTP ou HTTPS à
l’hôte choisi est demandé lorsque vous enregistrez la configuration du Mac;
l’extension n’injecte aucun script dans les sites que vous consultez.

Lorsque vous demandez une actualisation ou modifiez l’affichage des fournisseurs
ou la veille des mini-écrans, l’extension transmet cette commande au Mac source.
Les réglages d’affichage et de veille s’appliquent aussi à ses autres clients et
mini-écrans. Les éventuels diagnostics du Companion Mac suivent ses propres
réglages, indépendamment de l’extension.

La commande **Copier la configuration API** place l’adresse et la clé dans votre
presse-papiers uniquement lorsque vous la choisissez. Si vous configurez une
adresse HTTP, le jeton et les données transitent sans chiffrement applicatif.
Une adresse HTTPS utilise le chiffrement de cette connexion. Utilisez l’API HTTP
sur un réseau de confiance ou un VPN et n’exposez pas son port sur Internet.

L’utilisation des données par Quota Display respecte la Politique relative aux
données utilisateur du Chrome Web Store, y compris ses exigences d’utilisation
limitée. Les données servent uniquement aux fonctions décrites ci-dessus et ne
sont utilisées ni pour la publicité ni pour évaluer la solvabilité d’une personne.

## Suppression et contact

**Paramètres → API et connexions → Déconnecter** supprime de l’extension l’adresse,
la clé et le cache des quotas, puis retire sa permission d’accès à cet hôte. Cela
ne modifie pas les comptes ni les réglages du Mac source. Désinstaller
l’extension supprime son stockage Chrome, y compris les préférences restantes.

Pour toute question ou demande liée à cette politique, ouvrez une demande sur
les [issues du projet](https://github.com/pducharme/codex-claude-quota-display/issues).
Ne joignez jamais votre clé API à une demande publique.
