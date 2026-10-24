// Copie ce fichier en "config.js" (même dossier) et remplace les valeurs
// par celles de ton projet Supabase (Project Settings > API).
//
// "config.js" ne doit JAMAIS être commité dans Git (il est dans .gitignore) :
// pour le développement local, chacun garde sa propre copie non versionnée ;
// pour le build automatique sur GitHub Actions, ces valeurs sont injectées
// à partir des secrets du dépôt (voir .github/workflows/build.yml).
//
// La clé "anon" de Supabase est volontairement publique (visible par
// n'importe qui ouvrant l'app) : la vraie protection vient des policies RLS
// côté base de données (voir migrations/001_multi_tenant.sql), pas du secret
// de cette clé.

window.SUPABASE_URL = "https://xxxxxxxxxxxx.supabase.co";
window.SUPABASE_ANON_KEY = "ta-clé-anon-publique-ici";
