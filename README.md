# Talk to me Bro

Navigateur macOS minimaliste avec un **mode lecture** (façon « Just Read ») et la
**lecture à voix haute** avec la voix choisie dans
*Réglages Système › Accessibilité › Lire et énoncer* (« Read & Speak », anciennement « Contenu énoncé »).

## Construire

```bash
scripts/build-app.sh
open "build/Talk to me Bro.app"
```

Prérequis : macOS 14+, Xcode / Swift 6. Pour l'installer, copier `build/Talk to me Bro.app` dans `/Applications`.

## Utilisation

| Action | Raccourci |
| --- | --- |
| Mode lecture (article seul, sans pub ni mise en page) | ⇧⌘R ou bouton 📄 |
| Lire à voix haute / Pause | ⌥⌘P ou ▶︎ |
| Paragraphe précédent / suivant | ⌥⌘← / ⌥⌘→ |
| Arrêter | ⌥⌘. |
| Taille du texte | ⌘+ / ⌘- / ⌘0 |
| Barre d'adresse | ⌘L |

- ▶︎ sur une page normale passe automatiquement en mode lecture et commence à lire.
- En mode lecture, la lecture commence au premier paragraphe visible à l'écran.
- Pendant la lecture, cliquer un paragraphe y saute ; ⌥-clic démarre la lecture à ce paragraphe.
- Le paragraphe lu et le mot prononcé sont surlignés, et la page défile toute seule.
- Le menu « Aa » règle la vitesse (multiplicateur de la vitesse système) et la voix : « Voix du système »
  (par défaut) suit le réglage système, ou on choisit une voix installée. Les voix sont classées par
  qualité (Premium › Améliorée › Standard), d'abord celles de la langue du système, puis « Autres langues ».

## Choix des voix

Trois moteurs, choisis dans le même menu « Aa » › Voix :

| Moteur | Qualité | Coût / compte | Confidentialité |
| --- | --- | --- | --- |
| **macOS** (par défaut) | Standard à Premium selon les voix téléchargées | Gratuit, rien à installer | Local |
| **Piper** (optionnel) | Neuronale, meilleure que les voix de base | Gratuit, sans compte | Local |
| **Azure** (optionnel) | Neuronale, la plus naturelle | Compte Azure (carte demandée), niveau gratuit F0 | Texte envoyé à Microsoft |

Si Piper ou Azure échoue, la lecture continue avec la voix macOS. Ajouter un autre service
(OpenAI, ElevenLabs…) = un `ClipSynthesizer` de plus (voir `AzureClient.swift`, `PiperService.swift`).

## Voix Piper (optionnel, local)

[Piper](https://github.com/OHF-Voice/piper1-gpl) : voix neuronales qui tournent sur le Mac.

1. **Réglages** (⌘,) → *Installer Piper* (environ 200 Mo ; nécessite Python 3.9+, par exemple
   `brew install python` ou python.org).
2. *Voix à télécharger* → choisir une voix (30 à 80 Mo), par exemple Siwis ou Tom.
3. La voix apparaît dans « Aa » › Voix.

- Tout est installé dans `~/Library/Application Support/local.browspeaker/piper` (environnement Python
  à part, voix, journal `piper.log`) ; *Désinstaller Piper* supprime ce dossier.
- Un petit serveur Piper local (127.0.0.1) garde la voix chargée pendant la lecture ; il s'arrête avec l'app.
- En français, Piper n'a que des voix de France (pas de voix québécoise).
- Le mot surligné est estimé (Piper ne donne pas le minutage des mots), le paragraphe est exact.

## Voix Azure (optionnel)

Pour les voix neuronales les plus naturelles (dont des voix québécoises), on peut brancher sa propre
ressource **Azure Speech** :

1. Créer un compte Azure (https://azure.microsoft.com/free/), puis une ressource **Speech**
   (https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices) au niveau **Free F0**
   (environ 500 000 caractères par mois gratuits).
2. Dans la ressource : *Keys and Endpoint* → copier **KEY 1** et la **région** (ex. `canadaeast`).
3. Dans l'app : **Réglages** (⌘,) → coller la clé et la région → *Enregistrer et tester*.
4. Les voix Azure de la langue du système apparaissent dans le menu « Aa » › Voix.

- La clé est rangée dans le trousseau macOS, jamais dans un fichier du projet.
- Avec une voix Azure, le texte lu est envoyé à Microsoft.
- L'audio est mis en cache dans `~/Library/Caches/local.browspeaker/azure` : relire un article ne
  recompte pas dans le quota.
- Le paragraphe lu est surligné ; le mot surligné est estimé (l'API REST ne donne pas le minutage des mots).

## Partager vers Talk to me Bro

Depuis n'importe quelle app (Safari, Chrome, Mail, Notes…), menu **Partager › Lire avec Talk to me Bro** :
Talk to me Bro s'ouvre (ou passe au premier plan s'il tourne déjà), charge la page, passe en mode lecture
et commence à lire. Ça marche avec un lien, ou avec du texte qui contient un lien (c'est ce qu'envoie
Dia : l'adresse en texte, sans `https://`).

- Si l'option n'apparaît pas : *Réglages Système › Général › Ouverture et extensions › Partage*
  (ou *Partager › Modifier les extensions…*), puis cocher « Lire avec Talk to me Bro ».
- Après avoir déplacé l'app (par exemple dans `/Applications`), l'ouvrir une fois pour que macOS
  réenregistre l'extension.
- Sous le capot, l'extension ouvre `browspeaker://read?url=<adresse encodée>`. On peut utiliser ce lien
  ailleurs (Raccourcis, scripts, `open "browspeaker://read?url=…"`).

## Ouvrir avec Talk to me Bro

Clic droit › **Ouvrir avec › Talk to me Bro** dans le Finder, sur :

- un signet `.webloc` (lien glissé depuis un navigateur sur le bureau) ;
- un raccourci Windows `.url` ;
- un fichier `.html`.

Talk to me Bro se déclare aussi comme navigateur (`http`/`https`) : il peut être choisi dans
*Réglages Système › Bureau et Dock › Navigateur web par défaut* ou dans un sélecteur de navigateur,
et répond à `open -a "Talk to me Bro" https://…`. Dans tous les cas, la page s'ouvre dans la fenêtre
existante, passe en mode lecture et la lecture commence.

## Fonctionnement

- `BrowserModel` : un `WKWebView` pour naviguer et un second pour le mode lecture.
- Extraction de l'article avec [Mozilla Readability](https://github.com/mozilla/readability)
  (`Resources/Readability.js`, v0.5.0, licence Apache 2.0), exécutée dans un monde JS isolé de la page.
- La vue lecture désactive le JavaScript de la page ; seul le script de Talk to me Bro y tourne.
- `SpeechController` : état de lecture, choix de la voix et du moteur (`SpeechEngine`).
- `SystemSpeechEngine` : `AVSpeechSynthesizer`, avec la voix système (`NSSpeechSynthesizer.defaultVoice`),
  relue à chaque lecture.
- `ClipSpeechEngine` : moteurs qui produisent un fichier audio par paragraphe (Piper, Azure), avec
  préchargement du paragraphe suivant.
- Les voix **Siri** ne sont pas accessibles aux applications tierces : dans ce cas, Talk to me Bro
  prend une voix de la même langue (indiqué « remplacement » dans le menu).

Le code et les identifiants internes gardent l'ancien nom (`BrowSpeaker`, `local.browspeaker`,
`browspeaker://`) : le nom affiché peut changer sans casser le partage ni « Ouvrir avec ».
