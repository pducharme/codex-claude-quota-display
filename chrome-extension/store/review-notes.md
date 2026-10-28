# Chrome Web Store — notes de soumission

## Objectif unique

Afficher dans Chrome les quotas Codex et Claude fournis par l’API du Companion
installé sur le Mac choisi par l’utilisateur, avec actualisation et réglages
d’affichage associés.

## Justification des permissions

**storage** — Conserve dans le profil Chrome l’adresse du Mac source, son jeton
API et la préférence du badge. Le dernier état des quotas est gardé dans le
stockage de session pour afficher les dernières données si le Mac devient
inaccessible. Aucune synchronisation Google n’est utilisée.

**alarms** — Relit les quotas du Mac configuré environ une fois par minute afin
de tenir le badge à jour lorsque le tableau de bord est fermé. La collecte
auprès des fournisseurs reste exécutée sur le Mac.

**Hôtes HTTP/HTTPS optionnels** — Chaque utilisateur choisit son Mac source,
avec une adresse IP ou un nom d’hôte inconnu à l’avance. Les motifs HTTP/HTTPS
sont déclarés comme permissions optionnelles; l’accès est demandé uniquement
pour l’hôte choisi lors de la configuration. L’extension appelle seulement
`/v1/quotas`, `/v1/refresh` et `/v1/display`. Elle ne lit pas les pages visitées
et n’y injecte aucun script. L’ancienne permission est retirée lors d’un
changement d’hôte ou d’une déconnexion.

## Code distant

**Non.** Tout le JavaScript et les assets sont inclus dans l’extension. Les
réponses JSON du Mac sont traitées comme des données; aucun code distant n’est
chargé ou exécuté.

## Données et confidentialité

Politique publique :
<https://github.com/pducharme/codex-claude-quota-display/blob/main/chrome-extension/PRIVACY.md>

- Déclarer les **informations d’authentification** : le jeton API du Mac est
  enregistré localement et transmis uniquement au serveur choisi par
  l’utilisateur dans l’en-tête `Authorization`.
- Déclarer le **contenu de site Web** pour les réponses de l’API : quotas,
  forfaits, états, dates de remise à zéro et réglages. Ces données restent dans
  le cache de session Chrome et servent au tableau de bord et au badge.
- Déclarer les **informations financières et de paiement** pour les soldes de
  crédits API et les montants mensuels. Les numéros de carte et moyens de paiement
  ne sont jamais reçus; seuls les soldes normalisés par le Mac sont affichés.
- Aucun historique de navigation, suivi des pages, identifiant de connexion,
  session OAuth, conversation, numéro de carte ou coordonnée bancaire n’est lu par l’extension.
  Aucun service de publicité, de télémétrie ou de collecte du développeur n’est
  intégré. Aucune vente de données ni utilisation pour la publicité ou la
  solvabilité.
- Ne pas déclarer « aucune donnée traitée » ou « toutes les communications sont
  chiffrées ». Une adresse HTTP choisie par l’utilisateur transmet la clé et les
  données sans chiffrement applicatif; utiliser un réseau local ou un VPN de
  confiance. HTTPS utilise le chiffrement du serveur configuré.
- Déconnecter supprime l’adresse, le jeton et le cache, puis retire l’accès à
  l’hôte. Désinstaller supprime aussi les préférences restantes.

Le client communique uniquement avec un serveur fourni par l’utilisateur. La
[FAQ officielle, questions 15 et 16](https://developer.chrome.com/docs/webstore/program-policies/user-data-faq)
décrit l’exception applicable aux clients de protocole à serveur choisi et aux
échanges avec un programme natif sur le même ordinateur.

## Prérequis et instructions de test

L’extension nécessite un Companion Quota Display configuré et actif sur un Mac
accessible depuis Chrome. Elle ne demande aucun compte auprès du développeur.
Chrome peut fonctionner sur un autre ordinateur. Les connexions Codex/Claude,
le Designer et les intégrations restent gérés par le Companion Mac.

1. Installer et configurer le Companion depuis le
   [dépôt du projet](https://github.com/pducharme/codex-claude-quota-display).
2. Sur le Mac : **Paramètres → API et connexions → Copier la configuration API**.
3. Dans l’extension : **Paramètres → API et connexions**, coller la configuration,
   puis choisir **Enregistrer et connecter** et autoriser l’hôte configuré.
4. Avec le Companion Mac 1.1.14, connecter Claude Console sur le Mac source pour
   vérifier aussi les crédits achetés et mensuels. Vérifier les quotas, les resets
   en banque, le badge, l’actualisation et la fenêtre permanente. Les valeurs de quota et de reset dépendent des données
   fournies par les comptes du Mac source.
5. Vérifier les réglages de visibilité et de veille : ils sont partagés avec le
   Mac source et ses mini-écrans. Déconnecter termine la connexion côté Chrome.

Ne fournir dans la fiche, les captures ou les instructions publiques aucune
adresse privée d’installation ni véritable clé API. Le réviseur doit disposer
d’un Mac source compatible ou d’un environnement de test séparé.
