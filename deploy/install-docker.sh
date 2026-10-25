#!/bin/sh
# Run from the repository root on the board. Never replaces existing network/panel units.
set -eu
if [ "$(id -u)" != 0 ]; then echo 'Run with sudo sh deploy/install-docker.sh'; exit 1; fi
docker compose version >/dev/null
test -f backend/server.py
test -f deploy/corenest-host.service
if [ -e /opt/corenest ] || [ -e /etc/systemd/system/corenest-host.service ]; then
  echo 'Existing CoreNest Docker installation found. Refusing to overwrite; follow the upgrade guide.'
  exit 1
fi
if ! id a7s-companion >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin a7s-companion
fi
install -d -m 755 /opt/corenest/backend/web /opt/corenest/deploy
install -m 644 backend/*.py backend/requirements.txt /opt/corenest/backend/
install -m 644 backend/web/* /opt/corenest/backend/web/
install -m 644 Dockerfile .dockerignore compose.yaml /opt/corenest/
install -m 644 deploy/corenest-host.service /etc/systemd/system/corenest-host.service
systemctl daemon-reload
systemctl enable --now corenest-host.service
cd /opt/corenest
docker compose build --pull
docker compose up -d --wait --wait-timeout 90
echo 'CoreNest Docker server is ready on 127.0.0.1:18766. Existing 18765 service is unchanged.'
echo 'Run the pairing command from your computer to open the QR page.'
