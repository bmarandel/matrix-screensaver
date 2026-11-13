# Matrix — screensaver macOS

Pluie numérique façon *Matrix* qui finit par révéler le logo Apple .
Port Swift natif de l'effet `matrix` de [TerminalTextEffects](https://github.com/ChrisBuilds/terminaltexteffects)
(MIT), l'effet utilisé par le screensaver d'Omarchy (`omarchy-screensaver` → `tte … --frame-rate 120`).

Cycle : pluie 15 s → remplissage de l'écran → résolution du logo (dégradé radial vert) → pause 10 s → on recommence.

## Build & installation

```sh
./build.sh            # → build/Matrix.saver (universel Intel + Apple Silicon)
./build.sh --install  # + copie dans ~/Library/Screen Savers
```

Puis Réglages Système → Économiseur d'écran → **Matrix**.

## Personnaliser

- **Logo** : `Resources/logo.txt` (art en blocs `█ ▀ ▄`, dessinés en rectangles pleins).
  Régénérer la pomme : `swift tools/make-logo.swift 40 > Resources/logo.txt` (40 = largeur en colonnes).
  N'importe quel texte/ASCII-art fonctionne aussi (ex. le `logo.txt` d'Omarchy).
- **Réglages** : enum `Cfg` en tête de `Sources/MatrixSaverView.swift` (couleurs, vitesse, durée de pluie,
  durée d'affichage du logo, police — JetBrains Mono Nerd Font, repli Menlo).

## Release

Le build est publié en asset de release (`Matrix.saver.zip`), installé par
[macos-config](https://github.com/bmarandel/macos-config) (`install-tools.sh`) :

```sh
./build.sh && gh release create vX.Y.Z build/Matrix.saver.zip --title vX.Y.Z --notes "…"
```

Licence MIT (voir `LICENSE`), effet porté de TerminalTextEffects.
