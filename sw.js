var V = 'chat-v4';
var SHELL = ['./', 'index.html', 'manifest.json', 'icon-192.png', 'icon-512.png'];

self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(V).then(function (c) { return c.addAll(SHELL); }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(keys.filter(function (k) { return k !== V; }).map(function (k) { return caches.delete(k); }));
    }).then(function () { return self.clients.claim(); })
  );
});

// অ্যাপের ফাইল ও লাইব্রেরি ক্যাশ থেকে আসে (নেট ছাড়াও খুলবে), পেছনে নতুন সংস্করণ নামে।
// Supabase-এর ডেটা, মেসেজ ও মিডিয়া কখনো ক্যাশ হয় না।
self.addEventListener('fetch', function (e) {
  var r = e.request;
  if (r.method !== 'GET') return;
  var u = new URL(r.url);
  if (u.hostname.endsWith('supabase.co')) return;
  var ok = u.origin === self.location.origin || u.hostname === 'cdn.jsdelivr.net' || u.hostname === 'unpkg.com';
  if (!ok) return;
  e.respondWith(
    caches.open(V).then(function (c) {
      return c.match(r).then(function (hit) {
        var net = fetch(r).then(function (res) {
          if (res && res.ok) c.put(r, res.clone());
          return res;
        }).catch(function () { return hit; });
        return hit || net;
      });
    })
  );
});

self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  e.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (list) {
      if (list.length) return list[0].focus();
      return self.clients.openWindow('./');
    })
  );
});
