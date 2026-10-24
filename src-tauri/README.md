# ERP Boutique — projet Tauri

Ce dossier contient la coquille Tauri (Cargo.toml, tauri.conf.json, src/)
qui embarque l'app web (`../dist/index.html` et ses fichiers associés) dans
une fenêtre native Windows/Mac.

## Méthode recommandée : build automatique via GitHub Actions

Le dépôt contient `.github/workflows/build.yml`, qui compile automatiquement
l'app pour Windows **et** Mac à chaque `git push`, sans rien installer sur ta
propre machine (GitHub fournit les machines de compilation). Voir le README
à la racine du dépôt pour la mise en route (secrets à configurer, où
récupérer les fichiers générés).

C'est la méthode à privilégier si une compilation locale pose des problèmes
de sécurité Windows (antivirus, Smart App Control, politique d'entreprise)
ou si tu veux simplement éviter d'installer Rust/Visual Studio localement.

## Méthode alternative : build local

### Windows
1. Installer [Rust](https://www.rust-lang.org/tools/install) et [Node.js](https://nodejs.org/).
2. Installer les [prérequis Tauri pour Windows](https://tauri.app/start/prerequisites/) (Visual Studio C++ Build Tools, WebView2 — déjà inclus dans Windows 10/11 à jour).
3. Depuis la racine du dépôt (celle qui contient `dist/` et `src-tauri/`) :
   ```
   npm install -g @tauri-apps/cli
   copy dist\config.example.js dist\config.js
   REM puis éditer dist\config.js avec tes vraies clés Supabase
   tauri dev     # pour tester en local
   tauri build   # pour produire l'installeur .msi / .exe
   ```

### Mac
1. Installer Rust et Node.js.
2. Installer Xcode Command Line Tools (`xcode-select --install`).
3. Mêmes commandes `tauri dev` / `tauri build` — produit un `.dmg` / `.app`.

### Linux (si jamais nécessaire plus tard)
```
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev libayatana-appindicator3-dev
tauri build
```

## État actuel du code

- `Cargo.toml` : dépendances minimales (`tauri`, `serde`) — pas encore de
  commande Rust personnalisée, la logique métier reste en JavaScript côté
  `dist/index.html` qui parle directement à Supabase.
- `tauri.conf.json` : fenêtre 1200×800 (redimensionnable, min 900×600),
  `frontendDist` pointant vers `../dist`, cibles de build = toutes celles
  pertinentes pour la plateforme de compilation (`targets: "all"`), icônes
  reprises de la version PWA + `icon.ico` pour Windows.
- `src/main.rs` / `src/lib.rs` : coquille minimale, aucune logique propre.

## Prochaine étape technique (hors phase 1)

Si un besoin apparaît que le navigateur seul ne peut pas couvrir (impression
de factures/tickets, sauvegarde locale chiffrée, notifications système),
ce sera ajouté ici comme commande `#[tauri::command]` appelée depuis le
JavaScript via `window.__TAURI__.invoke(...)`.
