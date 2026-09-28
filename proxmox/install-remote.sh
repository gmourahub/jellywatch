#!/usr/bin/env bash
# Instala o stack num contêiner LXC do Proxmox VE a partir de QUALQUER máquina (Linux, macOS, Git Bash),
# usando a API do Proxmox (API token) + SSH no contêiner. Não precisa acessar o shell do host.
#
#   PVE_TOKEN_ID='root@pam!claude' PVE_TOKEN_SECRET='xxxx' \
#     bash proxmox/install-remote.sh --host 192.168.15.10 --media-storage data-1tb --media-size 850 --gpu
#
# O token precisa da role Administrator em "/" (pveum acl modify / --tokens 'root@pam!claude' --roles Administrator).
#
# Opções:
#   --host IP             endereço do Proxmox (obrigatório)
#   --node NOME           nó (padrão: o primeiro)
#   --ctid N              ID do contêiner (padrão: próximo livre)
#   --hostname NOME       (padrão: jellyfin-stack)
#   --storage NOME        storage do disco raiz (padrão: local-lvm)
#   --disk GB             disco raiz (padrão: 32)
#   --media-storage NOME  storage onde criar o volume de mídia (ex.: data-1tb). Sem ele, a mídia fica no disco raiz.
#   --media-size GB       tamanho do volume de mídia (padrão: 500)
#   --cores N             (padrão: 4)
#   --memory MB           (padrão: 4096; os 8 serviços usam ~2 GB, medido em 27/09/2026)
#   --bridge NOME         (padrão: vmbr0)
#   --ip CIDR --gateway IP   IP fixo (padrão: dhcp)
#   --gpu                 repassa /dev/dri/renderD128 (Intel/AMD) para o Jellyfin
#   --ssh-key ARQUIVO     chave pública SSH (padrão: ~/.ssh/id_ed25519.pub ou id_rsa.pub)
# shellcheck disable=SC2029  # comandos remotos são montados de propósito no lado local
set -euo pipefail
# Git Bash (Windows) converte argumentos "/caminho" em "C:/..." ao chamar curl; desliga isso
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

HOST="" NODE="" CTID="" HOSTNAME_CT="jellyfin-stack" STORAGE="local-lvm" DISK=32
MEDIA_STORAGE="" MEDIA_SIZE=500 CORES=4 MEMORY=4096 BRIDGE="vmbr0" IP="dhcp" GATEWAY="" GPU=0 SSH_KEY=""
CT_DATA="/mnt/data" CT_APP="/opt/jellywatch" TAGS="docker;iac;jellyfin;media"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift ;;
    --node) NODE="$2"; shift ;;
    --ctid) CTID="$2"; shift ;;
    --hostname) HOSTNAME_CT="$2"; shift ;;
    --storage) STORAGE="$2"; shift ;;
    --disk) DISK="$2"; shift ;;
    --media-storage) MEDIA_STORAGE="$2"; shift ;;
    --media-size) MEDIA_SIZE="$2"; shift ;;
    --cores) CORES="$2"; shift ;;
    --memory) MEMORY="$2"; shift ;;
    --bridge) BRIDGE="$2"; shift ;;
    --ip) IP="$2"; shift ;;
    --gateway) GATEWAY="$2"; shift ;;
    --gpu) GPU=1 ;;
    --ssh-key) SSH_KEY="$2"; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "Opção desconhecida: $1" >&2; exit 1 ;;
  esac
  shift
done

