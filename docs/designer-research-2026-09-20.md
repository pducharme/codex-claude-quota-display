# Designer pour mini-écrans : recherche et proposition

Recherche du 20 septembre 2026. Catalogue et proposition de produit. Une première partie est maintenant implémentée; voir [le périmètre livré et la validation restante](designer-v1.md). Les 26 intégrations ne sont pas toutes livrées.

## Direction recommandée

Un catalogue de modules prêts à utiliser, avec personnalisation visuelle progressive. Objectif proposé : une première page utile en moins de deux minutes après connexion du service, sans écrire de code ni manipuler des coordonnées.

Le chemin principal serait **Choisir un modèle → Connecter → Personnaliser → Publier**. Le placement libre serait une option avancée. Les pages existantes de quotas et de météo deviennent les premiers modèles, en conservant leur rendu et leur fonctionnement.

## Ce que montrent les communautés

- Un projet publié dans r/homeoffice propose déjà écran tactile, widgets, configuration par application et glisser-déposer. Un commentaire insiste sur les services déjà connectés et le minimum de configuration. C'est une piste qualitative, pas une mesure de demande du marché. [Discussion](https://www.reddit.com/r/homeoffice/comments/1s7kzh7/built_a_color_touchscreen_desk_display_with/)
- Un utilisateur de Sonos a construit un écran de bureau pour changer de morceau, régler les pièces et couper le son avant les réunions. Son appareil communique avec un bridge sur son ordinateur : scénario particulièrement proche de notre Companion. [Projet](https://www.reddit.com/r/esp32/comments/1u9gvcp/sonos_speaker_desktop_control_panel/)
- Les utilisateurs d'ESPHome réclament une prévisualisation et un placement visuel. Certains rencontrent cependant du code généré incomplet ou des écarts entre le Designer et l'écran réel. Notre publication doit vérifier le résultat sur l'appareil et permettre le retour à la version précédente. [Besoin](https://community.home-assistant.io/t/esphome-display-designer-simulator-web-app/876078), [difficultés](https://community.home-assistant.io/t/esphome-designer-question/1001074)
- Une discussion Tidbyt/AWTRIX décrit météo, CO₂, solaire, portes, lessive, rendez-vous et bus. Les échanges soulignent le risque d'alertes manquées ou envahissantes : durée, priorité, acquittement et retour à la page précédente sont des fonctionnalités de base. [Discussion](https://www.reddit.com/r/homeautomation/comments/1ol2690)
- Un projet de départs ferroviaires suscite une demande explicite pour le LilyGO T-Display S3 Long et pour un filtrage des trains qui ramènent l'utilisateur chez lui. Le format allongé convient particulièrement aux prochaines échéances. [Discussion](https://www.reddit.com/r/esp32/comments/1k28gzy/esp32_based_uk_departures_board/)

## Parcours simple

1. **Ajouter une page** ouvre une galerie avec un aperçu réel et des catégories : Musique, Bureau, Maison, Créateur, Atelier, Fun.
2. **Choisir un modèle** présente ses prérequis avant installation : compte à connecter, appareil nécessaire, Home Assistant optionnel ou requis selon le module.
3. **Connecter le service une fois** dans le Companion. Le même compte est réutilisé par toutes les pages; les secrets du fournisseur restent sur le Mac.
4. **Personnaliser** avec quelques choix : disposition, ambiance, police, accent, informations visibles. L'aperçu fonctionne d'abord avec des données d'exemple clairement identifiées.
5. **Publier** sur un écran nommé ou les deux. Afficher « envoyé », puis « appliqué » uniquement après accusé de réception de chaque appareil. Un écran hors ligne garde une publication en attente.

Pour une composition personnelle : bouton Ajouter, recherche de blocs, placement automatique dans une grille, aimantation, redimensionnement par poignées, double-clic pour éditer le texte, annuler/rétablir. Un clic doit permettre l'ajout sans obligation de glisser. La navigation clavier doit permettre de sélectionner, déplacer et configurer.

Un bloc pourrait être une valeur, un texte, une image, une jauge, un petit graphique, un bouton ou un module complet. Le choix de donnée doit employer des libellés comme « Sonos → Bureau → Volume », sans afficher de chemins JSON dans le parcours normal.

## Typographies proposées

La sélection ci-dessous est un choix de design à tester sur le matériel, pas un classement issu des forums. Conserver la police bitmap actuelle comme option par défaut.

| Nom visible | Police | Utilisation proposée |
|---|---|---|
| Pixel original | Glyphes actuels 5 × 7 | Identité actuelle, quotas, horloge |
| Pixel compact | [Silkscreen](https://fonts.google.com/specimen/Silkscreen) | Titres courts, compteurs rétro |
| Pixel doux | [Pixelify Sans](https://fonts.google.com/specimen/Pixelify+Sans) | Météo, pages ludiques, texte plus souple |
| Terminal | [VT323](https://fonts.google.com/specimen/VT323) | Horloges, serveur, ambiance terminal |
| Moderne | [Space Grotesk](https://fonts.google.com/specimen/Space+Grotesk) | Musique, agenda, pages sobres |
| Technique | [JetBrains Mono](https://fonts.google.com/specimen/JetBrains+Mono) | Statistiques et valeurs alignées |

Les cinq alternatives figurent sous licence OFL dans les métadonnées du dépôt officiel [Google Fonts](https://github.com/google/fonts/tree/main/ofl). Conserver les notices avec les fichiers distribués. Les pages doivent fonctionner sans connexion à Google : polices préparées et transmises par le Companion. Vérifier les accents français, les chiffres, le symbole degré et les titres longs. Proposer des tailles optimisées pour l'écran et éviter le redimensionnement fractionnaire des glyphes bitmap.

Ambiances suggérées : Pixel classique, Terminal ambre, Minimal, Musique. Une ambiance choisit une combinaison lisible; elle reste distincte du contenu de la page.

## Catalogue de 26 usages

« Observé » signifie qu'un utilisateur, un auteur de projet ou une documentation montre l'usage. « Proposition » est notre extrapolation; cela ne prouve pas une intégration existante ou une demande commerciale. Les sources regroupées sont référencées après le tableau.

| # | Module | Ce que l'écran montre ou permet | Origine / dépendance à prévoir |
|---|---|---|---|
| 1 | Quotas IA | Reste disponible, échéances et resets | Existant dans notre produit |
| 2 | Télécommande Spotify | Pochette, titre, pause, suivant, appareil cible | Observé [A]; API et compte autorisés |
| 3 | Télécommande Sonos | Lecture, volume, pièce, favoris | Observé [B]; via Home Assistant ou connecteur dédié |
| 4 | Contrôles du Mac | Volume, lecture et raccourcis choisis | Proposition; autorisations macOS selon action |
| 5 | Prochaine réunion | Titre, heure et compte à rebours | Observé [C]; calendrier connecté |
| 6 | Focus / Pomodoro | Démarrer, pause, progression, pause suivante | Observé [A]; fonctionnement local possible |
| 7 | Météo express | Température, pluie à venir, prochaine heure utile | Observé [D]; ville et fournisseur météo |
| 8 | Stats ordinateur | CPU, mémoire et réseau | Observé [A]; collecteur du Companion à développer |
| 9 | Homelab | Serveurs disponibles, stockage, UPS, alertes | Observé [E]; connecteurs à sélectionner |
| 10 | Build / déploiement | Projet, build en cours, succès ou échec | Proposition; GitHub Actions ou webhook |
| 11 | Impression 3D | Progression, temps restant, températures | Observé [F]; intégration selon marque/modèle |
| 12 | Créateur YouTube | Abonnés, vues, objectif, dernière vidéo | Observé [A]; clé API et limites de précision |
| 13 | Live / Twitch | En direct, spectateurs, durée du stream | Proposition; authentification et API Twitch |
| 14 | Scènes de la maison | Lumières, scène bureau, mode soirée | Observé [B]; Home Assistant ou connecteurs dédiés |
| 15 | Air intérieur | CO₂, humidité, température | Observé [D]; capteurs déjà accessibles sur le réseau |
| 16 | Énergie | Production solaire et import/export | Observé [D]; intégration énergie existante |
| 17 | Véhicule électrique | Charge, autonomie disponible, rappel de branchement | Observé [C]; intégration constructeur/HA |
| 18 | Prochains départs | Bus/train, destination, minutes avant départ | Observé [G]; données locales de transport |
| 19 | Score sportif | Équipe, score, période, prochain match | Observé dans l'écosystème [H]; fournisseur de données |
| 20 | Cours et devises | Valeur et variation de quelques actifs | Observé [H]; fournisseur, délai et licence à préciser |
| 21 | Maison à surveiller | Porte ouverte, garage, congélateur | Observé [D]; capteurs et acquittement tactile |
| 22 | Lessive terminée | Appareil, durée depuis la fin, effacer le rappel | Observé [D]; capteur ou automatisation existante |
| 23 | Colis | Transporteur, étape, livraison prévue | Proposition; disponibilité des API à étudier |
| 24 | Dans le ciel | Avion au-dessus de chez soi, départ et destination reliés par un arc, progression estimée, vitesse et type d'appareil | Observé [I], présentation précisée par l'utilisateur; suivi ADS-B et enrichissement du trajet |
| 25 | Pixel art / compagnon | Illustration, animation calme, petit personnage | Proposition; ressources locales, aucune API nécessaire |
| 26 | Messages du foyer | Anniversaire, rappel, petit message | Observé [D]; saisie Companion ou automatisation |

[A] [Écran de bureau à widgets, Reddit](https://www.reddit.com/r/homeoffice/comments/1s7kzh7/built_a_color_touchscreen_desk_display_with/).
[B] [Télécommande Sonos, Reddit](https://www.reddit.com/r/esp32/comments/1u9gvcp/sonos_speaker_desktop_control_panel/), [autre projet Sonos et lumières](https://www.reddit.com/r/sonos/comments/1sgphxl/built_a_desktop_control_for_my_office_sonos/).
[C] [Charge de véhicule et rappel de réunion](https://www.reddit.com/r/Rivian/comments/1rqwwan/made_a_charge_status_screenwidget_for_my_office/).
[D] [Usages quotidiens Tidbyt/AWTRIX](https://www.reddit.com/r/homeautomation/comments/1ol2690).
[E] [Dashboard homelab : suggestions d'utilisateurs](https://www.reddit.com/r/homelab/comments/1qsq0we/server_dashboard_display_board_ideas/).
[F] [BambuHelper, forum Bambu Lab](https://forum.bambulab.com/t/diy-read-only-esp32-status-display-for-bambu-printers-bambuhelper-v3-8-0/251743), [projet d'utilisateur](https://www.reddit.com/r/BambuLab/comments/1v5dkw5/i_built_a_print_status_display_printer/).
[G] [Départs ferroviaires sur LilyGO](https://www.reddit.com/r/esp32/comments/1uw49tx/uk_train_departure_board_lilygo_tseries_s3_lcd/), [besoin d'un filtrage par destination](https://www.reddit.com/r/esp32/comments/1k28gzy/esp32_based_uk_departures_board/).
[H] [Tronbyt : météo, actions et sports](https://tronbyt.com/), [catalogue communautaire](https://github.com/tronbyt/apps).
[I] [Radar ESP32, Hackaday.io](https://hackaday.io/project/206068-air-traffic-radar-using-esp32-ads-b-data).

## Modèle Déplacements : Dans le ciel

Demande précisée le 20 septembre : afficher les avions passant au-dessus du lieu choisi, avec la ville de départ à gauche, la destination à droite et un avion positionné sur un arc indiquant son avancement. Ce modèle est une proposition, pas une intégration livrée.

- **Présentation 640 × 180** : numéro de vol et compagnie en haut; villes et codes d'aéroport aux extrémités d'un arc central; silhouette d'avion sur l'arc; vitesse au sol, altitude et type d'appareil en bas. Distance horizontale au lieu choisi et âge de la dernière position dans les détails, sans surcharger la page.
- **Configuration** : sélectionner un lieu dans Companion et un rayon de détection. Le lieu reste enregistré localement; expliquer que la zone de recherche est transmise au fournisseur de positions. Choisir ensuite unités et style visuel. Les identifiants éventuels restent sur le Mac.
- **Sélection** : ignorer les appareils au sol et les positions périmées; sélectionner un appareil proche dans le rayon, en favorisant les passages à forte élévation lorsque les données nécessaires sont disponibles. Garder la sélection assez longtemps pour lire; balayage pour passer au suivant et appui pour épingler temporairement un vol. Aucun appareil détecté : message explicite ou retour à la page habituelle. Une panne du fournisseur doit rester distincte d'un ciel sans détection.
- **Bascule automatique demandée** : option « Afficher lorsqu’un avion passe dans ma zone », activable pour chaque écran. Une détection fraîche et confirmée dans la zone remplace temporairement la page active par « Dans le ciel ». Mémoriser la page précédente et l'état de sa rotation, puis les restaurer après le passage. Cette règle doit fonctionner même si le modèle avion n'est pas dans la rotation habituelle.
- **Stabilité et contrôle** : garder le même vol tant qu'il est admissible; si d'autres avions restent dans la zone à sa sortie, sélectionner le suivant sans repasser brièvement par la page précédente. Une courte temporisation et une marge de sortie évitent les allers-retours en bordure de zone ou lors d'une réception intermittente. Une perte prolongée de données affiche l'état indisponible puis rend la main, sans prétendre que l'avion a quitté la zone. Un retour manuel ferme l'interruption et empêche le même passage de reprendre immédiatement l'écran. Respecter les interactions tactiles en cours, les pages épinglées et l'horaire de nuit; ne pas réveiller un écran en veille.
- **Actualisation** : viser quelques secondes entre les positions, selon couverture, latence et quota de la source choisie; afficher leur ancienneté. Ne pas annoncer une position extrapolée comme une observation actuelle.
- **Arc** : schéma de progression, pas représentation de l'altitude ni tracé géographique réel. Placer l'avion selon une estimation calculée à partir de la position et du trajet disponible, jamais une animation arbitraire. Ne pas transformer ce pourcentage en heure d'arrivée sans données adaptées. Masquer la progression si le trajet est absent ou incohérent; indiquer « Trajet indisponible » et garder les données de vol connues.
- **Sources candidates** : [ADSB.lol](https://www.adsb.lol/docs/open-data/api/) pour le suivi public; [ADSBDB](https://github.com/mrjackwills/adsbdb) pour le type d'appareil et le départ/destination associés à l'indicatif. Leur couverture, cohérence, quotas et conditions d'utilisation doivent être vérifiés avant intégration. Une route trouvée par indicatif peut être incomplète ou ne plus correspondre au vol observé; ne pas l'afficher comme certaine sans validation.
- **Limite importante** : les données ADS-B de position ne comprennent pas à elles seules l'itinéraire commercial. [OpenSky](https://openskynetwork.github.io/opensky-api/) documente position, vitesse et identité, et distingue ces données des horaires commerciaux; ses [arrivées historiques](https://openskynetwork.github.io/opensky-api/rest.html) ne remplacent pas une destination confirmée pour le vol en cours. Une API telle que [FlightAware AeroAPI](https://www.flightaware.com/commercial/aeroapi/) peut être étudiée si une meilleure couverture des trajets est nécessaire.

Le premier prototype peut utiliser des données fictives clairement identifiées. La validation réelle demandera un lieu fourni par l'utilisateur, une comparaison avec les positions horodatées du fournisseur, les cas sans trajet/sans avion/source indisponible, puis un essai sur les deux mini-écrans. Vérifier aussi la bascule depuis une autre page, le retour à cette page avec reprise de sa rotation, plusieurs avions successifs, les oscillations en bordure, le retour manuel, l'absence de réveil nocturne et l'activation indépendante par écran.

## Les détails qui rendent le tout utilisable

- Une information principale, deux ou trois secondaires, et quelques grandes cibles tactiles par page. Concevoir pour le format 640 × 180 plutôt que réduire un dashboard de tablette.
- Navigation par balayage; rotation automatique facultative avec une durée par page et une option Épingler. Une interaction doit suspendre la rotation.
- Automatisations simples à proposer : « afficher Musique pendant la lecture », « afficher Réunion cinq minutes avant », « afficher Impression lorsqu'elle est active », « afficher Dans le ciel lorsqu'un avion entre dans ma zone ». Donner la priorité aux interactions en cours.
- Les alertes doivent proposer une durée, une priorité et un geste pour les fermer. Revenir ensuite à la page précédente. Éviter toute animation lumineuse incessante; respecter l'horaire de nuit et conserver la DEL éteinte.
- Une page non connectée affiche son état et une façon de réparer la connexion. Ne jamais faire passer des données d'exemple ou anciennes pour des valeurs réelles.
- Les comptes externes et leurs jetons restent dans le Companion; un modèle partagé contient la présentation et les références de données, jamais les secrets.
- Partage ultérieur de modèles par fichier : importer, prévisualiser, reconnecter ses propres comptes. Commencer sans marketplace ni exécution de scripts arbitraires fournis par un modèle.

## Faisabilité des intégrations citées

**Spotify.** Le widget serait une télécommande; il contrôlerait un appareil de lecture existant. Les nouvelles applications en mode développement sont limitées à cinq utilisateurs autorisés, et le propriétaire de l'application doit disposer de Premium. Une intégration personnelle est distincte d'une distribution largement accessible. Le plafond de Client IDs a été relevé à 25 en juillet 2026 : les anciennes explications qui disent encore un seul Client ID sont dépassées. [Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes), [guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide), [actualisation de juillet](https://developer.spotify.com/blog/2026-07-23-web-api-quota-updates).

**Sonos.** Contrôle de lecture, volume et groupes possible via l'API officielle authentifiée, laquelle passe par le cloud Sonos. L'intégration Home Assistant offre une autre voie, locale, si HA est déjà disponible. Ne pas présenter l'API officielle cloud comme un accès HTTP local sans compte. [API Sonos](https://docs.sonos.com/docs/control), [Home Assistant](https://www.home-assistant.io/integrations/sonos/).

**YouTube.** Le compteur public d'abonnés est arrondi à trois chiffres significatifs : ne pas vendre une précision à l'abonné près ou une actualisation instantanée. Les statistiques privées demandent un parcours distinct avec autorisation. [Documentation des chaînes](https://developers.google.com/youtube/v3/docs/channels).

**Maison, imprimantes et transport.** La présence d'un projet communautaire prouve un usage, pas la compatibilité universelle. Chaque module doit afficher ses appareils/services pris en charge et son mode de connexion. BambuHelper est notamment un écran de statut en lecture seule, pas une preuve de contrôle de toutes les imprimantes.

## Ordre proposé

1. Moteur de pages distribuées, ressources de polices/images, publication avec accusé de réception, cache local et retour à la dernière version fonctionnelle. Préparer aussi une migration USB conservant les réglages et la mise à jour du moteur par Wi-Fi.
2. Designer simple avec modèles Quotas, Météo, Horloge/Focus et les six options typographiques. Vérifier l'aperçu contre les deux écrans réels avant d'étendre le catalogue.
3. Un connecteur musique choisi selon l'usage réel et un connecteur Home Assistant, puis YouTube. Un connecteur Home Assistant peut servir à plusieurs modèles : Sonos, lumières, capteurs, énergie, imprimante ou véhicule, si les intégrations correspondantes existent déjà.
4. Catalogue plus large, conditions d'affichage et modèles partageables, guidés par les usages effectivement adoptés.

Le Designer reste simple si les connecteurs assurent la connexion, la récupération de données et les actions, pendant que les modèles règlent la présentation. Une nouvelle présentation peut réutiliser un connecteur; un nouveau service demande un vrai travail d'intégration.

## Méthode et limites

Recherche ciblée dans Reddit (esp32, sonos, homeoffice, homeassistant, homelab, BambuLab, Rivian), Home Assistant Community, Bambu Lab Community, Hackaday.io, projets GitHub et documentations officielles. Les exemples anciens sont conservés quand leur usage est pertinent; aucun classement de popularité n'est déduit des votes.

La collecte automatique last30days sur une fenêtre élargie à 180 jours a retourné quatre fils Reddit et cinq vidéos YouTube, mais peu de résultats suffisamment ciblés et aucune transcription. Elle n'est pas la base d'une affirmation de tendance. Les constatations présentées proviennent des recherches web ciblées et des sources liées ci-dessus. X/Twitter n'a pas été consulté. Aucun des connecteurs ou modules proposés n'a été installé ou testé sur les mini-écrans pendant cette recherche.
