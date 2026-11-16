#!/usr/bin/env bash
# ============================================================================
#  RoscomVPN Routing - установщик АДДОНА к
#  Nginx-L4-Stream-Router-Mask-for-3x-ui
#
#  Принципы:
#    * только добавляет, ничего не удаляет из L4/stream{};
#    * идемпотентно: повторный запуск ничего не ломает;
#    * при ошибке nginx -t конфиг откатывается из бэкапа.
# ============================================================================
set -eo pipefail

BRANCH="$ROUTING_ADDON_BRANCH"
[ -n "$BRANCH" ] || BRANCH=main
RAW="https://raw.githubusercontent.com/kotiara86/Nginx-L4-Stream-Router-Mask-for-3x-ui/$BRANCH/addons/roscom-routing"

NGINX_MAIN=/etc/nginx/conf.d/01-main.conf
SNIPPET=/etc/nginx/snippets/roscom-routing-headers.conf

[ "$(id -u)" -eq 0 ] || { echo "Запустите от root."; exit 1; }
command -v nginx >/dev/null || { echo "nginx не найден: сначала установите основной стек."; exit 1; }
command -v python3 >/dev/null || { echo "python3 не найден."; exit 1; }
command -v curl >/dev/null || { echo "curl не найден."; exit 1; }
[ -f "$NGINX_MAIN" ] || { echo "Не найден $NGINX_MAIN - сначала установите основной стек (install.sh)."; exit 1; }

echo "[1/6] Каталоги и конфиг"
mkdir -p /etc/roscom-routing /etc/nginx/snippets /var/lib/roscom-routing
mkdir -p /var/www/html/routing/happ /var/www/html/routing/incy /var/www/html/routing/mihomo

if [ ! -f /etc/roscom-routing/roscom-routing.conf ]; then
cat > /etc/roscom-routing/roscom-routing.conf <<'EOF'
# RoscomVPN routing addon - конфигурация
# Профиль: default | whitelist | jsonsub | off
ROUTING_PROFILE=default
# Источник правил (можно указать свой форк или зеркало)
ROUTING_UPSTREAM=https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main
EOF
chmod 0644 /etc/roscom-routing/roscom-routing.conf
fi

if [ ! -f "$SNIPPET" ]; then
  echo "# roscom routing: заполнится при первом запуске roscom-routing-update.sh" > "$SNIPPET"
  chmod 0644 "$SNIPPET"
fi

echo "[2/6] Загрузка скрипта обновления"
curl -fsSL "$RAW/roscom-routing-update.sh" -o /usr/local/sbin/roscom-routing-update.sh
chmod 0755 /usr/local/sbin/roscom-routing-update.sh

echo "[3/6] Вставка include в L7-локации подписок (L4 не трогаем)"
BACKUP="$NGINX_MAIN.roscom-bak.$(date +%Y%m%d-%H%M%S)"
cp -f "$NGINX_MAIN" "$BACKUP"
python3 - "$NGINX_MAIN" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
inc = "include /etc/nginx/snippets/roscom-routing-headers.conf;"
text = path.read_text(encoding="utf-8")
if inc in text:
    print("SKIP: include уже присутствует")
    sys.exit(0)
lines = text.splitlines()
targets = []
i = 0
while i < len(lines):
    if re.match(r"^\s*location\b.*\{\s*$", lines[i]):
        depth = 1
        j = i + 1
        while j < len(lines) and depth > 0:
            depth += lines[j].count("{") - lines[j].count("}")
            j += 1
        block = chr(10).join(lines[i:j])
        if "proxy_pass http://sub_backend;" in block:
            targets.append(i)
        i = j
        continue
    i += 1
for idx in reversed(targets):
    pad = re.match(r"^(\s*)", lines[idx]).group(1) + "    "
    lines.insert(idx + 1, pad + inc)
path.write_text(chr(10).join(lines) + chr(10), encoding="utf-8")
print("PATCHED: " + str(len(targets)) + " location-блок(ов)")
PY

if nginx -t; then
  systemctl reload nginx || true
else
  echo "nginx -t не прошёл - восстанавливаю конфиг из $BACKUP"
  cp -f "$BACKUP" "$NGINX_MAIN"
  nginx -t && systemctl reload nginx
  exit 1
fi

echo "[4/6] systemd-таймер обновления (каждые 6 часов)"
cat > /etc/systemd/system/roscom-routing-update.service <<'EOF'
[Unit]
Description=RoscomVPN routing subscription headers updater
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=oneshot
Nice=10
ExecStart=/usr/local/sbin/roscom-routing-update.sh
EOF

cat > /etc/systemd/system/roscom-routing-update.timer <<'EOF'
[Unit]
Description=Periodic RoscomVPN routing refresh

[Timer]
OnBootSec=3min
OnUnitActiveSec=6h
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now roscom-routing-update.timer

echo "[5/6] Первое обновление правил"
/usr/local/sbin/roscom-routing-update.sh || echo "warn: первое обновление не удалось, смотрите /var/log/roscom-routing.log"

echo "[6/6] Проверка"
systemctl is-active roscom-routing-update.timer
ls -1 /var/www/html/routing/happ 2>/dev/null || true

cat <<'EOF'

Готово. Что дальше:
  1) В панели 3x-ui: Настройки подписки -> поле "Routing rules" очистите
     (заголовок Routing теперь формирует nginx; иначе будет дубль).
  2) Проверка заголовка:
       curl -sI https://ВАШ-ДОМЕН/sub/КЛЮЧ | grep -i ^routing
  3) Сменить профиль: правка ROUTING_PROFILE в
     /etc/roscom-routing/roscom-routing.conf, затем
       roscom-routing-update.sh
  4) Лог: /var/log/roscom-routing.log
  5) Откат: uninstall-roscom-routing.sh (или вернуть файл из 01-main.conf.roscom-bak.*)
EOF