msg() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$HOST" ] || die "--host é obrigatório"
[ -n "${PVE_TOKEN_ID:-}" ] && [ -n "${PVE_TOKEN_SECRET:-}" ] || die "defina PVE_TOKEN_ID e PVE_TOKEN_SECRET"
[ "$IP" = dhcp ] || [ -n "$GATEWAY" ] || die "--ip exige --gateway"
# Primeiro Python que aceita código multilinha (no Windows, shims .bat do pyenv quebram isso)
PY=""
for cand in $(type -ap python3 python 2>/dev/null); do
  if [ "$("$cand" -c 'import sys
print("ok")' 2>/dev/null)" = ok ]; then PY="$cand"; break; fi
done
[ -n "$PY" ] || die "python3 é necessário (só para ler JSON)"
for c in curl ssh scp tar; do command -v "$c" >/dev/null || die "$c não encontrado"; done
if [ -z "$SSH_KEY" ]; then
  for k in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do [ -f "$k" ] && SSH_KEY="$k" && break; done
fi
[ -f "$SSH_KEY" ] || die "chave SSH pública não encontrada (gere com: ssh-keygen -t ed25519)"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

API="https://$HOST:8006/api2/json"
AUTH="Authorization: PVEAPIToken=$PVE_TOKEN_ID=$PVE_TOKEN_SECRET"
# api MÉTODO CAMINHO [campo=valor ...]  -> imprime o JSON; falha com a mensagem da API
api() {
  local method="$1" path="$2"; shift 2
  local args=() out code
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  out="$(curl -sk -m 120 -w '\n%{http_code}' -X "$method" -H "$AUTH" "${args[@]}" "$API$path")"
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  [ "$code" -lt 300 ] || { echo "API $method $path -> HTTP $code: $out" >&2; return 1; }
  printf '%s' "$out"
}
json() { "$PY" -c "import json,sys; d=json.load(sys.stdin)['data']; $1"; }
wait_task() {
  local upid="$1" st
  while :; do
    st="$(api GET "/nodes/$NODE/tasks/$("$PY" -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$upid")/status" |
      json 'print(d["status"], d.get("exitstatus",""))')"
    case "$st" in running*) sleep 2 ;; "stopped OK") return 0 ;; *) echo "tarefa falhou: $st" >&2; return 1 ;; esac
  done
}

# ------------------------------------------------------------------ descoberta
msg "Conectando em $HOST"
api GET /version | json 'print("Proxmox VE", d["version"])'
[ -n "$NODE" ] || NODE="$(api GET /nodes | json 'print(d[0]["node"])')"
[ -n "$CTID" ] || CTID="$(api GET /cluster/nextid | json 'print(d)')"
echo "nó: $NODE | CTID: $CTID"

# ------------------------------------------------------------------ template
msg "Procurando template Debian"
TEMPLATE="$(api GET "/nodes/$NODE/aplinfo" | json '
import re
t=sorted((x["template"] for x in d if re.match(r"debian-1[23]-standard", x["template"])),
         key=lambda s:(s.startswith("debian-13"), s))
print(t[-1] if t else "")')"
[ -n "$TEMPLATE" ] || die "nenhum template Debian disponível"
if ! api GET "/nodes/$NODE/storage/local/content?content=vztmpl" | grep -q "$TEMPLATE"; then
  msg "Baixando $TEMPLATE"
  wait_task "$(api POST "/nodes/$NODE/aplinfo" storage=local "template=$TEMPLATE" | json 'print(d)')"
fi

# ------------------------------------------------------------------ contêiner
NET="name=eth0,bridge=$BRIDGE,ip=$IP"
[ -n "$GATEWAY" ] && NET="$NET,gw=$GATEWAY"
CREATE=(vmid="$CTID" hostname="$HOSTNAME_CT" ostemplate="local:vztmpl/$TEMPLATE" ostype=debian
        unprivileged=1 cores="$CORES" memory="$MEMORY" swap=512 rootfs="$STORAGE:$DISK"
        net0="$NET" onboot=1 timezone=host nameserver=1.1.1.1 "tags=$TAGS" "ssh-public-keys=$(cat "$SSH_KEY")")
[ -n "$MEDIA_STORAGE" ] && CREATE+=(mp0="$MEDIA_STORAGE:$MEDIA_SIZE,mp=$CT_DATA,backup=0")

msg "Criando LXC $CTID ($HOSTNAME_CT)"
# keyctl só pode ser ligado pelo usuário root@pam de verdade; com token, tenta e cai para só nesting
if ! UPID="$(api POST "/nodes/$NODE/lxc" "${CREATE[@]}" features=nesting=1,keyctl=1 2>/tmp/pve-err)"; then
  grep -qi "root@pam\|permission\|feature" /tmp/pve-err || { cat /tmp/pve-err >&2; exit 1; }
  echo "(keyctl não permitido para token; criando só com nesting=1)"
  UPID="$(api POST "/nodes/$NODE/lxc" "${CREATE[@]}" features=nesting=1)"
