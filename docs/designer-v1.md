# Designer 1.1.0 — première version

Le Companion propose **Paramètres → Mini-écrans → Designer…**. En mode source
distante, le Designer s'ouvre sur cette source : elle doit aussi utiliser 1.1.0.
Le menu montre un message explicite lorsque sa version est trop ancienne.

## Utilisation

1. Installer une première fois le nouveau firmware sur chaque mini-écran par
   USB, avec l'image application à `0x10000`. Garder le partitionnement existant
   et les réglages NVS; ne pas écrire une image complète sur un écran configuré.
2. Ouvrir le Designer. Les écrans apparaissent après leur première connexion.
   Les six derniers caractères de leur adresse matérielle permettent de les
   distinguer. Les pages classiques sont conservées tant qu'aucune publication
   n'est envoyée.
3. Ajouter un modèle : Quotas, Météo, Horloge, Focus, Dans le ciel ou Page libre.
   Ajouter textes, valeurs, jauges et boutons Focus; déplacer les éléments dans
   l'aperçu ou avec les flèches du clavier depuis leur bouton de sélection.
   Les coordonnées et dimensions restent disponibles dans les options avancées.
4. Choisir police, couleurs et écrans destinataires, puis **Envoyer aux écrans**.
   « Publication appliquée » apparaît seulement après confirmation du firmware.
   Les modifications suivantes de pages ne nécessitent plus de flash.

L'aperçu utilise des données d'exemple clairement identifiées. Ses six polices
bitmap sont les mêmes que celles du firmware, accents français compris. Les
pages classiques conservent leur rendu natif; les modèles ajoutés sont éditables.
Une composition accepte huit pages, seize éléments par page, quarante-huit au
total, dans la limite de taille du document. Une publication précédente peut
être restaurée depuis le Designer.

Sur le mini-écran : balayer pour naviguer, toucher une page personnalisée pour
l'épingler/libérer, toucher le bouton Focus pour démarrer/pause. Le point ambre
indique une page épinglée. L'appui long de deux secondes conserve l'accès aux
réglages web. Les pages sont mises en cache sur l'écran; sans connexion, les
valeurs anciennes sont explicitement signalées.

## Dans le ciel

Choisir une municipalité ou saisir latitude/longitude, régler le rayon (1 à
100 km), activer la recherche et, au choix, la bascule automatique. La zone
est envoyée à ADSB.lol; ADSBDB complète les renseignements des vols proches.
Une connexion Internet du Mac source est nécessaire. Aucun compte fournisseur
ou jeton n'est transmis aux mini-écrans.

Le suivi filtre les positions anciennes et les appareils au sol. Un avion
entrant dans le rayon peut interrompre la page active; un avion déjà choisi
reste affiché dans une petite marge extérieure pour éviter les oscillations.
Après sa sortie ou une perte prolongée des données, l'écran reprend sa page
et sa rotation. Le balayage vers la droite ferme l'interruption; vers la gauche,
un autre avion présent est choisi, sinon la page précédente revient. Un même
avion fermé manuellement ne reprend pas immédiatement l'écran. Les interactions,
les pages épinglées et la veille priment; aucun réveil nocturne.

La vitesse est celle par rapport au sol. L'arc représente une progression
estimée, pas la trajectoire géographique ni l'altitude. Les itinéraires manquants,
avec escales ambiguës ou incohérents sont remplacés par « Trajet indisponible ».
La récupération vise dix secondes entre observations; la disponibilité et la
couverture des sources déterminent la fraîcheur réelle.

## Validation du 20 septembre 2026

- Tests Python : authentification, protection des publications, rotation de clé,
  validation, ciblage, confirmation par écran, retour arrière, sauvegarde
  atomique, données aériennes périmées, absence d'itinéraire et panne fournisseur.
- Vérification C++ de la sélection automatique : zone, maintien du vol, sortie,
  prochain avion, fermeture manuelle et page épinglée. Tests existants de veille,
  configuration et DEL conservés.
- Firmware compilé pour le T-Display S3 Long et Companion universel signé,
  avec auto-test natif réussi.
- Parcours dans l'interface avec deux écrans simulés : ajout de modèle, publication
  vers un seul écran, confirmation, choix de police et texte français.
- Requête réelle autour de l'aéroport de Montréal : fournisseur accessible,
  trois appareils, deux itinéraires disponibles au moment de l'essai.
- Companions source et client installés en 1.1.0 : ponts sains, clés, adresse de
  source et veille vérifiées inchangées. Anciennes applications conservées.

**Validation matérielle restante :** aucun écran USB n'était présent pendant
l'implémentation. Le nouveau firmware, le tactile, le cache au redémarrage et la
bascule avec retour doivent encore être vérifiés sur les deux appareils physiques.
La présence de données aériennes réelles et les tests simulés ne remplacent pas
cette vérification. Le lieu personnel à surveiller reste à configurer.

## Périmètre

Cette version livre le moteur de pages et le suivi aérien. Spotify, Sonos,
YouTube, Home Assistant, images personnalisées et graphiques restent dans le
catalogue de recherche. Les mises à jour du moteur de firmware restent par USB;
les descriptions de pages passent par HTTP. Le partitionnement n'est pas changé
et la mise à jour OTA du firmware n'est pas encore ajoutée.
