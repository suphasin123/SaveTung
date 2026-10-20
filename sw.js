// SaveTung service worker: keeps the app shell and CDN libraries available offline.
// Supabase API traffic is never cached, so financial data always comes from the server.
const CACHE = 'savetung-v7';
const SHELL = ['./', 'index.html', 'manifest.webmanifest', 'icon-192.png', 'icon-512.png', 'apple-touch-icon.png'];
const CDN_HOSTS = ['cdn.tailwindcss.com', 'unpkg.com', 'cdn.jsdelivr.net', 'fonts.googleapis.com', 'fonts.gstatic.com'];

self.addEventListener('install', event => {
    event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', event => {
    event.waitUntil(
        caches.keys()
            .then(keys => Promise.all(keys.filter(key => key !== CACHE).map(key => caches.delete(key))))
            .then(() => self.clients.claim())
    );
});

self.addEventListener('fetch', event => {
    const { request } = event;
    if (request.method !== 'GET') return;
    const url = new URL(request.url);

    if (url.origin === self.location.origin) {
        // App shell: prefer the network so updates arrive, fall back to cache offline.
        event.respondWith(
            fetch(request).then(response => {
                if (response.ok) {
                    const copy = response.clone();
                    caches.open(CACHE).then(cache => cache.put(request, copy));
                }
                return response;
            }).catch(() => caches.match(request).then(hit => hit || caches.match('index.html')))
        );
    } else if (CDN_HOSTS.includes(url.hostname)) {
        // Libraries and fonts: serve cached copy immediately, refresh in the background.
        event.respondWith(
            caches.open(CACHE).then(cache => cache.match(request).then(hit => {
                const refresh = fetch(request).then(response => {
                    if (response.ok || response.type === 'opaque') cache.put(request, response.clone());
                    return response;
                }).catch(() => hit);
                return hit || refresh;
            }))
        );
    }
});
