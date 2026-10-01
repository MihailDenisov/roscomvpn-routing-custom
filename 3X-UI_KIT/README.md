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
