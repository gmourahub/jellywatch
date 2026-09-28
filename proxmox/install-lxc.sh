#!/usr/bin/env bash
# Instala o stack Jellyfin Full Automation num contêiner LXC do Proxmox VE.
# Rode NO HOST Proxmox, como root, de dentro da pasta do projeto:
#
#   bash proxmox/install-lxc.sh [opções]
#
# Opções (todas opcionais):
#   --ctid N            ID do contêiner (padrão: próximo livre)
#   --hostname NOME     (padrão: jellyfin-stack)
#   --storage NOME      storage do disco raiz (padrão: local-lvm)
#   --disk GB           tamanho do disco raiz (padrão: 32)
#   --cores N           (padrão: 4)
#   --memory MB         (padrão: 4096; os 8 serviços usam ~2 GB, medido em 27/09/2026)
#   --bridge NOME       (padrão: vmbr0)
#   --ip CIDR           IP fixo, ex. 192.168.0.50/24 (padrão: dhcp)
#   --gateway IP        gateway, obrigatório com --ip
#   --media-path DIR    pasta DO HOST para mídia/downloads, montada em /mnt/data no LXC
#                       (ex.: /mnt/pve/nas/jellyfin ou /tank/media). Sem ela, fica no disco raiz.
#   --gpu               repassa /dev/dri/renderD128 para transcodificação Intel/AMD
#   --template-storage  storage dos templates (padrão: local)
set -euo pipefail

CTID=""
HOSTNAME_CT="jellyfin-stack"
STORAGE="local-lvm"
DISK=32
CORES=4
MEMORY=4096
BRIDGE="vmbr0"
IP="dhcp"
GATEWAY=""
MEDIA_PATH=""
GPU=0
TEMPLATE_STORAGE="local"
TAGS="docker;iac;jellyfin;media"
CT_DATA="/mnt/data"
CT_APP="/opt/jellywatch"
# root do LXC não privilegiado = 100000 no host; uid 1000 (PUID dos apps) = 101000
HOST_UID=101000

while [ $# -gt 0 ]; do
  case "$1" in
    --ctid) CTID="$2"; shift ;;
    --hostname) HOSTNAME_CT="$2"; shift ;;
    --storage) STORAGE="$2"; shift ;;
    --disk) DISK="$2"; shift ;;
    --cores) CORES="$2"; shift ;;
    --memory) MEMORY="$2"; shift ;;
    --bridge) BRIDGE="$2"; shift ;;
    --ip) IP="$2"; shift ;;
    --gateway) GATEWAY="$2"; shift ;;
    --media-path) MEDIA_PATH="$2"; shift ;;
    --gpu) GPU=1 ;;
    --template-storage) TEMPLATE_STORAGE="$2"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Opção desconhecida: $1" >&2; exit 1 ;;
  esac
  shift
done

msg() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }
ct() { pct exec "$CTID" -- bash -c "$1"; }

# ------------------------------------------------------------------ checagens
[ "$(id -u)" = 0 ] || die "rode como root no host Proxmox"
command -v pct >/dev/null || die "pct não encontrado: este script deve rodar no host Proxmox VE"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$PROJECT_DIR/docker-compose.yml" ] || die "docker-compose.yml não encontrado em $PROJECT_DIR"
[ "$IP" = dhcp ] || [ -n "$GATEWAY" ] || die "--ip exige --gateway"
[ -n "$CTID" ] || CTID="$(pvesh get /cluster/nextid)"
pct status "$CTID" >/dev/null 2>&1 && die "já existe um contêiner com ID $CTID"
if [ "$GPU" = 1 ]; then
  [ -e /dev/dri/renderD128 ] || die "--gpu: /dev/dri/renderD128 não existe no host"
fi

# ------------------------------------------------------------------ template
msg "Procurando template Debian"
pveam update >/dev/null
TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep -E '^debian-13-standard' | sort -V | tail -1 || true)"
[ -n "$TEMPLATE" ] || TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep -E '^debian-12-standard' | sort -V | tail -1 || true)"
[ -n "$TEMPLATE" ] || die "nenhum template Debian disponível"
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  msg "Baixando $TEMPLATE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# ------------------------------------------------------------------ contêiner
NET="name=eth0,bridge=$BRIDGE,ip=$IP"
[ -n "$GATEWAY" ] && NET="$NET,gw=$GATEWAY"
SSH_KEYS=()
[ -s /root/.ssh/authorized_keys ] && SSH_KEYS=(--ssh-public-keys /root/.ssh/authorized_keys)

