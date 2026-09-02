# Codex + Claude Quota Display

Compteur Wi-Fi pour le **LILYGO T-Display S3 Long** (écran 180×640), affiché
en mode paysage 640×180.

Le projet contient deux composants :

- `bridge/` : service Python local qui lit les quotas des sessions Codex et
  Claude déjà connectées sur le Mac.
- `firmware/` : firmware PlatformIO de l’ESP32-S3.

Les identifiants OpenAI et Anthropic restent sur le Mac. L’écran reçoit
uniquement les quotas, les resets Codex disponibles et la météo de la ville
configurée.

## État sur ce Mac

- Le firmware est compilé et déjà flashé sur la carte connectée.
- La carte est configurée et connectée au Wi-Fi.
- Le pont tourne automatiquement avec la session macOS.
- Un menu macOS surveille les connexions Claude Max et Codex/ChatGPT.
- L’adresse actuelle du pont se copie depuis le menu macOS.
- Codex et Claude répondent tous les deux correctement.

## 1. Installer le pont Mac

Télécharger le fichier `.pkg` de la
[dernière Release](https://github.com/pducharme/codex-claude-quota-display/releases/latest),
puis l’ouvrir. Il installe le Companion, le pont API et leur démarrage
automatique. Comme cette première version n’est pas notariée, macOS peut
demander un clic droit sur le paquet, **Ouvrir**, ou une confirmation dans
**Réglages Système → Confidentialité et sécurité**.

Pour installer depuis les sources :

```sh
cd bridge
./install.sh
```

Après l’installation, ouvrir le menu **Quota Display**, puis choisir
**Copier la configuration API** pour copier l’adresse et le jeton destinés aux
mini-écrans et aux autres Companions.

Le pont actualise les fournisseurs toutes les cinq minutes et écoute sur le
port `8788`. Les endpoints authentifiés sont `GET /v1/quotas` et
`GET /v1/weather?city=Sherbrooke`. `POST /v1/refresh` lance immédiatement
une nouvelle lecture Codex et Claude; l’écran attend la nouvelle génération
avant de terminer son animation.

L’entrée compacte de la barre de menus affiche directement les limites
restantes **5 h / semaine** sur deux lignes, entre les icônes officielles des
applications Claude et Codex. Son menu reprend le look du mini-écran dans
deux cartes côte à côte et conserve les commandes macOS dessous. La grande
jauge indique le quota réellement restant; les cinq segments de la fenêtre
5 h et les sept segments de la vraie semaine indiquent le niveau qui devrait
théoriquement rester selon le temps avant la réinitialisation. Le menu affiche
aussi Fable, les resets Codex, les comptes à rebours, l’heure de la dernière
actualisation et l’état de l’API.

**Source des quotas…** permet d’utiliser soit l’API de ce Mac, soit une API
distante avec la même adresse et le même jeton qu’un mini-écran. En mode
distant, le Companion ne demande pas de reconnecter Codex ou Claude localement;
**Actualiser les quotas** déclenche l’actualisation sur le Mac source. La case
du menu contrôle toujours le démarrage automatique du pont API local à
l’ouverture de la session. En mode local, le Companion vérifie les
authentifications toutes les cinq minutes et permet de reconnecter chaque
fournisseur. Il utilise directement Codex.app et, après une autorisation
explicite dans **Connexions**, la session de Claude Desktop. Le jeton Claude
reste en mémoire; seul un cache local des pourcentages et des heures de remise
à zéro est écrit sur disque. Aucun jeton fournisseur n’est envoyé au pont API
ni à l’ESP32.

### Utiliser le Mac mini comme source

1. Installer le paquet de la Release sur le Mac mini, ouvrir Codex.app et
   Claude Desktop, puis connecter les deux applications.
2. Dans **Connexions**, choisir **Autoriser Claude Desktop…**. macOS demande
   l’accès à `Claude Safe Storage`; cette autorisation remplace l’installation
   de Claude Code en ligne de commande. La CLI reste seulement un repli si elle
   est déjà présente.
3. Sur le MBP, ouvrir **Source des quotas…** et saisir l’adresse `IP:8788` et
   le jeton affichés par le Mac mini.
4. Décocher **Démarrer l’API avec la session** sur le MBP si son pont local ne
   sert plus.
5. Configurer les mini-écrans avec cette même adresse et ce même jeton.

Pour construire le paquet universel Intel + Apple Silicon :

```sh
bridge/build_pkg.sh 1.0.7
```

À partir de la version 1.0.5, le Companion utilise le même mécanisme Sparkle 2
qu’AgentLimits. Il vérifie les mises à jour au démarrage puis toutes les 24 h;
le sous-menu **Mises à jour** permet aussi de vérifier immédiatement ou de
désactiver les vérifications automatiques. La mise à jour est téléchargée et
installée dans l’app après confirmation. Une version antérieure à la 1.0.5 doit
d’abord être remplacée une fois avec le `.pkg`; les versions suivantes pourront
l’être directement depuis le Companion.

Si la version 1.0.6 ou une version antérieure a été installée, installer la
1.0.7 une fois avec le `.pkg`. Cette migration rend l’app modifiable par
l’utilisateur et retire le `KeepAlive` du menu : les prochaines mises à jour
Sparkle ne demanderont plus Touch ID et ne lanceront plus un deuxième menu.

## 2. Compiler et flasher

L’image complète déjà compilée se trouve dans
`firmware/releases/quota-display-full.bin` et se flashe à l’adresse `0x0`.
Pour reconstruire depuis les sources, installer PlatformIO puis lancer :

```sh
python3 -m pip install --user platformio
cd firmware
pio run
pio run --target upload --upload-port /dev/cu.usbmodem2101
pio device monitor --port /dev/cu.usbmodem2101 --baud 115200
```

## 3. Configurer l’écran

Au premier démarrage, l’écran crée un réseau Wi-Fi nommé
`QuotaDisplay-XXXXXX`. Le mot de passe est affiché sur l’écran.

1. Connecter un téléphone ou le Mac à ce réseau.
2. Ouvrir `http://192.168.4.1`.
3. Saisir le Wi-Fi, l’adresse et le jeton copiés depuis le Companion, puis la
   ville météo.
4. Enregistrer. L’écran redémarre et commence à se synchroniser.

Pour changer la ville ou effacer la configuration, maintenir le bouton
**BOOT** pendant trois secondes au démarrage, puis remplir de nouveau le
portail. La ville par défaut est `Sherbrooke`.

## Comportement des quotas

- L’interface utilise deux cartes couleur côte à côte, avec les pourcentages
  restants en grand.
- Les en-têtes utilisent le pictogramme terminal Codex et le petit Clawd
  pixelisé; les deux ont une animation discrète.
- Le point de chaque carte est vert lorsque le fournisseur répond, orange
  lorsque la dernière lecture est conservée et rouge lorsqu’il est hors ligne.
- Une fenêtre de 300 minutes est affichée comme `5 HEURES`.
- Une fenêtre de 10 080 minutes est affichée comme `SEMAINE`.
- Si un fournisseur ne renvoie pas une fenêtre, l’écran affiche `NON FOURNI`
  au lieu d’estimer une valeur.
- En cas de panne réseau, la dernière lecture reste visible avec un point
  rouge.
- Toucher la carte **Codex** affiche le nombre de resets en banque, leurs dates
  d’expiration et le temps restant avant chaque expiration. Toucher cette vue
  revient aux quotas.
- La carte **Codex** affiche aussi sous ses deux compteurs le nombre de resets
  en banque, des marqueurs colorés et l’expiration du prochain.
- La carte **Claude** affiche aussi une ligne compacte **Fable** sous les deux
  compteurs, avec le pourcentage restant et une mini-jauge pleine largeur.
- Glisser vers la gauche affiche la météo : `Sherbrooke, QC`, la température
  actuelle, le ressenti, une icône animée correspondant au soleil, aux nuages, à
  la pluie, à la neige ou à l’orage, puis les minimums et maximums des cinq
  prochains jours. Glisser vers la droite revient aux quotas. Les pages entrent
  et sortent avec une transition horizontale accélérée puis ralentie.
- Pour actualiser, partir du bord supérieur et tirer brièvement vers le bas.
  Aucun texte ni poignée ne réserve d’espace à l’écran; un petit spinner
  apparaît pendant le geste et reste visible jusqu’à la fin d’une vraie
  relecture Codex et Claude sur le Mac.
- Cette révision matérielle utilise le contrôleur tactile **CST3530** à
  l’adresse I²C `0x58`. Le firmware détecte et décode directement son format,
  différent de l’ancien AXS15231 documenté à `0x3B`.
- L’actualisation automatique toutes les cinq minutes reste active.

L’adresse IP du Mac peut changer après un redémarrage du routeur. Si cela
arrive, réserver l’adresse du Mac mini dans le DHCP du routeur ou réinitialiser
l’écran et saisir la nouvelle adresse.

## Vérifications

```sh
python3 bridge/test_quota_bridge.py
python3 bridge/quota_bridge.py --once
SPARKLE_ROOT=$(bridge/prepare_sparkle.sh)
xcrun swiftc -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library -swift-version 5 \
  -F "$SPARKLE_ROOT" -framework Sparkle \
  -framework AppKit -framework Foundation -framework LocalAuthentication \
  -framework Security -lsqlite3 \
  bridge/quota_menu.swift -o /tmp/QuotaDisplayMenu
DYLD_FRAMEWORK_PATH="$SPARKLE_ROOT" /tmp/QuotaDisplayMenu --self-test
```

Sources matérielles : [dépôt officiel LilyGO](https://github.com/Xinyuan-LilyGO/T-Display-S3-Long)
et [fiche produit](https://lilygo.cc/products/t-display-s3-long). Les données
météo viennent de [l’API Open-Meteo](https://open-meteo.com/en/docs).
