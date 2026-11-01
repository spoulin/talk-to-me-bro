# Talk to me Bro

[English](README.md) · **Français**

Lecteur d'articles pour macOS : on lui envoie un article depuis son navigateur, il l'affiche sans pub ni
mise en page (façon « Just Read ») et le **lit à voix haute**, avec la voix de macOS ou une voix Piper locale.

## Construire

```bash
scripts/build-app.sh
open "build/Talk to me Bro.app"
```

Prérequis : macOS 14+, Xcode / Swift 6. Pour l'installer, copier `build/Talk to me Bro.app` dans `/Applications`.

## Utilisation

Pour ouvrir un article :
- dans le navigateur, **Partager › Lire avec Talk to me Bro** ;
- ou glisser un lien dans la fenêtre ;
- ou copier un lien, puis ⇧⌘V.

La lecture démarre toute seule. La barre du bas montre la progression (cliquer ou glisser pour sauter
à un paragraphe), le temps restant, les commandes, la vitesse et les pauses, la voix et la taille du texte.

| Action | Raccourci |
| --- | --- |
| Lire / Pause | espace (dans l'article) ou ⌥⌘P |
| Paragraphe précédent / suivant | ← / → (dans l'article) ou ⌥⌘← / ⌥⌘→ |
| Arrêter | ⌥⌘. |
| Écouter le lien copié | ⇧⌘V |
| Ouvrir la page d'origine dans le navigateur | ⇧⌘O |
| Taille du texte | ⌘+ / ⌘- / ⌘0 |

- Pendant la lecture, cliquer un paragraphe y saute ; ⌥-clic démarre la lecture à ce paragraphe.
- Les liens de l'article s'ouvrent dans le navigateur habituel.
- **Pauses** (menu de la vitesse) : Aucune, Courtes, Moyennes (par défaut) ou Longues, après chaque
  paragraphe et, plus courtes, après chaque phrase, pour un débit moins monotone.

## Choix des voix

Deux moteurs, choisis dans le menu des voix de la barre du lecteur ; tout reste sur le Mac :

| Moteur | Qualité | Coût / compte | Confidentialité |
| --- | --- | --- | --- |
| **macOS** (par défaut) | Standard à Premium selon les voix téléchargées | Gratuit, rien à installer | Local |
| **Piper** (optionnel) | Neuronale, meilleure que les voix de base | Gratuit, sans compte | Local |

Si Piper échoue, la lecture continue avec la voix macOS. Ajouter un service de voix en ligne
(Azure, OpenAI, ElevenLabs…) = un `ClipSynthesizer` de plus, sur le modèle de `PiperSynthesizer`
(un moteur Azure complet existe dans le premier commit de l'historique git).

## Voix Piper (optionnel, local)

[Piper](https://github.com/OHF-Voice/piper1-gpl) : voix neuronales qui tournent sur le Mac.

1. **Réglages** (⌘,) → *Installer Piper* (environ 200 Mo ; nécessite Python 3.9+, par exemple
   `brew install python` ou python.org).
2. *Voix à télécharger* → choisir une voix (30 à 80 Mo), par exemple Siwis ou Tom.
3. La voix apparaît dans le menu des voix de la barre du lecteur.

- Tout est installé dans `~/Library/Application Support/local.browspeaker/piper` (environnement Python
  à part, voix, journal `piper.log`) ; *Désinstaller Piper* supprime ce dossier.
- Un petit serveur Piper local (127.0.0.1) garde la voix chargée pendant la lecture ; il s'arrête avec l'app.
- En français, Piper n'a que des voix de France (pas de voix québécoise).
- Le mot surligné est estimé (Piper ne donne pas le minutage des mots), le paragraphe est exact.

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

- `BrowserModel` : un `WKWebView` caché charge la page, un second affiche l'article épuré.
- Extraction de l'article avec [Mozilla Readability](https://github.com/mozilla/readability)
  (`Resources/Readability.js`, v0.5.0, licence Apache 2.0), exécutée dans un monde JS isolé de la page.
- La vue lecture désactive le JavaScript de la page ; seul le script de Talk to me Bro y tourne.
- `SpeechController` : état de lecture, choix de la voix et du moteur (`SpeechEngine`).
- `SystemSpeechEngine` : `AVSpeechSynthesizer`, avec la voix système (`NSSpeechSynthesizer.defaultVoice`),
  relue à chaque lecture.
- `ClipSpeechEngine` : moteurs qui produisent un fichier audio par paragraphe (Piper), avec
  préchargement du paragraphe suivant.
- Les voix **Siri** ne sont pas accessibles aux applications tierces : dans ce cas, Talk to me Bro
  prend une voix de la même langue (indiqué « remplacement » dans le menu).

L'interface est en anglais par défaut et en français si le Mac est en français
(`Resources/fr.lproj`, `ShareExtension/fr.lproj`).

Le code et les identifiants internes gardent l'ancien nom (`BrowSpeaker`, `local.browspeaker`,
`browspeaker://`) : le nom affiché peut changer sans casser le partage ni « Ouvrir avec ».
