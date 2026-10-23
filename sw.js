const CACHE = "treino-app-v224";
const SHELL = [
  "./",
  "./index.html",
  "./app.js",
  "./races.json",
  "./runner.json",
  "./manifest.json",
  "./icon-192.png",
  "./badge-96.png",
  "./icon-512.png",
  "./icon-mono-192.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  // Ícones das notificações vêm do cache primeiro: com sinal ruim (academia) o network-first
  // demorava e o Android mostrava o aviso do descanso com o quadrado branco no lugar do ícone.
  if (/\/(badge-96|icon-192|icon-512|icon-mono-192|icon-mono-512)\.png$/.test(new URL(req.url).pathname)) {
    event.respondWith(caches.match(req).then((cached) => cached || fetch(req)));
    return;
  }
  // Network-first for the app shell (so updates show up), cache fallback offline.
  event.respondWith(
    fetch(req, { cache: "no-store" })
      .then((res) => {
        const copy = res.clone();
        caches.open(CACHE).then((cache) => cache.put(req, copy));
        return res;
      })
      .catch(() => caches.match(req).then((cached) => cached || caches.match("./index.html")))
  );
});

// Push do servidor (edge function enviar-push): { title, body, url, tag }.
self.addEventListener("push", (event) => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch (e) { d = { body: event.data ? event.data.text() : "" }; }
  event.waitUntil(
    self.registration.showNotification(d.title || "Movo", {
      body: d.body || "",
      icon: "./icon-192.png",
      badge: "./badge-96.png",
      tag: d.tag || "movo",
      data: { url: d.url || "./" },
    })
  );
});

// Aviso local do app (fim do descanso, cronômetro de bloco): a página pede e o service worker
// mostra, como no push do servidor, com o ícone do Movo em endereço absoluto.
self.addEventListener("message", (event) => {
  const d = event.data || {};
  if (d.tipo !== "notificar" || !d.title) return;
  const abs = (u) => new URL(u, self.registration.scope).href;
  event.waitUntil(
    self.registration.showNotification(d.title, {
      ...(d.opts || {}),
      icon: abs("./icon-192.png"),
      badge: abs("./badge-96.png"),
      data: { url: "./" },
    }).then(() => { if (event.ports && event.ports[0]) event.ports[0].postMessage("ok"); })
  );
});

// Toque na notificação (descanso acabou, push do servidor) foca uma aba já
// aberta do app, se tiver, ou abre uma nova — sem isso o toque só fecha a
// notificação e não leva a pessoa de volta pro treino.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || "./";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientsArr) => {
      const existing = clientsArr.find((c) => "focus" in c);
      if (existing) {
        // App já aberto: pede para abrir a tela do aviso (ex.: ?abrir=medidas) e traz para a frente.
        const m = /[?&]abrir=([a-z]+)/.exec(url);
        if (m) existing.postMessage({ tipo: "abrir", alvo: m[1] });
        return existing.focus();
      }
      return self.clients.openWindow(url);
    })
  );
});
