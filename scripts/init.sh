#!/usr/bin/env sh
# Cria o .env a partir do .env.example com chaves e senha aleatórias.
# Uso: ./scripts/init.sh [DATA_ROOT] [SERVER_HOST] [--up]
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env"
hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
# Como root (ex.: dentro de um LXC) os apps continuam rodando como 1000:1000
if [ "$(id -u)" = 0 ]; then RUN_UID=1000; RUN_GID=1000; else RUN_UID=$(id -u); RUN_GID=$(id -g); fi

UP=0
DATA_ROOT_ARG=""
SERVER_HOST_ARG=""
for a in "$@"; do
  case "$a" in
    --up) UP=1 ;;
    *) if [ -z "$DATA_ROOT_ARG" ]; then DATA_ROOT_ARG="$a"; else SERVER_HOST_ARG="$a"; fi ;;
  esac
done

if [ -f "$ENV_FILE" ]; then
  echo ".env já existe; mantendo os valores dele (DATA_ROOT e SERVER_HOST da linha de comando são ignorados)."
else
  sed -e "s|^PUID=.*|PUID=$RUN_UID|" \
      -e "s|^PGID=.*|PGID=$RUN_GID|" \
      "$ROOT/.env.example" > "$ENV_FILE"
  [ -n "$DATA_ROOT_ARG" ] && sed -i.bak "s|^DATA_ROOT=.*|DATA_ROOT=$DATA_ROOT_ARG|" "$ENV_FILE"
  [ -n "$SERVER_HOST_ARG" ] && sed -i.bak "s|^SERVER_HOST=.*|SERVER_HOST=$SERVER_HOST_ARG|" "$ENV_FILE"
  echo ".env criado em $ENV_FILE"
fi

# Gera as chaves de API vazias e troca a senha de exemplo (ou vazia) por uma aleatória.
# Vale também para um .env copiado à mão do .env.example.
sed -i.bak -e "s|^RADARR_API_KEY=[[:space:]]*$|RADARR_API_KEY=$(hex 16)|" \
           -e "s|^SONARR_API_KEY=[[:space:]]*$|SONARR_API_KEY=$(hex 16)|" \
           -e "s|^PROWLARR_API_KEY=[[:space:]]*$|PROWLARR_API_KEY=$(hex 16)|" \
           -e "s|^ADMIN_PASSWORD=\(troque-esta-senha\)\{0,1\}[[:space:]]*$|ADMIN_PASSWORD=$(hex 8)|" \
           "$ENV_FILE"
rm -f "$ENV_FILE.bak"

# Credenciais opcionais vindas do ambiente (ex.: repassadas por proxmox/install-*.sh).
# awk em vez de sed: a senha pode ter | & / e outros caracteres especiais.
for k in OPENSUBTITLES_USERNAME OPENSUBTITLES_PASSWORD; do
  eval "v=\${$k:-}"
  [ -n "$v" ] || continue
  K="$k" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON[k] }
              index($0, k "=") == 1 { print k "=" v; found = 1; next } { print }
              END { if (!found) print k "=" v }' "$ENV_FILE" > "$ENV_FILE.tmp"
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  echo "$k definido a partir do ambiente"
done

DATA_ROOT="$(sed -n 's/^DATA_ROOT=//p' "$ENV_FILE")"
mkdir -p "$DATA_ROOT"
echo "DATA_ROOT: $DATA_ROOT"
grep -E '^(ADMIN_USER|ADMIN_PASSWORD)=' "$ENV_FILE"

if [ "$UP" = 1 ]; then
  cd "$ROOT"
  docker compose up -d
  docker compose logs -f setup
fi
