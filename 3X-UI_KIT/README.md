# 3X-UI_KIT + RoscomVPN routing

Кастомизированный набор скриптов поверх
[itsnotkubrick/3X-UI_KIT](https://github.com/itsnotkubrick/3X-UI_KIT).

Репозиторий не требует отдельного форка панели: используется официальный 3x-ui, а дополнительная логика находится в shell/Python-скриптах вокруг него.

> Все примеры ниже используют тестовые домены и адреса. Никогда не публикуйте production IP, домены, UUID, секреты, API-токены, subscription ID и пользовательские данные в документации.

## Компоненты

| Файл | Назначение |
|---|---|
| `3x-ui.sh` | установка/настройка 3x-ui и набора inbound'ов |
| `kit.sh` | CLI для управления пользователями |
| `kit-sub.py` | публичный subscription shim перед 3x-ui |
| `setup-relay.sh` | L3/L4 relay на отдельном VPS |
| `main-relay.sh` | переключение MAIN на работу через relay |
| `install-routing-addon.sh` | подключение routing к существующей установке |

## Поддерживаемые протоколы

Типовая конфигурация может включать:

```text
REALITY / VLESS
XHTTP
Hysteria2
Trojan
TUIC
AmneziaWG 3.x
MTProto
```

Конкретный набор задаётся установщику через `--protocols`.

## Установка MAIN

Базовая установка:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/3x-ui.sh)
```

Пример с выбранными протоколами:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/3x-ui.sh) \
  --protocols reality,xhttp,hy2,trojan,tuic,awg3,mtproto \
  -y
```

Пример установки на отдельный VPN-домен с fallback-сайтом:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/3x-ui.sh) \
  --domain vpn.example.com \
  --fallback-url https://www.example.com \
  -y
```

До запуска A-запись `vpn.example.com` должна указывать на MAIN VPS.

## Routing

### HAPP

В 3x-ui включается штатный HAPP routing:

```text
subEnableRouting = true
subRoutingRules = https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/HAPP/DEFAULT-CUSTOM.DEEPLINK
```

`kit-sub.py` пропускает наружу заголовки `Routing-Enable` и `Routing`.

### Mihomo / FlClash

Для Clash/Mihomo включаются:

```text
subClashEnable = true
subClashAutoDetect = true
subClashEnableRouting = true
subClashRules = https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/MIHOMO/3x-ui-routing.yaml
```

3x-ui генерирует VPN-ноды, а удалённый YAML добавляет только:

- `proxy-groups`;
- `rule-providers`;
- `rules`.

В routing включена блокировка рекламных доменов через `category-ads -> REJECT-DROP`.

## Управление пользователями

### Создать пользователя

```bash
kit user add USERNAME
```

С лимитами:

```bash
kit user add USERNAME --gb 50 --days 30 --devices 3
```

Значение `0` означает «без ограничения».

### Список пользователей

```bash
kit user list
```

### Subscription URL

```bash
kit user link USERNAME
```

### Дополнительные ссылки

```bash
kit user link USERNAME --all
```

Команда также выводит поддерживаемые отдельные ссылки `vpn://` и `tg://`.

В SINGLE-режиме MTProto всегда должен публиковаться через внешний TCP/443, даже если внутренний inbound слушает другой порт.

### Изменить лимиты

```bash
kit user limit USERNAME --gb 100 --days 60 --devices 2
```

### Включить / выключить

```bash
kit user off USERNAME
kit user on USERNAME
```

### Удалить

```bash
kit user del USERNAME
```

### Восстановить REALITY flow старому пользователю

```bash
kit user repair USERNAME
```

## Служебные URL

```bash
kit paths
```

Пример:

```text
Panel URL:          https://vpn.example.com/<panel-path>/
Subscription base: https://vpn.example.com/<subscription-path>/
Subscription path: /<subscription-path>/
Routing URL:        https://raw.githubusercontent.com/.../HAPP/DEFAULT-CUSTOM.DEEPLINK
Fallback:           https://www.example.com/
Domain:             vpn.example.com
```

Не публикуйте реальный вывод `kit paths`, если в нём есть секретный путь панели или другие чувствительные данные.

## Архитектура с relay

Рекомендуемая схема:

```text
Client
  ↓
entry.example.com
  ↓
L3/L4 relay
  ↓
MAIN 3x-ui VPS
  ↓
Internet
```

Relay не завершает TLS и не запускает Xray/3x-ui. Он только делает DNAT/SNAT/MASQUERADE.

Типовые пробросы:

```text
80/tcp    -> MAIN:80
443/tcp   -> MAIN:443
443/udp   -> MAIN:443
8443/udp  -> MAIN:8443
8444/udp  -> MAIN:8444
```

В SINGLE-конфигурации TCP/443 может одновременно обслуживать REALITY, XHTTP, MTProto, HTTPS, панель и подписку через SNI/stream routing на MAIN.

## Настройка relay

Создайте A-запись:

```text
entry.example.com -> RELAY_IPV4
```

Затем на relay VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/setup-relay.sh) \
  --main-ip MAIN_IPV4 \
  --relay-domain entry.example.com
