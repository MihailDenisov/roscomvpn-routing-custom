# Интеграция с 3X-UI_KIT

Эта директория добавляет RoscomVPN/HAPP routing к оригинальному
[itsnotkubrick/3X-UI_KIT](https://github.com/itsnotkubrick/3X-UI_KIT)
без замены самой панели 3x-ui.

## Как работает

Оригинальный 3X-UI_KIT уже ставит `kit-sub.py` как reverse proxy перед подпиской 3x-ui.
Эта версия добавляет к успешным ответам подписки:

```
Routing-Enable: true
Routing: happ://routing/onadd/<base64>
```

Это тот же механизм, который использует `hydraponique/3x-ui`, но реализованный
на уровне `kit-sub`. Routing deeplink берётся из:

```
https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/HAPP/DEFAULT-CUSTOM.DEEPLINK
```

Значение кэшируется на 10 минут. При временной недоступности GitHub используется
последняя успешно загруженная версия до перезапуска `kit-sub`.

## Установка поверх уже установленного 3X-UI_KIT

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MihailDenisov/roscomvpn-routing-custom/main/3X-UI_KIT/install-routing-addon.sh)
```

Скрипт:

1. заменяет только `/usr/local/lib/kit-sub/kit_sub.py`;
2. добавляет в `/etc/kit-sub/config.json` параметры `routing_enable`, `routing_url`, `routing_ttl`;
3. перезапускает `kit-sub.service`.

Повторный запуск безопасен.

## Важно при обновлении 3X-UI_KIT

Повторный запуск оригинального установщика 3X-UI_KIT может вернуть upstream-версию
`kit-sub.py`. После обновления KIT достаточно повторно запустить addon-команду выше.
