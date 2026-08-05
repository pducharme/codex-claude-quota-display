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
- Adresse actuelle du pont : `192.168.1.252:8788`.
- Codex et Claude répondent tous les deux correctement.

## 1. Installer le pont Mac

Cette étape est déjà effectuée sur ce Mac. Pour réinstaller ou mettre à jour le
service :

```sh
cd bridge
./install.sh
```

L’installateur affiche :

- l’adresse IP et le port du pont;
- le jeton de lecture à saisir dans l’écran;
- l’état du service.

Le pont actualise les fournisseurs toutes les cinq minutes et écoute sur le
port `8788`. Les endpoints authentifiés sont `GET /v1/quotas` et
`GET /v1/weather?city=Sherbrooke`. `POST /v1/refresh` lance immédiatement
une nouvelle lecture Codex et Claude; l’écran attend la nouvelle génération
avant de terminer son animation.

L’entrée compacte de la barre de menus affiche directement les limites
restantes **5 h / semaine** sur deux lignes, entre les icônes officielles des
applications Claude et Codex. Elle occupe environ la moitié de la largeur de
la version avec les noms complets. Son menu détaille aussi
Fable, les resets Codex, les prochaines réinitialisations et l’heure de la
dernière actualisation dans deux cartes à jauges graduées. La grande barre
indique le quota réellement restant; les cinq segments de la fenêtre 5 h et
les sept segments de la semaine indiquent le quota qui devrait théoriquement
rester selon le temps avant la réinitialisation. Le compte à rebours précise
la fenêtre concernée. Une ligne indique
aussi si l’API ESP32 est joignable et son adresse sur le réseau local. Une case
du menu contrôle le démarrage automatique du pont API à l’ouverture de la
session; le contrôleur de barre de menus reste disponible pour pouvoir la
recocher. Elle vérifie également les authentifications
toutes les cinq minutes. Si Claude n’utilise plus l’abonnement `claude.ai` ou
si Codex n’utilise plus ChatGPT, leur connexion web est relancée sur ce Mac.
Le menu permet également de reconnecter manuellement chaque fournisseur et de
forcer une actualisation des quotas. Aucun jeton fournisseur n’est copié dans
le menu ni sur l’ESP32.

Pour réafficher le jeton sans réinstaller :

```sh
/usr/bin/python3 "$HOME/Library/Application Support/Quota Display/quota_bridge.py" \
  --token-file "$HOME/Library/Application Support/Quota Display/token" \
  --show-token
```

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
3. Saisir le Wi-Fi, `192.168.1.252:8788` comme pont, le jeton obtenu avec la
   commande ci-dessus et la ville météo.
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
  actuelle en grand, une icône animée correspondant au soleil, aux nuages, à
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
arrive, réserver `192.168.1.252` dans le DHCP du routeur ou réinitialiser
l’écran et saisir la nouvelle adresse.

## Vérifications

```sh
python3 bridge/test_quota_bridge.py
python3 bridge/quota_bridge.py --once
xcrun swiftc -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library -swift-version 5 \
  -framework AppKit -framework Foundation \
  bridge/quota_menu.swift -o /tmp/QuotaDisplayMenu
/tmp/QuotaDisplayMenu --self-test
```

Sources matérielles : [dépôt officiel LilyGO](https://github.com/Xinyuan-LilyGO/T-Display-S3-Long)
et [fiche produit](https://lilygo.cc/products/t-display-s3-long). Les données
météo viennent de [l’API Open-Meteo](https://open-meteo.com/en/docs).