msg "Criando LXC $CTID ($HOSTNAME_CT)"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME_CT" \
  --ostype debian \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap 512 \
  --rootfs "$STORAGE:$DISK" \
  --net0 "$NET" \
  --timezone host \
  --onboot 1 \
  --tags "$TAGS" \
  "${SSH_KEYS[@]}"

if [ -n "$MEDIA_PATH" ]; then
  msg "Montando $MEDIA_PATH (host) em $CT_DATA (LXC)"
  if [ ! -d "$MEDIA_PATH" ]; then
    mkdir -p "$MEDIA_PATH"
    chown "$HOST_UID:$HOST_UID" "$MEDIA_PATH"
  elif [ "$(stat -c %u "$MEDIA_PATH")" != "$HOST_UID" ]; then
    echo "AVISO: $MEDIA_PATH não pertence a $HOST_UID (uid 1000 dentro do LXC)."
    echo "       Se os apps não conseguirem gravar, rode: chown -R $HOST_UID:$HOST_UID '$MEDIA_PATH'"
  fi
  pct set "$CTID" --mp0 "$MEDIA_PATH,mp=$CT_DATA"
fi

if [ "$GPU" = 1 ]; then
  msg "Repassando GPU (/dev/dri/renderD128)"
  pct set "$CTID" --dev0 /dev/dri/renderD128,mode=0666
fi

msg "Iniciando LXC"
pct start "$CTID"
for _ in $(seq 1 60); do
  ct "getent hosts deb.debian.org" >/dev/null 2>&1 && break
  sleep 2
done
ct "getent hosts deb.debian.org" >/dev/null || die "LXC sem acesso à internet (confira bridge/IP/gateway)"

# ------------------------------------------------------------------ Docker
msg "Instalando Docker no LXC"
ct "export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null
    curl -fsSL https://get.docker.com | sh >/dev/null
    systemctl enable --now docker >/dev/null"
ct "docker compose version"

# ------------------------------------------------------------------ projeto
msg "Copiando o projeto para $CT_APP"
TMP_TAR="$(mktemp --suffix=.tgz)"
tar czf "$TMP_TAR" -C "$PROJECT_DIR" --owner=0 --group=0 --exclude=__pycache__ --exclude=.env --exclude=backup --exclude=.git .
pct push "$CTID" "$TMP_TAR" /root/jellywatch.tgz
rm -f "$TMP_TAR"
ct "mkdir -p $CT_APP && tar xzf /root/jellywatch.tgz --no-same-owner -m -C $CT_APP && rm /root/jellywatch.tgz"

if [ "$GPU" = 1 ]; then
  ct "cat > $CT_APP/docker-compose.override.yml <<'EOF'
services:
  jellyfin:
    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128
EOF"
fi

CT_IP="$(ct "ip -4 -o addr show eth0" | awk '{print $4}' | cut -d/ -f1)"
[ -n "$CT_IP" ] || die "não consegui descobrir o IP do LXC"

# Repassa credenciais opcionais do ambiente local para o scripts/init.sh do LXC (o .env não é copiado)
fwd_env() {
  local k
  for k in OPENSUBTITLES_USERNAME OPENSUBTITLES_PASSWORD; do
    [ -z "${!k:-}" ] || printf '%s=%q ' "$k" "${!k}"
  done
}

msg "Subindo o stack (download das imagens + configuração automática, alguns minutos)"
ct "cd $CT_APP && $(fwd_env)sh scripts/init.sh $CT_DATA $CT_IP --up"

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
 Projeto no LXC: $CT_APP   (pct enter $CTID)
=====================================================================
EOF
[ "$STATUS" = 0 ] || die "a configuração automática teve falhas; veja: pct exec $CTID -- docker logs jf-setup"
