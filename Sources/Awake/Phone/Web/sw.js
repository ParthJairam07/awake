// Awake's service worker. It keeps the app's own files so the home-screen
// app opens (and says "can't reach the Mac") when the Mac is unreachable,
// and it shows web push notifications. It never stores or answers anything
// under /api/: status, screenshots and logs always come from the Mac.
const CACHE = 'awake-shell-v1';
const SHELL = ['/', '/app.js', '/app.css', '/manifest.webmanifest', '/icon-180.png', '/icon-192.png', '/icon-512.png'];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== self.location.origin || url.pathname.startsWith('/api/')) return;
  const key = url.pathname === '/index.html' ? '/' : url.pathname;
  if (!SHELL.includes(key)) return;
  // The Mac first, so a new build's files arrive as soon as it is reachable;
  // the stored copy only when it is not.
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        if (response.ok) {
          const copy = response.clone();
          caches.open(CACHE).then((cache) => cache.put(key, copy));
        }
        return response;
      })
      .catch(() => caches.match(key).then((hit) => hit || Response.error()))
  );
});

self.addEventListener('push', (event) => {
  let note = { title: 'Awake', body: '' };
  try {
    if (event.data) note = Object.assign(note, event.data.json());
  } catch (error) {
    if (event.data) note.body = event.data.text();
  }
  event.waitUntil(self.registration.showNotification(note.title || 'Awake', {
    body: note.body || '',
    icon: '/icon-192.png',
    badge: '/icon-192.png',
    tag: note.tag || undefined,
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windows) => {
      for (const client of windows) {
        if ('focus' in client) return client.focus();
      }
      return self.clients.openWindow('/');
    })
  );
});