```

Скрипт:

- включает IPv4 forwarding;
- по умолчанию отключает IPv6;
- создаёт отдельные idempotent iptables chains;
- разрешает локально только необходимый минимум;
- делает DNAT/SNAT/MASQUERADE;
- устанавливает systemd unit для восстановления правил после reboot.

Если IPv6 нужен:

```bash
... --keep-ipv6
```

У cloud firewall/security group relay должны быть разрешены только реально используемые входящие порты.

## Подготовка MAIN к relay

После того как DNS relay уже указывает на relay VPS и `80/tcp` корректно пересылается на MAIN:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/main-relay.sh) prepare \
  --origin-domain vpn.example.com \
  --relay-domain entry.example.com \
  --relay-ip RELAY_IPV4
```

`prepare`:

- создаёт backup;
- расширяет существующий Let's Encrypt сертификат нужными SAN;
- обновляет nginx;
- оставляет TLS termination на MAIN.

## Активация relay

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/main-relay.sh) activate \
  --origin-domain vpn.example.com \
  --relay-domain entry.example.com \
  --relay-ip RELAY_IPV4
```

`activate`:

- переводит public share/subscription endpoints на relay domain;
- обновляет `externalProxy.dest`;
- для MTProto фиксирует внешний порт `443`;
- обновляет `/etc/kit/kit.env`;
- обновляет `kit-sub.py`;
- включает Mihomo routing и ad blocking через 3x-ui.

После активации обновите subscription на тестовом клиенте и проверьте все используемые протоколы.

## Проверка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/main-relay.sh) status \
  --origin-domain vpn.example.com \
  --relay-domain entry.example.com
```

Проверьте также:

```bash
ufw status numbered
ss -lntup
```

## Lockdown MAIN

Только после успешного теста через relay:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/main-relay.sh) activate \
  --origin-domain vpn.example.com \
  --relay-domain entry.example.com \
  --relay-ip RELAY_IPV4 \
  --lockdown
```

В текущей схеме lockdown оставляет `80/tcp` доступным для Let's Encrypt, а VPN-порты разрешает только от relay IPv4.

Перед изменениями MAIN создаётся backup в:

```text
/root/kit-relay-backup/
```

## AmneziaWG

Типовая установка использует UDP-порт `8443`.

Если порт намеренно закрыт UFW и нужен прямой доступ без relay:

```bash
ufw allow 8443/udp
```

При relay+lockdown прямой публичный доступ к этому порту на MAIN обычно не нужен.

## Подписка и безопасность

Subscription URL является bearer-secret: любой, кто её получил, потенциально может скачать пользовательские конфиги.

Рекомендуется:

- только HTTPS;
- длинный случайный `subId`;
- не публиковать URL;
- не логировать полный subscription URL;
- `Cache-Control: no-store`;
- `X-Robots-Tag: noindex, nofollow, noarchive`;
- rate limit на subscription endpoint;
- возможность ротации subscription ID при утечке.

Не путайте subscription URL с URL панели: секретный путь панели и panel credentials не должны передаваться обычным пользователям.

## SSH hardening

Минимальный набор для MAIN и relay:

- вход только по SSH-ключам;
- `PasswordAuthentication no`;
- `KbdInteractiveAuthentication no`;
- `PermitRootLogin prohibit-password`;
- проверить эффективные параметры через `sshd -T`;
- настроить Fail2ban так, чтобы его chain реально стоял до разрешающего SSH-правила;
- включить unattended security updates.

Не отключайте парольный вход, пока не проверили вход по ключу во второй SSH-сессии.

## Проверка публичных endpoint'ов

После любых изменений убедитесь, что пользовательские ссылки содержат только публичный relay endpoint:

```bash
kit user link USERNAME --all
```

Для MTProto ожидается:

```text
tg://proxy?server=entry.example.com&port=443&secret=...
```

В subscription/Clash YAML не должны появляться внутренние IP MAIN, localhost-адреса или внутренние listener-порты.


### TgWebProxy WEB alongside MTProto

The WEB relay is intentionally installed as a separate service so it cannot
replace or reconfigure the existing MTProto/MTG inbound.

On a single-port 3X-UI KIT host, public TCP/443 remains owned by nginx stream.
The existing MTProto SNI route continues to use `127.0.0.1:10445`. Ordinary
HTTPS reaches the existing internal TLS frontend on `127.0.0.1:10446`, where
a dedicated `server_name` vhost forwards TgWebProxy traffic to the
loopback-only backend `127.0.0.1:4600`. Its management API is also private on
`127.0.0.1:9601`.

Install on MAIN only after a certificate for the TgWeb hostname is available:

```bash
bash 3X-UI_KIT/setup-tgwebproxy-main.sh \
  web.example.com /path/to/fullchain.pem /path/to/privkey.pem
```

The installer validates the existing `10446` HTTPS fallback, never edits
`kit-stream.conf`, never edits x-ui inbounds, and refuses to reuse occupied
backend/admin ports. Client state and traffic counters live under
`/var/lib/tgwebproxy`; the private API token is stored in
`/etc/tgwebproxy/admin.token`.


The installer also enables `kit-tgweb-reconcile.timer` (30 seconds). It treats
3x-ui and TgWebProxy traffic as one allowance: the TgWeb quota is continuously
reduced by traffic already consumed through 3x-ui, while TgWeb's own persisted
usage remains part of the same total. When combined usage reaches `totalGB`,
the TgWeb capability and that user's 3x-ui client records are disabled. The
timer only changes per-user policy; it does not stop or reconfigure MTProto/MTG.
