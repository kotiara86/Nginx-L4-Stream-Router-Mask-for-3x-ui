# RoscomVPN Routing - аддон к Nginx-L4-Stream-Router-Mask-for-3x-ui

Клиенты получают правила маршрутизации (какие домены идут напрямую, какие через туннель, что блокируется) прямо в подписке - без ручного импорта deeplink.

Источник правил: [hydraponique/roscomvpn-routing](https://github.com/hydraponique/roscomvpn-routing).

---

## Что именно делается

Happ умеет читать профиль маршрутизации из HTTP-заголовка ответа подписки:

    Routing: happ://routing/onadd/<base64-профиль>
    Routing-Enable: true

Аддон делает три вещи и ничего больше:

1. Каждые 6 часов тянет свежие `HAPP/*.DEEPLINK`, `HAPP/*.JSON`, `INCY/*.DEEPLINK` и `MIHOMO/default.yaml`, проверяет их и кладёт в `/var/www/html/routing/` (статика уже отдаётся существующим `location /`).
2. Генерирует include-файл `/etc/nginx/snippets/roscom-routing-headers.conf` с заголовками `Routing` и `Routing-Enable` и `nginx -t` + `systemctl reload nginx`.
3. Вставляет одну строку `include` в те `location`-блоки `01-main.conf`, где есть `proxy_pass http://sub_backend;`.

## Почему пинг не растёт и скорость не падает

- **Ноль изменений в L4.** Файл `/etc/nginx/stream.d/00-stream.conf` не читается и не переписывается. SNI-роутинг, `reuseport`, сокеты Xray - как были.
- **Нет нового хопа.** Никакого дополнительного прокси между клиентом и Xray: заголовок добавляется в тот же ответ, который nginx и так отдаёт.
- **Маршрутизация клиентская.** Профиль говорит приложению, что пускать напрямую, а что в туннель. Сервер по-прежнему не занимается geoip-фильтрацией - CPU и RTT не меняются.
- **Статика без сети в горячем пути.** Обновление правил идёт по таймеру, а не в момент запроса подписки. Подписка никогда не ждёт GitHub.
- **Заголовок ~1.6 КБ.** Это ниже любых лимитов nginx и клиентов (в 3x-ui апстрим-лимит 8 КБ).

## Установка

    curl -fsSL https://raw.githubusercontent.com/kotiara86/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/addons/roscom-routing/install-roscom-routing.sh -o /tmp/install-roscom-routing.sh
    bash /tmp/install-roscom-routing.sh

Скрипт идемпотентный: повторный запуск ничего не дублирует. Перед правкой `01-main.conf` делается бэкап `01-main.conf.roscom-bak.<дата>`, и при любом падении `nginx -t` конфиг откатывается.

## После установки

1. В панели 3x-ui: **Настройки подписки -> Routing rules** - очистить поле. Заголовок теперь формирует nginx; если оставить значение в панели, клиент получит два `Routing` (аддон скрывает панельный через `proxy_hide_header`, но лучше не держать два источника правды).
2. Проверить:

       curl -sI https://ВАШ-ДОМЕН/sub/КЛЮЧ | grep -i ^routing

   В ответе должен быть `routing: happ://routing/onadd/...` и `routing-enable: true`.
3. В Happ: обновить подписку (потянуть вниз) и переподключиться - профиль применится после реконнекта.

## Профили

`/etc/roscom-routing/roscom-routing.conf`:

| ROUTING_PROFILE | Что получает клиент |
|---|---|
| `default` | RU/BY напрямую, YouTube/Telegram/GitHub через туннель, реклама и DHT блокируются |
| `whitelist` | напрямую только белые списки РФ, остальное через туннель |
| `jsonsub` | минимальный профиль: только DNS + кастомные geoip/geosite |
| `off` | заголовки не отдаются, поведение как до аддона |

После смены профиля:

    roscom-routing-update.sh

## Что получает каждый клиент

| Клиент | Как приходят правила |
|---|---|
| Happ (обычная подписка) | автоматически, заголовок `Routing` |
| INCY | вручную: `/routing/incy/<profile>.deeplink` (авто-в-теле подписки требует правки панели) |
| Mihomo / Clash Meta | вручную: `/routing/mihomo/default.yaml`, подставить URL своей подписки |
| Happ (JSON-подписка) | **не работает** авто-профиль: Happ в JSON-режиме применяет правила из конфига, а не из заголовка |

Для JSON-подписок нужен либо серверный JSONSUB-профиль (это уже патч панели, см. форк `hydraponique/3x-ui`), либо обычная подписка вместо JSON.

## Диагностика

    cat /var/log/roscom-routing.log
    systemctl list-timers roscom-routing-update.timer
    curl -s https://ВАШ-ДОМЕН/routing/meta.json

Если `failed` в `meta.json` равен 1 - источник недоступен или файл не прошёл валидацию; аддон оставляет последний рабочий профиль и ничего не ломает.

## Удаление

    curl -fsSL https://raw.githubusercontent.com/kotiara86/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/addons/roscom-routing/uninstall-roscom-routing.sh -o /tmp/uninstall-roscom-routing.sh
    bash /tmp/uninstall-roscom-routing.sh

Удаляются только include-строки, заголовки, таймер и статика. L4-правила и `stream{}` остаются нетронутыми.
