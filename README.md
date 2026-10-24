# ERP Boutique

Application de bureau (Windows/Mac) multi-boutiques, construite avec Tauri
et Supabase. Voir le cahier des charges complet dans le document Claude
partagé pour le détail des modules et du phasage.

## Mise en route : créer le dépôt GitHub et lancer le premier build

### 1. Créer le dépôt sur GitHub

1. Va sur https://github.com/new
2. Nom du dépôt : `erp-boutique` (ou ce que tu préfères)
3. Visibilité : **Privé** (recommandé — le code métier n'a pas besoin d'être public)
4. Ne coche rien d'autre (pas de README, pas de .gitignore — on les a déjà)
5. Clique **Create repository**

GitHub affiche alors une page avec des commandes à exécuter — garde-la ouverte, l'étape 3 ci-dessous s'en sert.

### 2. Configurer les secrets Supabase (avant le premier push, pour que le tout premier build fonctionne)

1. Dans le nouveau dépôt GitHub, va dans **Settings** (onglet en haut) → **Secrets and variables** → **Actions**
2. Clique **New repository secret**, crée :
   - `SUPABASE_URL` → l'URL de ton projet Supabase (ex : `https://xxxxxxxxxxxx.supabase.co`)
   - `SUPABASE_ANON_KEY` → la clé "anon public" de ton projet Supabase

Ces deux valeurs se trouvent dans ton tableau de bord Supabase : **Project Settings → API**.

### 3. Pousser le code vers GitHub

Depuis ce dossier (`erp-boutique/`), dans un terminal :

```
git init
git add .
git commit -m "Premier commit : app ERP Boutique (Tauri)"
git branch -M main
git remote add origin https://github.com/<ton-compte>/erp-boutique.git
git push -u origin main
```

(Remplace `<ton-compte>` par ton nom d'utilisateur GitHub — la page créée à l'étape 1 donne la commande exacte avec la bonne URL, tu peux la copier-coller directement à la place.)

### 4. Suivre le build

1. Dans le dépôt GitHub, va dans l'onglet **Actions**
2. Tu verras "Build ERP Boutique (desktop)" en cours d'exécution (icône jaune qui tourne)
3. Ça prend 10 à 20 minutes (GitHub compile pour Windows ET Mac en parallèle)
4. Une fois terminé (coche verte), clique sur le run → en bas de la page, section **Artifacts** → télécharge `erp-boutique-windows` (contient le `.msi`/`.exe`) ou `erp-boutique-macos` (contient le `.dmg`)

### 5. Pour chaque mise à jour ensuite

Après toute modification du code :
```
git add .
git commit -m "Description du changement"
git push
```

Chaque push relance automatiquement le build — tu n'as plus besoin de rien installer ni configurer sur ta machine.

## Structure du projet

```
erp-boutique/
├── dist/                    → fichiers web (index.html, config.js non commité, manifest, icônes)
├── src-tauri/                → coquille Tauri (Rust) qui embarque dist/ dans une fenêtre native
├── migrations/                → scripts SQL Supabase (multi-tenant, rôles, inscription)
├── .github/workflows/build.yml → compilation automatique Windows + Mac
└── package.json
```

## Développement local (optionnel)

Si tu veux tester en local avant de pousser (pas obligatoire — GitHub Actions
suffit pour obtenir les installeurs), voir `src-tauri/README.md`.
