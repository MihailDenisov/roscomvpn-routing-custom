# 3X-UI_KIT + RoscomVPN routing

Кастомизированный установщик поверх
[itsnotkubrick/3X-UI_KIT](https://github.com/itsnotkubrick/3X-UI_KIT).

Он не заменяет 3x-ui на сторонний форк: по-прежнему ставится официальный
`MHSanaei/3x-ui v3.8.5`, как в upstream KIT.

## Что изменено

1. В настройках подписки автоматически включается штатный HAPP routing:
   - `subEnableRouting = true`
   - `subRoutingRules = https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/HAPP/DEFAULT-CUSTOM.DEEPLINK`
2. Официальный 3x-ui сам обновляет удалённые правила и хранит последнее валидное значение.
3. `kit-sub.py` пропускает наружу заголовки `Routing-Enable` и `Routing`.
4. Все остальные функции оригинального 3X-UI_KIT сохранены.

Это аналогично механизму RoscomVPN в `hydraponique/3x-ui`, но без замены официальной панели.

## Установка нового сервера

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/3x-ui.sh)
```

Все параметры оригинального установщика поддерживаются, например:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/3x-ui.sh) --protocols reality,xhttp,hy2,awg3 -y
```

## Уже установленный 3X-UI_KIT

В панели 3x-ui откройте настройки подписки / HAPP routing и задайте:

```
Enable routing: ON
Routing rules:
https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/HAPP/DEFAULT-CUSTOM.DEEPLINK
```

Если наружная подписка идёт через `kit-sub`, дополнительно замените его на версию из этого репозитория:

```bash
curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/kit-sub.py \
  -o /usr/local/lib/kit-sub/kit_sub.py
systemctl restart kit-sub
```

## Кастомные DIRECT-правила

Правила хранятся в корневом `custom-direct.json`. Сейчас там:

- `domain:maicraft.tech`
- `domain:vds.first-server.net`
- `domain:mgr.hosting-minecraft.pro`
- `domain:my.hosting-minecraft.pro`
- `157.228.189.164/32`

GitHub Actions пересобирает `HAPP/DEFAULT-CUSTOM.DEEPLINK` поверх свежего
`hydraponique/roscomvpn-routing/HAPP/DEFAULT.JSON`.


## Субдомен и fallback на обычный сайт

Для отдельного субдомена можно использовать:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/3x-ui.sh) \
  --domain connect.example.com \
  --fallback-url https://example.com \
  -y
```

Перед запуском A/AAAA-запись `connect.example.com` должна указывать на VPS.

Установщик выпустит отдельный Let's Encrypt сертификат только для
`connect.example.com` и сохранит его в:

```
/etc/letsencrypt/live/connect.example.com/
```

Существующие сертификаты `example.com` и `*.example.com` не изменяются и не копируются.

Обычный браузерный запрос на:

```
https://connect.example.com/
```

получит HTTP 302 на:

```
https://example.com/
```

При этом секретные пути панели/подписки и VPN-маршруты продолжают обслуживаться локально.
Certbot renewal включается штатным systemd timer; после успешного продления Nginx автоматически перезагружается.


## Команда `kit paths`

После установки можно одной командой посмотреть служебные URL и пути:

```bash
kit paths
```

Пример вывода:

```
Panel URL:         https://connect.example.com/<panel-path>/
Subscription base:https://connect.example.com/<sub-path>/
Subscription path:/<sub-path>/
Routing URL:       https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/HAPP/DEFAULT-CUSTOM.DEEPLINK
Fallback:          https://example.com/
Domain:            connect.example.com
```

Значения берутся из фактической установки сервера, а не захардкожены в CLI.


## AmneziaWG 3.1: порт закрыт по умолчанию

AmneziaWG 3.1 использует `8443/udp`, но установщик **не открывает этот порт в UFW автоматически**.
Inbound создаётся и остаётся готовым как резервный транспорт.

Открыть при необходимости:

```bash
ufw allow 8443/udp
```

Закрыть обратно:

```bash
ufw delete allow 8443/udp
```

Проверить:

```bash
ufw status
ss -lunp | grep ':8443 '
```

Важно: если у VPS-провайдера есть отдельный cloud firewall/security group, `8443/udp` нужно открыть/закрыть и там отдельно.


## RU relay без VPN-софта

Для промежуточного сервера можно использовать обычный L3/L4 relay на `iptables`.
На relay не ставятся 3x-ui, Xray, WireGuard, AmneziaWG, Hysteria или другие VPN/proxy-сервисы.

Схема:

```
client -> ru.connect.example.com -> RU relay -> MAIN 3x-ui VPS
```

Relay прозрачно пересылает:

```
80/tcp    -> MAIN:80      Let's Encrypt HTTP-01
443/tcp   -> MAIN:443     REALITY / XHTTP / MTProto / HTTPS / panel / subscription
443/udp   -> MAIN:443     Hysteria2
8443/udp  -> MAIN:8443    AmneziaWG 3.1
8444/udp  -> MAIN:8444    TUIC
```

### 1. DNS

Создайте A-запись:

```
ru.connect.example.com -> IPv4 RU relay
```

AAAA для relay не нужен, если используется IPv4-only режим.

### 2. Настройка relay

На RU VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/setup-relay.sh) \
  --main-ip MAIN_IPV4 \
  --relay-domain ru.connect.example.com
```

