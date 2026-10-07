# Design note: landing page для web.maicraft.tech

Статус: НЕ blocker текущей итерации. Подготовлено для следующего этапа.

## Цель

```text
https://web.maicraft.tech/  → обычная безопасная landing page в браузере
TgWeb protocol traffic      → tgwebproxy-multi (127.0.0.1:4600)
```

## Зафиксированная схема (behind_proxy=true)

tgwebproxy-multi работает с `behind_proxy=true` и на `:4600` принимает
**plaintext HTTP/WebSocket**. Поэтому обязательная цепочка — с TLS-терминацией
ДО попадания трафика в tgwebproxy-multi. Raw SNI stream напрямую на `:4600`
направлять НЕЛЬЗЯ: tgwebproxy-multi не говорит TLS, handshake умрёт.

```text
Internet :443
  → nginx stream, ssl_preread (SNI = web.maicraft.tech)
  → local TLS vhost 127.0.0.1:9443 (loopback)
  → TLS termination (тот же сертификат web.maicraft.tech)
  → HTTP routing (landing vs protocol paths)
  → tgwebproxy-multi 127.0.0.1:4600 (plaintext HTTP/WebSocket)
```

Это ровно схема `nginx-sni-reference.conf` из данного каталога и правило
«Never configure stream ssl_preread to send raw TLS directly to :4600» из
`README.md`. Landing page реализуется ТОЛЬКО на HTTP-слое, после TLS
termination — то есть в `server { listen 127.0.0.1:9443 ssl; ... }`.

## Что НЕ делать

- Не направлять raw SNI stream с `ssl_preread` непосредственно на
  `127.0.0.1:4600` — зафиксировано выше.
- Не менять `location /` на blind proxy/landing до анализа реальных путей
  протокола: можно сломать transport endpoints TgWeb.
- Не трогать существующие SNI-маршруты `connect.maicraft.tech` /
  `ru.connect.maicraft.tech` и default/fallback target stream-фронта.

## Обязательный шаг 0: инвентаризация путей tgwebproxy-multi

Выписать из исходников/конфигурации tgwebproxy-multi (и access-логов staging):

1. Все HTTP paths, которые использует TgWeb-клиент (Telegram Desktop WebProxy):
   long-poll / carrier lanes / websocket и т.п.
2. WebSocket upgrade paths, если есть.
3. Health/metrics/admin paths (admin API на 9601 — loopback-only, сюда не входит).

До получения этого списка никаких изменений nginx.

## Конфигурация (после шага 0; скелон — полная версия в nginx-sni-reference.conf)

```nginx
# --- stream context: SNI-фронт, TLS НЕ терминируется ---
# map $ssl_preread_server_name $sni_backend {
#     hostnames;
#     connect.maicraft.tech     127.0.0.1:<existing-main-backend>;
#     ru.connect.maicraft.tech  127.0.0.1:<existing-relay-backend>;
#     web.maicraft.tech         127.0.0.1:9443;   # ← local TLS vhost, НЕ :4600
#     default                   127.0.0.1:<existing-default-backend>;
# }
# server {
#     listen 443 reuseport;
#     proxy_pass $sni_backend;
#     ssl_preread on;
# }

# --- http context: TLS termination + landing + routing ---
# server {
#     listen 127.0.0.1:9443 ssl;
#     server_name web.maicraft.tech;
#     ssl_certificate     /PATH/TO/web.maicraft.tech/fullchain.pem;
#     ssl_certificate_key /PATH/TO/web.maicraft.tech/privkey.pem;
#     access_log off;  # capability/secret в URL — никогда $request_uri/$args
#
#     # Браузерный GET / → landing (после инвентаризации: только если
#     # протокол не использует GET / — иначе точечное исключение)
#     location = / {
#         root /var/www/tgweb-landing;
#         try_files /index.html =404;
#     }
#
#     # Известные протокольные пути из шага 0 → tgwebproxy-multi
#     location ~ ^/(POLL|LANE|WS|...)$ {
#         proxy_pass http://127.0.0.1:4600;
#         proxy_http_version 1.1;
#         proxy_set_header Host $host;
#         proxy_set_header Upgrade $http_upgrade;
#         proxy_set_header Connection $tgweb_connection_upgrade;
#     }
#
#     # Всё остальное — 404, неизвестное не проксируем
#     location / { return 404; }
# }
```

Альтернатива без списка путей — инверсия: проксировать всё, КРОМЕ `GET /` с
обычным браузерным User-Agent, но это хрупче (поэтому — только после шага 0).

## Landing page

- Реализуется только на HTTP-слое после TLS termination (vhost `127.0.0.1:9443`).
- Минимальная статика: «Maicraft Telegram WebProxy» + ссылка на
  основной сайт/поддержку. Копия/вариант maicraft.tech — допустимо.
- Никаких форм, логинов, PII; нормальные security headers
  (CSP default-src 'self', X-Content-Type-Options, Referrer-Policy).
- Отдельный root-каталог, чтобы не пересекаться с любыми статическими
  ресурсами протокола.
- Протестировать: `curl https://web.maicraft.tech/` → landing; реальный
  TgWeb-клиент подключается; Telegram Desktop share-link
  `https://t.me/webproxy?...` продолжает работать.

## Критерии приёмки

1. `GET /` браузером → landing page, 200 (отдаёт TLS vhost 127.0.0.1:9443).
2. Stream `ssl_preread` для web.maicraft.tech указывает на `127.0.0.1:9443`,
   а не на `:4600`; TLS терминируется на loopback vhost.
3. Все пути из инвентаризации → tgwebproxy-multi по plaintext HTTP,
   handshake проходит.
4. Неизвестные пути → 404 (не проксируются).
5. Admin API 9601 остаётся loopback-only, не затронут.
6. Нет регрессии share-link/QR flow из 0004.
