# RoscomVPN custom routing

Кастомные правила маршрутизации для HAPP и интеграция с 3X-UI KIT.

## Что хранится в репозитории

- `custom-direct.json` — локальные DIRECT-исключения.
- `scripts/build.py` — собирает HAPP-профиль поверх свежего upstream RoscomVPN.
- `HAPP/DEFAULT-CUSTOM.JSON` — итоговый JSON HAPP routing.
- `HAPP/DEFAULT-CUSTOM.DEEPLINK` — готовый HAPP deeplink.
- `MIHOMO/3x-ui-routing.yaml` — routing для Clash/Mihomo/FlClash, который 3x-ui подмешивает к генерируемым VPN-узлам.
- `3X-UI_KIT/` — установщик, CLI, subscription shim и relay-скрипты.

## Кастомные DIRECT-правила

Редактируйте только `custom-direct.json`.

Пример структуры:

```json
{
  "DirectSites": [
    "domain:service.example.com",
    "domain:example.net"
  ],
  "DirectIp": [
    "203.0.113.10/32"
  ]
}
```

Не добавляйте в README реальные production-домены, IP, UUID, пароли, токены подписок или пользовательские данные.

После изменения `custom-direct.json` GitHub Actions пересобирает HAPP-профиль поверх актуального upstream и обновляет:

- `HAPP/DEFAULT-CUSTOM.JSON`
- `HAPP/DEFAULT-CUSTOM.DEEPLINK`

Автообновление upstream запускается по расписанию и поддерживает ручной запуск workflow.

## HAPP

HAPP получает централизованный routing через deeplink. Профиль может содержать:

- DIRECT-категории;
- PROXY-категории;
- BLOCK-категории;
- `geosite:category-ads` для доменной блокировки рекламы;
- пользовательские DIRECT-домены/IP.

## Mihomo / FlClash

`MIHOMO/3x-ui-routing.yaml` содержит только маршрутную часть:

```yaml
proxy-groups:
rule-providers:
rules:
```

VPN-ноды, UUID, пароли, Reality-параметры и endpoint'ы генерирует 3x-ui. Благодаря этому FlClash/Mihomo получает одну обычную subscription URL с актуальными узлами и routing.

В routing включена доменная фильтрация рекламы через:

```yaml
- RULE-SET,category-ads,REJECT-DROP
```

Это блокирует рекламные/трекерные домены, но не гарантирует удаление рекламы, которая отдаётся с тех же CDN/доменов, что и основной контент.

## Telegram WEB Proxy (экспериментально)

В `3X-UI_KIT/setup-telegram-webproxy.sh` есть отдельный тестовый установщик нового Telegram WEB Proxy. Он предназначен только для отдельного чистого Ubuntu VPS и не изменяет MAIN/relay-инфраструктуру 3X-UI KIT.

Особенности:

- upstream `telegramdesktop/tproxy-server` зафиксирован на проверенном commit;
- устанавливаются Caddy, `tproxy-server` и официальный MTProxy backend;
- используются публичные `80/tcp` и `443/tcp`;
- secret генерируется автоматически, если не передан;
- для production-like теста рекомендуется свой нейтральный сайт через `--site-dir` или локальное приложение через `--site-upstream`;
- `--demo-site` предназначен только для временного стенда;
- ссылка и secret сохраняются root-only в `/root/kit-webproxy/README.txt`.

Пример тестовой установки:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/setup-telegram-webproxy.sh) \
  --hostname webproxy.example.com \
  --email admin@example.com \
  --demo-site
```

Перед запуском DNS A-запись hostname должна указывать на VPS, а firewall провайдера должен пропускать TCP/80 и TCP/443.

> Важно: Telegram WEB Proxy пока считаем экспериментальной функцией. Не используйте этот VPS для текущего 3X-UI MAIN/relay и не рассчитывайте на него как на единственный Telegram transport.