Скрипт:

- включает IPv4 forwarding;
- отключает IPv6 по умолчанию;
- создаёт отдельные idempotent iptables chains;
- разрешает локально только SSH, loopback, ICMP и DHCP renew;
- делает DNAT/SNAT/MASQUERADE для нужных TCP/UDP портов;
- устанавливает systemd unit, который восстанавливает правила после перезагрузки.

Если IPv6 на relay нужен, добавьте `--keep-ipv6`.

У провайдера relay должны быть открыты:

```
SSH/tcp
80/tcp
443/tcp
443/udp
8443/udp
8444/udp
```

### 3. Подготовка MAIN

После того как `ru.connect.example.com` уже указывает на relay и relay пересылает `80/tcp` на MAIN:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/main-relay.sh) prepare \
  --origin-domain connect.example.com \
  --relay-domain ru.connect.example.com \
  --relay-ip RELAY_IPV4
```

Режим `prepare` делает backup и расширяет существующий Let's Encrypt сертификат двумя SAN:

```
connect.example.com
ru.connect.example.com
```

Сертификат остаётся только на MAIN; relay TLS не завершает.

### 4. Переключение подписок и endpoint'ов

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/main-relay.sh) activate \
  --origin-domain connect.example.com \
  --relay-domain ru.connect.example.com \
  --relay-ip RELAY_IPV4
```

Этот режим:

- задаёт всем inbound `shareAddrStrategy=custom` и адрес relay;
- меняет `externalProxy.dest` у SINGLE/TCP inbound'ов на relay;
- меняет public subscription host на relay;
- обновляет `/etc/kit/kit.env` и `kit-sub`.

После этого обновите подписки на клиентах и проверьте REALITY, XHTTP, Hysteria2, TUIC и AmneziaWG 3.1.

Проверка состояния:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/main-relay.sh) status \
  --origin-domain connect.example.com \
  --relay-domain ru.connect.example.com
```

### 5. Закрытие прямого доступа к MAIN

Только после успешной проверки через relay:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/main-relay.sh) activate \
  --origin-domain connect.example.com \
  --relay-domain ru.connect.example.com \
  --relay-ip RELAY_IPV4 \
  --lockdown
```

`--lockdown` оставляет `80/tcp` MAIN доступным для Let's Encrypt, а `443/tcp`,
`443/udp`, `8443/udp` и `8444/udp` разрешает только с IPv4 relay.

Перед каждым изменением MAIN создаётся backup в `/root/kit-relay-backup/`.
