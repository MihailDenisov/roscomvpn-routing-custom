# Design note: landing page для web.maicraft.tech

Статус: НЕ blocker текущей итерации. Подготовлено для следующего этапа.

## Цель

```text
https://web.maicraft.tech/  → обычная безопасная landing page в браузере
TgWeb protocol traffic      → tgwebproxy-multi (127.0.0.1:4600)
```

## Что НЕ делать

- Не менять `location /` на blind proxy/landing до анализа реальных путей
  протокола: можно сломать transport endpoints TgWeb.
- Не трогать существующий `ssl_preread` SNI-routing фронта.

## Обязательный шаг 0: инвентаризация путей tgwebproxy-multi

Выписать из исходников/конфигурации tgwebproxy-multi (и access-логов staging):

1. Все HTTP paths, которые использует TgWeb-клиент (Telegram Desktop WebProxy):
   long-poll / carrier lanes / websocket и т.п.
2. WebSocket upgrade paths, если есть.
3. Health/metrics/admin paths (admin API на 9601 — loopback-only, сюда не входит).

До получения этого списка никаких изменений nginx.

## Предлагаемая схема nginx (после шага 0)

```nginx
# SNI-фронт остаётся как есть: ssl_preread на web.maicraft.tech → 127.0.0.1:4600

map $request_method $tgweb_protocol_path {
    # Пример — заменить на реальный список из шага 0
    default 0;
}

server {
    listen 127.0.0.1:4600;   # или отдельный loopback порт для HTTP-терминации

    # Точное совпадение корня обычного браузера → landing
    location = / {
        root /var/www/tgweb-landing;
        try_files /index.html =404;
    }

    # Все известные протокольные пути → tgwebproxy-multi
    location ~ ^/(POLL|LANE|WS|...)$ {
        proxy_pass http://127.0.0.1:4700;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Всё остальное — 404, не проксируем неизвестное
    location / { return 404; }
}
```

Альтернатива без списка путей — инверсия: проксировать всё, КРОМЕ `GET /` с
обычным браузерным User-Agent, но это хрупче (поэтому — только после шага 0).

## Landing page

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

1. `GET /` браузером → landing page, 200.
2. Все пути из инвентаризации → tgwebproxy-multi, handshake проходит.
3. Неизвестные пути → 404 (не проксируются).
4. Admin API 9601 остаётся loopback-only, не затронут.
5. Нет регрессии share-link/QR flow из 0004.
