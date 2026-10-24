// Service worker : met en cache la coquille de l'app (HTML, manifest, icônes)
// pour un démarrage rapide et un minimum de résilience hors-ligne.
// Les données (articles, mouvements) viennent toujours de Supabase en direct —
// rien ici ne les met en cache.

const CACHE_NAME = 'boutique-stock-v1';
const APP_SHELL = [
  './',
  './index.html',
  './config.js',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL))
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // Ne jamais intercepter les appels vers Supabase (API, realtime) : toujours en direct.
  if (url.hostname.endsWith('.supabase.co')) return;

  // Pour la coquille de l'app (même origine) : réseau d'abord, repli sur le cache si hors-ligne.
  if (url.origin === self.location.origin) {
    event.respondWith(
      fetch(req)
        .then((res) => {
          const resClone = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(req, resClone));
          return res;
        })
        .catch(() => caches.match(req).then((cached) => cached || caches.match('./index.html')))
    );
    return;
  }

  // Pour les ressources externes (CDN SDK Supabase, SheetJS, polices) : cache d'abord, réseau en repli.
  event.respondWith(
    caches.match(req).then((cached) => {
      if (cached) return cached;
      return fetch(req).then((res) => {
        const resClone = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(req, resClone));
        return res;
      });
    })
  );
});
