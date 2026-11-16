#!/usr/bin/env bash
# RoscomVPN Routing - удаление аддона. L4/stream{} не затрагивается.
set -eo pipefail

NGINX_MAIN=/etc/nginx/conf.d/01-main.conf
[ "$(id -u)" -eq 0 ] || { echo "Запустите от root."; exit 1; }

systemctl disable --now roscom-routing-update.timer 2>/dev/null || true
rm -f /etc/systemd/system/roscom-routing-update.timer
rm -f /etc/systemd/system/roscom-routing-update.service
systemctl daemon-reload

BACKUP="$NGINX_MAIN.roscom-uninst.$(date +%Y%m%d-%H%M%S)"
[ -f "$NGINX_MAIN" ] && cp -f "$NGINX_MAIN" "$BACKUP"

python3 - "$NGINX_MAIN" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
if not path.exists():
    sys.exit(0)
keep = [
    line for line in path.read_text(encoding="utf-8").splitlines()
    if "roscom-routing-headers.conf" not in line
]
path.write_text(chr(10).join(keep) + chr(10), encoding="utf-8")
print("include-строки удалены")
PY

if nginx -t; then
  systemctl reload nginx || true
else
  echo "nginx -t не прошёл - восстанавливаю $BACKUP"
  cp -f "$BACKUP" "$NGINX_MAIN"
  nginx -t && systemctl reload nginx
  exit 1
fi

rm -f /etc/nginx/snippets/roscom-routing-headers.conf
rm -f /usr/local/sbin/roscom-routing-update.sh
rm -rf /var/www/html/routing /var/lib/roscom-routing /etc/roscom-routing

echo "Аддон удалён. L4-правила и stream{} не менялись."
