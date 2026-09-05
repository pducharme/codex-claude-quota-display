# Quota Display

Quota Display affiche les limites d’utilisation de **Codex** et de **Claude**
dans un Companion macOS et, facultativement, sur un mini-écran
**LILYGO T-Display S3 Long**.

[Télécharger la dernière version](https://github.com/pducharme/codex-claude-quota-display/releases/latest)

## Fonctionnalités

- Quotas restants sur 5 heures et sur la semaine.
- Forfaits Codex et Claude, quotas Fable et resets Codex en banque lorsque les
  fournisseurs les rendent disponibles.
- Jauges réelles accompagnées de segments indiquant où la consommation devrait
  théoriquement se situer dans la période.
- Companion natif dans la barre de menus macOS.
- Affichage au choix de Codex ou Claude, avec carte pleine largeur, fenêtre
  permanente, mode toujours au premier plan et pourcentage restant dans la
  barre des menus.
- Mode source locale ou client d’une autre instance Quota Display sur le réseau.
- Mini-écran tactile avec vue détaillée, météo sur cinq jours et actualisation
  par glissement.
- Veille quotidienne des mini-écrans, avec horaire réglable dans le Companion.
- Actualisation automatique toutes les cinq minutes.
- Relance préventive du LCD toutes les 30 minutes pour récupérer un écran noir
  sans débrancher l’ESP32.
- Mises à jour du Companion avec Sparkle, incluant les notes de version.

## Architecture

Un Mac agit comme source et garde les sessions des fournisseurs localement. Son
pont API transmet uniquement les quotas, les heures de remise à zéro et les
données météo aux autres appareils :

```text
Codex.app + Claude Desktop
            │
       Companion source
            │ API locale :8788
            ├── mini-écran ESP32
            └── autres Companions macOS
```

Le projet contient trois parties :

- `bridge/quota_menu.swift` : Companion macOS natif;
- `bridge/quota_bridge.py` : pont API local;
- `firmware/` : firmware PlatformIO du T-Display S3 Long.

## Installer le Companion macOS

### Prérequis

- macOS 13 ou une version plus récente;
- Python 3 installé dans `/opt/homebrew/bin`, `/usr/local/bin` ou `/usr/bin`;
- Codex.app et/ou Claude Desktop installés et connectés.

Téléchargez le fichier `.pkg` de la
[dernière Release](https://github.com/pducharme/codex-claude-quota-display/releases/latest),
puis ouvrez-le. Le paquet universel prend en charge Apple Silicon et Intel. Il
installe le Companion et son pont API, puis configure leur démarrage à
l’ouverture de session.

Le paquet n’est pas encore signé avec un certificat Developer ID ni notarié.
Si macOS le bloque, utilisez **clic droit → Ouvrir** ou autorisez-le dans
**Réglages Système → Confidentialité et sécurité**.

Après l’installation :

1. Ouvrez **Quota Display** dans la barre de menus.
2. Vérifiez que Codex.app est connecté avec un compte ChatGPT.
3. Dans **Connexions**, choisissez **Autoriser Claude Desktop…** si vous
   utilisez Claude. macOS peut demander l’accès à `Claude Safe Storage`.
4. Choisissez **Actualiser les quotas**.

Par défaut, le menu montre seulement le tableau de bord et une ligne
**Options**. Ce sous-menu regroupe le changement de source, la copie de la
configuration API, les fournisseurs affichés, la fenêtre permanente, le mode
toujours au premier plan, l’icône de la barre des menus, le démarrage
automatique, les mises à jour, les connexions, les informations de
l’application et la commande pour quitter.

## Utiliser une source distante

Une seule installation peut servir plusieurs mini-écrans et Companions :

1. Sur le Mac source, connectez Codex.app et Claude Desktop, puis autorisez les
   fournisseurs dans **Connexions**.
2. Choisissez **Copier la configuration API**.
3. Sur chaque Companion client, ouvrez **Source des quotas…**, puis saisissez
   l’adresse et le jeton copiés.
4. Utilisez la même adresse et le même jeton dans le portail de configuration
   des mini-écrans.

En mode distant, les connexions aux fournisseurs sont gérées uniquement par le
Mac source. L’action **Actualiser les quotas** du client demande une nouvelle
lecture à cette source. Le choix des fournisseurs affichés est aussi enregistré
sur la source : tous les Companions et mini-écrans adoptent le même affichage.

## Installer le mini-écran

Matériel pris en charge : **LILYGO T-Display S3 Long**, écran 180×640 utilisé en
mode paysage. Le firmware prend en charge le contrôleur tactile CST3530 des
révisions actuelles.

### Firmware précompilé

L’image complète se trouve dans
[`firmware/releases/quota-display-full.bin`](firmware/releases/quota-display-full.bin)
et doit être écrite à l’adresse `0x0` :

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install esptool
SERIAL_PORT=/dev/cu.usbmodemXXXX
python -m esptool --chip esp32s3 --port "$SERIAL_PORT" \
  write_flash 0x0 firmware/releases/quota-display-full.bin
```

Remplacez la valeur de `SERIAL_PORT` par le port USB détecté sur votre
ordinateur.

### Compilation depuis les sources

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install platformio
SERIAL_PORT=/dev/cu.usbmodemXXXX
cd firmware
pio run
pio run --target upload --upload-port "$SERIAL_PORT"
```

### Configuration Wi-Fi

Au premier démarrage, l’écran crée un réseau nommé `QuotaDisplay-XXXXXX`. Le
mot de passe temporaire est affiché sur le LCD.

1. Connectez un téléphone ou un ordinateur à ce réseau.
2. Ouvrez `http://192.168.4.1`.
3. Saisissez le Wi-Fi local, l’adresse du Companion source, le jeton API et la
   ville utilisée pour la météo.
4. Enregistrez. L’écran redémarre et commence sa synchronisation.

Pour rouvrir le portail et remplacer la configuration, maintenez **BOOT**
pendant trois secondes au démarrage.

## Utilisation du mini-écran

- Touchez la carte Codex pour consulter les resets en banque et leur expiration.
- Glissez vers la gauche pour afficher la météo; glissez vers la droite pour
  revenir aux quotas.
- Tirez brièvement depuis le bord supérieur pour forcer une actualisation
  Codex et Claude sur la source.
- Un point vert indique une lecture valide, orange une dernière valeur conservée
  et rouge une source indisponible.
- Lorsqu’un fournisseur est masqué ou indisponible, l’autre occupe
  automatiquement toute la largeur, sans reflash.
- `NON FOURNI` signifie que le fournisseur n’a pas retourné cette fenêtre de
  quota; l’application n’invente alors aucune valeur.

## Veille des mini-écrans

Dans **Options → Veille des mini-écrans…**, activez la veille puis choisissez
l’heure d’extinction et de réveil (23:00–07:00 proposé). Elle est désactivée
par défaut et s’applique à tous les mini-écrans liés à la source sélectionnée.
Les heures suivent le fuseau indiqué dans la fenêtre, y compris les changements
d’heure. Les deux heures doivent être différentes.

Le Companion source et le firmware des écrans doivent être mis à jour une
première fois. Ensuite, les changements d’horaire arrivent par la synchronisation
habituelle, sans reflash. Chaque écran conserve l’horaire en mémoire et l’exécute
même si le Mac dort ou si la source est temporairement indisponible.

Pendant la veille, le rétroéclairage est éteint, le LCD est au repos et les
animations, gestes et relances préventives du LCD sont suspendus. La connexion
reste active pour recevoir les modifications. Le réveil est automatique; pour
réveiller les écrans plus tôt, désactivez la veille dans le Companion.
Après une coupure d’alimentation, l’écran attend une heure valide fournie par
la source ou par NTP avant d’appliquer l’horaire.

## API locale

Le pont écoute par défaut sur le port `8788` et actualise les fournisseurs
toutes les cinq minutes.

| Méthode | Endpoint | Authentification | Rôle |
| --- | --- | --- | --- |
| `GET` | `/health` | Non | État du pont |
| `GET` | `/v1/quotas` | Jeton Bearer | Quotas et état des fournisseurs |
| `GET` | `/v1/weather?city=<ville>` | Jeton Bearer | Conditions et prévisions météo |
| `POST` | `/v1/refresh` | Jeton Bearer | Nouvelle lecture des fournisseurs |
| `POST` | `/v1/display` | Jeton Bearer | Fournisseurs visibles et horaire de veille des mini-écrans |

L’adresse et le jeton se copient depuis **Copier la configuration API** dans le
Companion.

Le pont utilise HTTP sur le réseau local. Ne redirigez pas le port `8788` vers
Internet; utilisez un réseau de confiance ou un VPN. Les jetons OpenAI et
Anthropic ne sont jamais envoyés aux écrans ni aux Companions clients.

## Développement

L’installation depuis les sources nécessite les outils de ligne de commande
Xcode :

```sh
cd bridge
./install.sh
```

Vérifications principales :

```sh
python3 bridge/test_quota_bridge.py
c++ -std=c++11 -Wall -Wextra -pedantic firmware/test_sleep.cpp -o /tmp/quota-sleep-test
/tmp/quota-sleep-test
python3 bridge/quota_bridge.py --once
```

Pour construire une Release, créez d’abord
`release-notes/<version>.html`, puis lancez :

```sh
bridge/build_pkg.sh 1.2.3
bridge/generate_appcast.sh 1.2.3
```

Le script de construction compile le Companion pour `arm64` et `x86_64`,
valide sa signature et exécute son autotest natif.

## Avis

Quota Display est un projet indépendant, sans affiliation avec OpenAI,
Anthropic ou LILYGO. Les noms et marques appartiennent à leurs propriétaires
respectifs. Les intégrations reposent sur les sessions locales des applications
et peuvent nécessiter une adaptation si leurs interfaces changent.

Consultez aussi [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), le
[dépôt matériel LilyGO](https://github.com/Xinyuan-LilyGO/T-Display-S3-Long)
et la [documentation Open-Meteo](https://open-meteo.com/en/docs).