fi
wait_task "$(echo "$UPID" | json 'print(d)')"

if [ "$GPU" = 1 ]; then
  msg "Repassando GPU (/dev/dri/renderD128)"
  api PUT "/nodes/$NODE/lxc/$CTID/config" "dev0=/dev/dri/renderD128,mode=0666" >/dev/null ||
    { echo "AVISO: não consegui repassar a GPU pelo token. No shell do Proxmox rode:"
      echo "       pct set $CTID --dev0 /dev/dri/renderD128,mode=0666 && pct reboot $CTID"; GPU=0; }
fi

msg "Iniciando LXC"
wait_task "$(api POST "/nodes/$NODE/lxc/$CTID/status/start" | json 'print(d)')"

CT_IP="${IP%%/*}"
if [ "$IP" = dhcp ]; then
  for _ in $(seq 1 60); do
    CT_IP="$(api GET "/nodes/$NODE/lxc/$CTID/interfaces" 2>/dev/null | json '
ips=[a["ip-address"] for i in d if i.get("name")=="eth0" for a in i.get("ip-addresses",[]) if a["ip-address-type"]=="inet"]
print(ips[0] if ips else "")' 2>/dev/null || true)"
    [ -n "$CT_IP" ] && break; sleep 2
  done
fi
[ -n "$CT_IP" ] && [ "$CT_IP" != dhcp ] || die "não consegui descobrir o IP do LXC"
echo "IP do LXC: $CT_IP"

# ------------------------------------------------------------------ SSH
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -i "${SSH_KEY%.pub}")
ct() { ssh "${SSH_OPTS[@]}" "root@$CT_IP" "$1"; }
for _ in $(seq 1 60); do ct true 2>/dev/null && break; sleep 3; done
ct true || die "SSH no LXC não respondeu"

msg "Instalando Docker no LXC"
ct "export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null
    command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh >/dev/null
    systemctl enable --now docker >/dev/null && docker compose version"

msg "Copiando o projeto para $CT_APP"
tar czf - -C "$PROJECT_DIR" --owner=0 --group=0 --exclude=./.env --exclude=./backup --exclude=./.git --exclude=__pycache__ . |
  ssh "${SSH_OPTS[@]}" "root@$CT_IP" "mkdir -p $CT_APP && tar xzf - --no-same-owner -m -C $CT_APP"
if [ "$GPU" = 1 ]; then
  ct "printf 'services:\n  jellyfin:\n    devices:\n      - /dev/dri/renderD128:/dev/dri/renderD128\n' > $CT_APP/docker-compose.override.yml"
fi

# Repassa credenciais opcionais do ambiente local para o scripts/init.sh do LXC (o .env não é copiado)
fwd_env() {
  local k
  for k in OPENSUBTITLES_USERNAME OPENSUBTITLES_PASSWORD; do
    [ -z "${!k:-}" ] || printf '%s=%q ' "$k" "${!k}"
  done
}

msg "Subindo o stack (download das imagens + configuração automática, alguns minutos)"
ct "mkdir -p $CT_DATA && cd $CT_APP && $(fwd_env)sh scripts/init.sh $CT_DATA $CT_IP --up"

STATUS="$(ct "docker inspect -f '{{.State.ExitCode}}' jf-setup")"
PASS="$(ct "sed -n 's/^ADMIN_PASSWORD=//p' $CT_APP/.env")"
cat <<EOF

=====================================================================
 LXC $CTID ($HOSTNAME_CT) pronto em $CT_IP
 Jellyfin    http://$CT_IP:8096      Jellyseerr  http://$CT_IP:5055
 Radarr      http://$CT_IP:7878      Sonarr      http://$CT_IP:8989
 Prowlarr    http://$CT_IP:9696      qBittorrent http://$CT_IP:8080
 Bazarr      http://$CT_IP:6767
 Login: admin / $PASS
 SSH: ssh root@$CT_IP     Projeto: $CT_APP
=====================================================================
EOF
[ "$STATUS" = 0 ] || die "a configuração automática teve falhas; veja: ssh root@$CT_IP docker logs jf-setup"
