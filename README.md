# Jellyfin Full Automation (Docker)

Stack do guia [Jellyfin Full Automation Guide (2026)](https://jellywatch.app/blog/jellyfin-full-automation-guide-radarr-sonarr-bazarr-jellyseerr-2026),
empacotado para ser instalado com um comando e replicado em outras máquinas.

```
Jellyseerr (pedido) → Radarr/Sonarr (busca via Prowlarr) → qBittorrent (download)
   → Radarr/Sonarr (importa + renomeia, hardlink) → Bazarr (legendas) → Jellyfin (streaming)
```

## Instalação

Requisitos: Docker (Docker Desktop no Windows/macOS ou Docker Engine + compose plugin no Linux).

**Windows (PowerShell)**
```powershell
.\scripts\init.ps1 -DataRoot D:/Jellyfin/data -ServerHost 192.168.0.10 -Up
```

**Linux / macOS**
```sh
./scripts/init.sh /mnt/data 192.168.0.10 --up
```

**Proxmox VE (contêiner LXC)**: copie a pasta para o host e rode lá como root:
```sh
scp -r jellywatch root@IP-DO-PROXMOX:/root/          # a partir do seu PC
ssh root@IP-DO-PROXMOX
bash /root/jellywatch/proxmox/install-lxc.sh --media-path /tank/media --gpu
```
O script cria um LXC Debian não privilegiado com `nesting` ligado, instala o Docker, copia o projeto para
`/opt/jellywatch` e roda a instalação acima. No final, mostra o IP e a senha. Opções mais usadas:
`--ctid`, `--storage`, `--disk`, `--memory`, `--ip 192.168.0.50/24 --gateway 192.168.0.1`,
`--media-path` (pasta do host, que aparece como `/mnt/data` no LXC) e `--gpu` (Intel/AMD).
A lista completa sai com `--help`. Dentro de um LXC não privilegiado, o uid 1000 corresponde ao
**101000** no host. Uma pasta de mídia que já existe precisa pertencer a esse uid:
`chown -R 101000:101000 /tank/media`.

**Proxmox VE pela API (de qualquer computador, sem abrir o shell do host)**: crie um API token com a role
Administrator em `/` e rode no seu PC (Linux, macOS ou Git Bash no Windows):
```sh
PVE_TOKEN_ID='root@pam!claude' PVE_TOKEN_SECRET='...' \
  bash proxmox/install-remote.sh --host 192.168.15.10 --media-storage data-1tb --media-size 850 --gpu
```
Para já instalar com legendas pt-BR, passe também a conta gratuita do [OpenSubtitles.com](https://www.opensubtitles.com)
(funciona igual no `install-lxc.sh` e no `scripts/init.sh`; o `.env` local não é copiado para o LXC):
```sh
OPENSUBTITLES_USERNAME='usuario' OPENSUBTITLES_PASSWORD='senha' PVE_TOKEN_ID='root@pam!claude' PVE_TOKEN_SECRET='...' \
  bash proxmox/install-remote.sh --host 192.168.15.10 --media-storage data-1tb --media-size 850 --gpu
```
O script cria o LXC pela API, com um volume de mídia no storage escolhido montado em `/mnt/data`, instala
tudo por SSH usando a sua chave `~/.ssh/id_ed25519.pub` e mostra o IP e a senha no final. O Proxmox só
deixa o usuário `root@pam` repassar a GPU. Com um token, rode depois no shell do host:
`pct set <CTID> --dev0 /dev/dri/renderD128,mode=0666 && pct reboot <CTID>`.

O script cria o `.env` (chaves de API e senha admin aleatórias), sobe os contêineres e mostra o log
do contêiner `setup`, que configura tudo sozinho. Sem `-Up`/`--up` ele só gera o `.env`; depois rode
`docker compose up -d`.

A senha do admin fica em `ADMIN_PASSWORD` no `.env`. **Guarde o `.env`**: ele contém as chaves de API.

## Serviços e URLs

Troque `localhost` pelo IP da máquina (o `SERVER_HOST` do `.env`, ou o IP do LXC no Proxmox) para
abrir de outro aparelho da rede, por exemplo `http://192.168.0.10:8096`.

| Serviço | URL | Para que serve | Login |
|---|---|---|---|
| **Jellyfin** | http://localhost:8096 | Assistir filmes e séries (web, TV, celular) | `admin` / `ADMIN_PASSWORD` |
| **Jellyseerr** | http://localhost:5055 | Pedir filmes e séries e ver o status dos pedidos | conta do Jellyfin |
| **Radarr** | http://localhost:7878 | Busca, baixa, renomeia e organiza **filmes** | `admin` / `ADMIN_PASSWORD` |
| **Sonarr** | http://localhost:8989 | Busca, baixa, renomeia e organiza **séries** | `admin` / `ADMIN_PASSWORD` |
| **Prowlarr** | http://localhost:9696 | Gerencia os indexers (sites de torrent) do Radarr e do Sonarr | `admin` / `ADMIN_PASSWORD` |
| **qBittorrent** | http://localhost:8080 | Cliente de torrent que faz os downloads | `admin` / `ADMIN_PASSWORD` |
| **Bazarr** | http://localhost:6767 | Baixa legendas automaticamente | sem login |
| FlareSolverr | (sem porta publicada) | Passa pela proteção Cloudflare de alguns indexers, usado pelo Prowlarr | — |
| `init` / `setup` | (rodam uma vez e param) | Configuram tudo automaticamente | — |

Entre os contêineres, os serviços se falam pelo nome: `http://jellyfin:8096`, `http://radarr:7878`,
`http://sonarr:8989`, `http://prowlarr:9696`, `http://qbittorrent:8080`, `http://bazarr:6767`,
`http://jellyseerr:5055` e `http://flaresolverr:8191`. Use esses endereços se for ligar um
serviço a outro manualmente.

### Telas mais úteis

| Onde | O que mostra |
|---|---|
| Jellyseerr → **Requests** | pedidos e status (*Pendente*, *Processando*, *Disponível*) |
| Radarr → **Activity → Queue** | filmes baixando: progresso, tempo restante, qualidade, erros |
| Radarr → **Activity → History** | o que foi baixado e importado, e quando |
| Radarr → **Wanted → Missing** | filmes pedidos que ainda não têm arquivo |
| Sonarr → **Activity → Queue** / **Wanted → Missing** | o mesmo, por episódio |
| Prowlarr → **Indexers** | indexers ativos e se algum está com falha |
| Prowlarr → **Search** | busca manual em todos os indexers ao mesmo tempo |
| qBittorrent → lista principal | velocidade, seeds e peers de cada torrent |
| Bazarr → **Movies / Series** | legendas que já existem e as que faltam |
| Jellyfin → **Painel → Bibliotecas** | forçar uma nova varredura da biblioteca |

## Acompanhar os downloads

O caminho mais simples é o **Radarr → Activity → Queue** (filmes) e o **Sonarr → Activity → Queue**
(séries). Para quem só faz pedidos, o **Jellyseerr → Requests** basta. O qBittorrent mostra os detalhes
de cada torrent:

| Estado no qBittorrent | Significa |
|---|---|
| Downloading | baixando |
| Stalled (DL) | sem fontes no momento, esperando |
| Queued | na fila, esperando uma vaga (máximo de 5 simultâneos) |
| Seeding / Stalled (UP) | terminou e está compartilhando; o arquivo já foi importado para a biblioteca |

Quando um download termina, o Radarr/Sonarr importa (hardlink) e renomeia o arquivo, o Jellyfin
atualiza a biblioteca e o Bazarr busca as legendas.

**Pelo celular:** o app **JellyWatch** (Android) aprova pedidos do Jellyseerr e acompanha as filas.
**nzb360** (Android) e **Ruddarr** (iOS) mostram as filas do Radarr, do Sonarr e do qBittorrent num lugar só.

## O que é configurado automaticamente

| Serviço | URL | Configuração automática |
|---|---|---|
| Jellyfin | :8096 | assistente inicial, usuário admin, bibliotecas *Filmes* e *Séries*, chave de API para os *arr, varredura da biblioteca a cada 1 h (`JELLYFIN_SCAN_INTERVAL_HOURS`), legenda em português ligada por padrão (`JELLYFIN_SUBTITLE_LANGUAGE`/`JELLYFIN_SUBTITLE_MODE`, só para usuários sem preferência) |
| Jellyseerr | :5055 | login via Jellyfin, bibliotecas, Radarr e Sonarr como servidores padrão |
| Radarr | :7878 | login, pasta raiz `/data/media/movies`, qBittorrent (categoria `radarr`), renomeação, hardlinks, notificação ao Jellyfin |
| Sonarr | :8989 | idem com `/data/media/tv` e categoria `sonarr` |
| Prowlarr | :9696 | login, Radarr e Sonarr como apps, 8 indexers públicos (`PROWLARR_INDEXERS`), FlareSolverr, DNS público |
| qBittorrent | :8080 | usuário/senha do `.env`, pastas `complete`/`incomplete`, fila de 5 downloads simultâneos (torrents lentos não ocupam vaga) |
| Bazarr | :6767 | Radarr/Sonarr, idiomas (`SUBTITLE_LANGUAGES`), perfil padrão, provedores Podnapisi/Addic7ed (+ OpenSubtitles.com se houver conta no `.env`), score mínimo 90, sincronização de legenda, desbloqueio dos provedores bloqueados (*throttled*) |

Todos usam o mesmo login: `ADMIN_USER` / `ADMIN_PASSWORD` (o Bazarr fica sem login).

## O que você ainda faz à mão

1. (Opcional) Trackers privados em **Prowlarr → Indexers → Add Indexer**. Eles são enviados sozinhos ao Radarr/Sonarr.
2. (Opcional) Perfis de qualidade do [TRaSH Guides](https://trash-guides.info) com Recyclarr:
   `docker run --rm -v ./recyclarr/config:/config ghcr.io/recyclarr/recyclarr:latest sync`
3. Faça um pedido de teste no Jellyseerr e acompanhe o fluxo inteiro.

## Indexers

A instalação já adiciona estes indexers públicos, todos testados:

| Indexer | Foco |
|---|---|
| 1337x | filmes e séries, lançamentos novos |
| The Pirate Bay | geral, maior acervo |
| Knaben | agregador (busca em vários sites de uma vez) |
| LimeTorrents, Uindex | geral |
| YTS | filmes, arquivos pequenos |
| EZTV | séries |
| Nyaa.si | anime |

Para trocar a lista, edite `PROWLARR_INDEXERS` no `.env` (use os nomes de definição do Prowlarr) e rode
`docker compose up setup`. Se um site falhar no teste, o setup tenta de novo pelo FlareSolverr e, se ainda
falhar, pula esse indexer. O Prowlarr e o FlareSolverr usam DNS público (1.1.1.1/9.9.9.9) porque
operadoras como a Vivo bloqueiam esses domínios no DNS delas.

Indexers públicos quase não têm conteúdo dublado em português. Para isso, é preciso um tracker privado
brasileiro, com convite ou cadastro. Adicione-o no Prowlarr pela interface.

## Estrutura de pastas

```
DATA_ROOT/
├── torrents/
│   ├── incomplete/        downloads em andamento
│   └── complete/radarr|sonarr/
└── media/
    ├── movies/            Filme (Ano)/Filme (Ano).mkv
    └── tv/                Série/Season 01/Série - S01E01 - Título.mkv
```

Todos os contêineres montam o mesmo `DATA_ROOT` em `/data`. Assim o Radarr/Sonarr cria um *hardlink*
em vez de copiar o arquivo, e o torrent continua semeando sem ocupar espaço duas vezes. O guia original
monta `/downloads` e `/movies` separadamente, o que impede hardlinks. Os hardlinks foram testados e
funcionam no Docker Desktop para Windows com um drive NTFS (`D:`). Se algum sistema de arquivos não
aceitar hardlinks, o *arr copia o arquivo. Continua funcionando, mas ocupa o dobro de espaço até o torrent ser removido.

As configurações de cada app ficam em volumes Docker nomeados (`jellywatch_radarr-config` etc.),
não em pastas do Windows, porque o SQLite dos *arr trava ou corrompe em bind mounts do Windows.

## Diferenças em relação ao guia

- Jellyfin usa a porta `8096` publicada em vez de `network_mode: host`, que não funciona bem no Docker Desktop.
- A transcodificação por hardware (`/dev/dri`) vem comentada. Descomente no Linux se tiver GPU Intel/AMD.
- Jellyseerr roda com a imagem `ghcr.io/seerr-team/seerr` (Seerr, sucessor oficial). A imagem
  `fallenbagel/jellyseerr` do guia (2.7.x) não consegue logar no Jellyfin 10.11+, que desativou a autenticação legada.
- Os caminhos passam a ser `/data/media/movies` e `/data/media/tv` em vez de `/movies` e `/tv`.
- O fuso horário padrão é `America/Sao_Paulo`, e metadados e legendas vêm em português por padrão.

## Acesso ao servidor (manutenção e suporte)

Esta seção serve para você ou um assistente (ex.: Claude Code) diagnosticar e ajustar a instalação.
Ela não tem senhas nem chaves: todas ficam no `.env` do servidor.

### Instalação atual

| Item | Valor |
|---|---|
| Host Proxmox VE | `192.168.15.10`. Interface web: https://192.168.15.10:8006 |
| Contêiner LXC | CT **105**, hostname `jellyfin-stack`, Debian 13 |
| IP do LXC (onde os serviços rodam) | **`192.168.15.86`**. Os serviços ficam em `http://192.168.15.86:<porta>` (veja [Serviços e URLs](#serviços-e-urls)) |
| Projeto no LXC | `/opt/jellywatch` (`docker-compose.yml`, `docker-compose.override.yml` com a GPU, `.env`) |
| Mídia e downloads | `/mnt/data` no LXC (volume `vm-105-disk-0` do storage `data-1tb`), que aparece como `/data` nos contêineres |
| Segredos | `/opt/jellywatch/.env`: `ADMIN_USER`/`ADMIN_PASSWORD`, `RADARR_API_KEY`, `SONARR_API_KEY`, `PROWLARR_API_KEY`, `OPENSUBTITLES_*` |

### Entrar no servidor

```sh
ssh root@192.168.15.86                 # do PC, com a chave ~/.ssh/id_ed25519 (instalada pelo install-remote.sh)
```
Pelo host Proxmox (shell da interface web ou `ssh root@192.168.15.10`): `pct enter 105`.

Se o SSH pedir senha ou recusar a chave, adicione a sua chave pública pelo host:
`pct exec 105 -- sh -c 'cat >> /root/.ssh/authorized_keys' < ~/.ssh/id_ed25519.pub`.

### Comandos úteis (dentro de `/opt/jellywatch`)

```sh
docker compose ps                        # estado dos contêineres
docker compose logs --tail 100 radarr    # logs de um serviço
docker compose up setup                  # reaplica a configuração automática (idempotente)
docker compose restart jellyfin          # reinicia um serviço
ls -la /mnt/data/media/movies /mnt/data/media/tv
df -h /mnt/data
```

### Acesso às APIs (a partir do LXC)

As chaves vêm do `.env` ou do config de cada app. Não copie os valores para arquivos do projeto.

| Serviço | Autenticação |
|---|---|
| Radarr / Sonarr / Prowlarr | cabeçalho `X-Api-Key: <RADARR/SONARR/PROWLARR_API_KEY do .env>`. APIs `/api/v3` (Radarr/Sonarr) e `/api/v1` (Prowlarr) |
| Jellyfin (10.11+) | `POST /Users/AuthenticateByName` com `ADMIN_USER`/`ADMIN_PASSWORD` e depois o cabeçalho `Authorization: MediaBrowser Client="x", Device="x", DeviceId="x", Version="1", Token="<AccessToken>"`. O antigo `X-Emby-Token` **não funciona** mais |
| Jellyseerr | cabeçalho `X-Api-Key`. A chave está em `main.apiKey` de `/app/config/settings.json` (`docker exec jellyseerr cat /app/config/settings.json`) |
| Bazarr | cabeçalho `X-API-KEY`. A chave está em `auth.apikey` de `/config/config/config.yaml` (`docker exec bazarr cat /config/config/config.yaml`) |
| qBittorrent | `POST /api/v2/auth/login` (form `username`/`password` do `.env`) com o cabeçalho `Referer: http://localhost:8080`, depois cookie de sessão |

Exemplo:
```sh
cd /opt/jellywatch && K=$(sed -n 's/^RADARR_API_KEY=//p' .env)
curl -s -H "X-Api-Key: $K" http://localhost:7878/api/v3/queue
```

### Pedindo ajuda a um assistente

Diga algo como: *"leia a seção 'Acesso ao servidor' do README e conecte por SSH em root@192.168.15.86"*.
**Não cole senhas, chaves nem o `.env` no chat.** O assistente lê o que precisa direto no servidor.
Nos arquivos que você compartilha, o mesmo cuidado: não deixe senhas em texto puro no `README.txt`.

## Problemas comuns

| Sintoma | Causa e solução |
|---|---|
| Pedido fica em *Solicitado* no Jellyseerr, mas o Radarr já importou o filme | O Jellyfin ignorou o aviso do Radarr. O filme aparece na próxima varredura, que roda a cada `JELLYFIN_SCAN_INTERVAL_HOURS`. Para não esperar: **Jellyfin → Painel → Bibliotecas → Escanear todas as bibliotecas**. |
| Legenda padrão abre no idioma errado num filme que tem legendas embutidas **e** uma `.srt` do Bazarr | Bug do Jellyfin: a `.srt` externa desloca a numeração das faixas em uma posição ([jellyfin#16485](https://github.com/jellyfin/jellyfin/issues/16485)). Escolha a legenda "Portuguese (Brazil) - Externo" no player. |
| Bazarr não baixa legendas e o log diz *All providers are throttled* | Rode `docker compose up setup` de novo: ele desbloqueia os provedores. Sem conta no OpenSubtitles.com, há pouca legenda pt-BR. |
| `apt-get update` no **host** Proxmox falha com `401 Unauthorized` em `enterprise.proxmox.com` | O repositório *enterprise* exige assinatura. Em **Node → Updates → Repositories**, desative os dois repositórios enterprise (`pve` e `ceph`) e adicione o **No-Subscription**. |

## Operação

```sh
docker compose up -d            # subir / atualizar configuração
docker compose pull && docker compose up -d   # atualizar imagens
docker compose up setup         # rodar a configuração automática de novo (idempotente)
docker compose logs -f radarr   # logs
docker compose down             # parar (os dados ficam nos volumes)
```

### Backup / migração para outra máquina

```sh
# backup das configs
for v in jellyfin-config jellyseerr-config radarr-config sonarr-config prowlarr-config qbittorrent-config bazarr-config; do
  docker run --rm -v jellywatch_$v:/v -v "$PWD/backup":/b alpine tar czf /b/$v.tgz -C /v .
done
```
Para restaurar numa instalação nova, copie o `.env` e a pasta `backup/`, rode `docker compose create`
e extraia cada arquivo no volume correspondente (`tar xzf` no lugar de `tar czf`) antes do `up -d`.
