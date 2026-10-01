# RoscomVPN custom routing

Кастомный HAPP-роутинг поверх актуального `hydraponique/roscomvpn-routing/HAPP/DEFAULT.JSON`.

## DIRECT-исключения

Домены:
- `maicraft.tech` — включает поддомены
- `vds.first-server.net`
- `mgr.hosting-minecraft.pro`
- `my.hosting-minecraft.pro`

IP:
- `157.228.189.164/32`

Редактируйте только `custom-direct.json`. Скрипт `scripts/build.py` загружает свежий upstream DEFAULT, добавляет кастомные `DirectSites` и `DirectIp`, удаляет дубликаты и генерирует:

- `HAPP/DEFAULT-CUSTOM.JSON`
- `HAPP/DEFAULT-CUSTOM.DEEPLINK`

GitHub Actions обновляет результат каждые 6 часов и поддерживает ручной запуск.
