# RoscomVPN custom routing

Кастомные правила маршрутизации для HAPP и интеграция с 3X-UI KIT.

## Что хранится в репозитории

- `custom-direct.json` — локальные DIRECT-исключения.
- `custom-proxy.json` — локальные PROXY-домены; сейчас используется для kill switch нейросетей в HAPP.
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

После изменения `custom-direct.json`, `custom-proxy.json` или `scripts/build.py` GitHub Actions пересобирает HAPP-профиль поверх актуального upstream и обновляет:

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

## Kill switch для нейросетей

Для ChatGPT/OpenAI, Claude/Anthropic, Kimi/Moonshot AI, Perplexity и Gemini включён отдельный маршрут без fallback на DIRECT. Цель — не допустить утечки пользовательского IP к этим сервисам, если VPN-узлы недоступны.

В Mihomo/FlClash домены нейросетей направляются в группу `🤖 Нейросети` типа `fallback`. Пока группа `⚡️ Авто` проходит health-check, трафик идёт через VPN. Если доступных VPN-узлов нет, следующий вариант — `REJECT-DROP`, поэтому соединение блокируется вместо выхода напрямую. Правила нейросетей расположены до DIRECT-правил Microsoft и whitelist. QUIC-блокировка `AND,((NETWORK,UDP),(DST-PORT,443)),REJECT-DROP` сохранена, чтобы браузеры переходили на TCP и доменная маршрутизация могла сработать по TLS/SNI.

В HAPP те же домены хранятся в `custom-proxy.json` и при сборке добавляются в `ProxySites`. Upstream-профиль использует `GlobalProxy=true` и удалённый DNS `8.8.8.8`, поэтому эти домены не должны уходить напрямую при недоступном VPN-узле.

Покрываются публичные домены сервисов:

- OpenAI / ChatGPT / Sora: `openai.com`, `chatgpt.com`, `oaistatic.com`, `oaiusercontent.com`, `sora.com`, точный `cdn.auth0.com`;
- Anthropic / Claude: `anthropic.com`, `claude.ai`, `claude.com`, `claudeusercontent.com`;
- Kimi / Moonshot AI: `kimi.com`, `kimi.ai`, `moonshot.cn`, `moonshot.ai`;
- Perplexity: `perplexity.ai`;
- Gemini: только `gemini.google.com`, без маршрутизации всего `google.com`.

`cdn.auth0.com` в Mihomo задан как точный `DOMAIN`, а не `DOMAIN-SUFFIX`: весь `auth0.com` не перехватывается.

### FlClash

Импортируйте обычную subscription URL из 3x-ui. Профиль с этим routing должен стоять **вторым**, сразу после базового VPN-профиля: **Профили → меню профиля → изменить порядок**. Это настраивается на стороне FlClash.

### Ручная проверка kill switch

1. Подключите профиль и убедитесь, что ChatGPT, Claude и Kimi открываются через рабочий VPN-узел.
2. Отключите или сделайте недоступными все VPN-узлы.
3. Проверьте `chatgpt.com`, `claude.ai` и `kimi.com`: соединение должно завершаться ошибкой/таймаутом. Страница «сервис недоступен в вашей стране» означает, что запрос дошёл до сервиса и kill switch следует перепроверить.
4. Верните VPN-узел — сервисы должны снова открыться.
5. Обычные российские сайты при этом должны продолжать идти по существующим DIRECT-правилам.

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

