# Matrix — screensaver macOS

Pluie numérique façon *Matrix* qui finit par révéler le logo Apple .
Port Swift natif de l'effet `matrix` de [TerminalTextEffects](https://github.com/ChrisBuilds/terminaltexteffects)
(MIT), l'effet utilisé par le screensaver d'Omarchy (`omarchy-screensaver` → `tte … --frame-rate 120`).

Cycle : pluie 15 s → remplissage de l'écran → résolution du logo (dégradé radial vert) → pause 10 s → on recommence.

## Prérequis

Xcode (ou les Command Line Tools) pour `swiftc`, `lipo`, `codesign`. Pas de projet Xcode :
`build.sh` compile directement avec `swiftc`. Cible macOS 12+, testé sur macOS 26 (Intel).

## Build & installation

```sh
./build.sh            # → build/Matrix.saver + build/Matrix.saver.zip (universel Intel + Apple Silicon)
./build.sh --install  # + copie dans ~/Library/Screen Savers et relance legacyScreenSaver
```

Ce que fait `build.sh` : compile une dylib par architecture, les fusionne avec `lipo`, assemble le
bundle (`Info.plist`, `Resources/`), retire les attributs étendus (`xattr -cr`, sinon `codesign` refuse :
*resource fork, Finder information… not allowed*), signe en ad hoc et zippe avec `ditto`.

**Sans compiler**, depuis la release (dépôt privé → `gh`, pas `curl`) :

```sh
gh release download -R bmarandel/matrix-screensaver -p Matrix.saver.zip -D /tmp
ditto -x -k /tmp/Matrix.saver.zip ~/Library/"Screen Savers"
```

C'est ce que fait `install-tools.sh` de [macos-config](https://github.com/bmarandel/macos-config).

**Sélection** : Réglages Système → Économiseur d'écran → **Matrix**, ou en ligne de commande avec
`macos-config/set-screensaver.py ~/Library/Screen\ Savers/Matrix.saver` (appelé par `macos-defaults.sh`).
Depuis macOS 14 le choix n'est plus dans `defaults -currentHost com.apple.screensaver` (ignoré) mais dans
`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`, une entrée `Idle` par écran et
par Space.

**Désinstaller** : `rm -rf ~/Library/"Screen Savers"/Matrix.saver; killall legacyScreenSaver`, puis
choisir un autre économiseur.

## Tester sans lancer l'économiseur

```sh
swiftc -O tools/preview.swift -o build/preview
build/preview build/Matrix.saver build/shots 3 17 23 26 44   # captures PNG à ces secondes
```

Charge le bundle hors écran (1440×900), l'anime en temps réel et mesure le rendu
(~7–11 ms/frame sur le Mac Intel : ~60 % d'un cœur à 60 fps).

## Personnaliser

- **Logo** : `Resources/logo.txt` (art en blocs `█ ▀ ▄`, dessinés en rectangles pleins).
  Régénérer la pomme : `swift tools/make-logo.swift 40 > Resources/logo.txt` (40 = largeur en colonnes).
  N'importe quel texte/ASCII-art fonctionne aussi (ex. le `logo.txt` d'Omarchy).
- **Réglages** : enum `Cfg` en tête de `Sources/MatrixSaverView.swift` (couleurs, vitesse, durée de pluie,
  durée d'affichage du logo, police — JetBrains Mono Nerd Font, repli Menlo).

## Notes techniques

- **Fidélité à TTE** : même algorithme (colonnes, `hold_time`, `drop`, `trim`, phases rain → fill → resolve)
  et mêmes valeurs par défaut. TTE tourne à `--frame-rate 120` chez Omarchy : ici 60 fps × 2 ticks
  par frame (`Cfg.ticksPerFrame`) pour garder la même vitesse.
- **Rendu** : glyphes regroupés par couleur et dessinés avec `CTFontDrawGlyphs` (repli de police
  automatique pour les katakanas demi-chasse) ; les blocs `█ ▀ ▄ ▌ ▐` sont des rectangles pleins
  sans anticrénelage, donc le logo n'a pas de jointures.
- **macOS 14+** : `legacyScreenSaver` ne libère pas les instances et continue à animer après la sortie.
  La vue écoute `com.apple.screensaver.willstop` et fait `exit(0)` (hors aperçu des Réglages).
- **Logo Apple** : `tools/make-logo.swift` rend le glyphe U+F8FF de la police système en bitmap
  puis le convertit en demi-blocs (1 colonne × ½ ligne = pixel carré), comme `omarchy-transcode-ascii`.

## Release

Le build est publié en asset de release (`Matrix.saver.zip`), installé par
[macos-config](https://github.com/bmarandel/macos-config) (`install-tools.sh`) :

```sh
./build.sh && gh release create vX.Y.Z build/Matrix.saver.zip --title vX.Y.Z --notes "…"
```

Licence MIT (voir `LICENSE`), effet porté de TerminalTextEffects.
