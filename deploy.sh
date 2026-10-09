#!/usr/bin/env bash
# WAHA single-session sender — one-file deploy.
# Copy ONLY this file to your VPS and run:  bash deploy.sh
# It pulls devlikeapro/waha + your prebuilt GHCR app image and starts everything
# on 127.0.0.1:4000. Push this repo to GitHub first so the workflow builds the image.
set -euo pipefail

# ---- config (override via env, e.g. GH_USER=leo APP_PORT=4000 bash deploy.sh) ----
APP_DIR="${APP_DIR:-$HOME/waha-single}"
GH_USER="${GH_USER:-changeme}"            # <-- your lowercase GitHub username
REPO_NAME="${REPO_NAME:-waha-single}"     # <-- your GitHub repo name
APP_IMAGE="${APP_IMAGE:-ghcr.io/$GH_USER/$REPO_NAME:latest}"
WAHA_PORT="${WAHA_PORT:-3000}"
APP_PORT="${APP_PORT:-4000}"
# If the GHCR package is private: create a classic PAT with read:packages and run:
#   GH_TOKEN=ghp_xxx bash deploy.sh
GH_TOKEN="${GH_TOKEN:-}"

WRITE_ONLY=0
if [[ "${1:-}" == "--write-only" ]]; then WRITE_ONLY=1; fi

if [[ "$APP_IMAGE" == *"changeme"* ]]; then
  echo "ERROR: set your GitHub username:  GH_USER=<you> bash deploy.sh"
  echo "   (or APP_IMAGE=ghcr.io/<you>/$REPO_NAME:latest bash deploy.sh)"
  exit 1
fi

echo "==> App dir: $APP_DIR"
echo "==> App image: $APP_IMAGE"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

echo "==> Writing docker-compose.yml"
cat > docker-compose.yml <<'DEPLOY_COMPOSE_EOF'
services:
  waha:
    image: devlikeapro/waha:latest
    env_file: .env
    volumes:
      - waha-sessions:/app/.sessions
    ports:
      - "127.0.0.1:${WAHA_PORT:-3000}:3000"
    restart: unless-stopped

  app:
    image: "${APP_IMAGE}"
    env_file: .env
    environment:
      WAHA_URL: http://waha:3000
      PORT: 3102
    ports:
      - "127.0.0.1:${APP_PORT:-4000}:3102"
    depends_on:
      - waha
    restart: unless-stopped

volumes:
  waha-sessions:
DEPLOY_COMPOSE_EOF

if [[ ! -f .env ]]; then
  echo "==> Generating .env with fresh secrets"
  randhex() { openssl rand -hex 16 2>/dev/null || tr -dc 'a-f0-9' < /dev/urandom | head -c 32; }
  API_KEY="$(randhex)"
  DASH_PASS="$(randhex)"
  cat > .env <<EOF
APP_IMAGE=$APP_IMAGE
WAHA_API_KEY=$API_KEY
WAHA_DASHBOARD_USERNAME=admin
WAHA_DASHBOARD_PASSWORD=$DASH_PASS
WHATSAPP_SWAGGER_USERNAME=admin
WHATSAPP_SWAGGER_PASSWORD=$DASH_PASS
WAHA_DASHBOARD_ENABLED=True
WHATSAPP_SWAGGER_ENABLED=True
SINGLE_SESSION=default
WAHA_PORT=$WAHA_PORT
APP_PORT=$APP_PORT
WAHA_URL=http://waha:3000
PORT=3102
EOF
else
  echo "==> .env exists, keeping it (change APP_IMAGE there to update)"
fi

if [[ "$WRITE_ONLY" == "1" ]]; then
  echo "==> --write-only: files written, skipping docker"
  exit 0
fi

command -v docker >/dev/null || { echo "ERROR: docker not found. Install docker first."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: 'docker compose' plugin not found."; exit 1; }

if [[ -n "$GH_TOKEN" ]]; then
  echo "==> Logging in to ghcr.io"
  echo "$GH_TOKEN" | docker login ghcr.io -u "$GH_USER" --password-stdin
fi

echo "==> Pulling images"
docker pull devlikeapro/waha:latest
docker pull "$APP_IMAGE"

echo "==> Starting (waha + app)"
docker compose up -d

echo "==> Waiting for app on 127.0.0.1:$APP_PORT ..."
for i in $(seq 1 30); do
  if curl -sf -o /dev/null "http://127.0.0.1:$APP_PORT/health"; then break; fi
  sleep 2
done

echo ""
echo "================ DONE ================"
echo "UI + API : http://127.0.0.1:$APP_PORT/"
echo "Send test: curl -X POST http://127.0.0.1:$APP_PORT/send -H 'Content-Type: application/json' -d '{\"phone\":\"919876543210\",\"message\":\"Hi\"}'"
echo "WAHA dash: http://127.0.0.1:$WAHA_PORT/dashboard (user admin, pass in .env)"
echo " creds  : grep -E 'API_KEY|PASSWORD' $APP_DIR/.env"
echo " logs   : cd $APP_DIR && docker compose logs -f"
echo " update : cd $APP_DIR && docker compose pull app && docker compose up -d app"
echo "Open the UI, press Start, scan the QR, then send."
