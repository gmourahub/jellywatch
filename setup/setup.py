"""Configuração automática do stack Jellyfin + *arr.

  python setup.py pre   -> roda antes dos apps (cria pastas, pré-configura qBittorrent)
  python setup.py post  -> roda depois (conecta tudo via API). Idempotente.

Só usa a biblioteca padrão do Python.
"""
import base64
import hashlib
import http.cookiejar
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ENV = os.environ
USER = ENV["ADMIN_USER"]
PASSWORD = ENV["ADMIN_PASSWORD"]
PUID = int(ENV.get("PUID", "1000"))
PGID = int(ENV.get("PGID", "1000"))
SERVER_HOST = ENV.get("SERVER_HOST", "localhost")

MOVIES = "/data/media/movies"
TV = "/data/media/tv"
DL_COMPLETE = "/data/torrents/complete"
DL_INCOMPLETE = "/data/torrents/incomplete"

RADARR = {"name": "Radarr", "url": "http://radarr:7878", "api": "/api/v3", "key": ENV["RADARR_API_KEY"]}
SONARR = {"name": "Sonarr", "url": "http://sonarr:8989", "api": "/api/v3", "key": ENV["SONARR_API_KEY"]}
PROWLARR = {"name": "Prowlarr", "url": "http://prowlarr:9696", "api": "/api/v1", "key": ENV["PROWLARR_API_KEY"]}
QBIT = "http://qbittorrent:8080"
JELLYFIN = "http://jellyfin:8096"
JELLYSEERR = "http://jellyseerr:5055"
BAZARR = "http://bazarr:6767"

JF_AUTH = 'MediaBrowser Client="jf-setup", Device="jf-setup", DeviceId="jf-setup", Version="1.0"'


def log(msg):
    print(f"[setup] {msg}", flush=True)


# ---------------------------------------------------------------- HTTP helpers
class Http:
    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def req(self, method, url, body=None, form=None, headers=None, raw=False):
        headers = dict(headers or {})
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        elif form is not None:
            data = urllib.parse.urlencode(form, doseq=True).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        r = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with self.opener.open(r, timeout=60) as resp:
                text = resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:500]
            raise RuntimeError(f"{method} {url} -> HTTP {e.code}: {detail}") from None
        if raw or not text:
            return text
        try:
            return json.loads(text)
        except ValueError:
            return text


def wait_for(name, fn, timeout=600):
    start = time.time()
    last = None
    while time.time() - start < timeout:
        try:
            fn()
            log(f"{name} está no ar")
            return
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(3)
    raise RuntimeError(f"{name} não respondeu em {timeout}s: {last}")


def retry(fn, attempts=10, delay=5):
    for i in range(attempts):
        try:
            return fn()
        except Exception:  # noqa: BLE001
            if i == attempts - 1:
                raise
            time.sleep(delay)


# ---------------------------------------------------------------- PRE
def qbit_password_hash(password):
    salt = os.urandom(16)
    key = hashlib.pbkdf2_hmac("sha512", password.encode(), salt, 100000, 64)
    return f"@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(key).decode()})"


def pre():
    for d in (DL_COMPLETE, DL_INCOMPLETE, MOVIES, TV):
        os.makedirs(d, exist_ok=True)
        try:
            os.chown(d, PUID, PGID)
        except OSError:
            pass  # bind mount do Windows não suporta chown; sem problema
    log("estrutura /data criada")

    conf_dir = "/qbittorrent-config/qBittorrent"
    conf = f"{conf_dir}/qBittorrent.conf"
    if os.path.exists(conf):
        log("qBittorrent.conf já existe, mantendo")
        return
    os.makedirs(conf_dir, exist_ok=True)
    with open(conf, "w") as f:
        f.write(
            "[BitTorrent]\n"
            f"Session\\DefaultSavePath={DL_COMPLETE}\n"
            f"Session\\TempPath={DL_INCOMPLETE}\n"
            "Session\\TempPathEnabled=true\n"
            "Session\\Port=6881\n"
            "\n[LegalNotice]\nAccepted=true\n"
            "\n[Preferences]\n"
            "WebUI\\Port=8080\n"
            f"WebUI\\Username={USER}\n"
            f'WebUI\\Password_PBKDF2="{qbit_password_hash(PASSWORD)}"\n'
            "WebUI\\HostHeaderValidation=false\n"
        )
    for p in ("/qbittorrent-config", conf_dir, conf):
        os.chown(p, PUID, PGID)
    log("qBittorrent pré-configurado com usuário/senha do .env")


# ---------------------------------------------------------------- qBittorrent
def setup_qbittorrent():
    h = Http()
    hdr = {"Referer": QBIT}

    def login():
        r = h.req("POST", f"{QBIT}/api/v2/auth/login", form={"username": USER, "password": PASSWORD}, headers=hdr, raw=True)
        if r.strip() and "Ok" not in r:  # v5.2+ responde 204 vazio; versões antigas "Ok."
            raise RuntimeError(f"login qBittorrent falhou: {r}")

    wait_for("qBittorrent", login)
    prefs = {
        "save_path": DL_COMPLETE, "temp_path_enabled": True, "temp_path": DL_INCOMPLETE,
        # Fila: torrents lentos/sem seeds não ocupam vaga, senão pedidos novos ficam em "queuedDL"
        "max_active_downloads": 5, "max_active_uploads": 10, "max_active_torrents": 15,
        "dont_count_slow_torrents": True,
    }
    h.req("POST", f"{QBIT}/api/v2/app/setPreferences", form={"json": json.dumps(prefs)}, headers=hdr)
    log("qBittorrent: caminhos de download configurados")


# ---------------------------------------------------------------- Jellyfin
def setup_jellyfin():
    h = Http()
    info = {}

    def ping():
        info.update(h.req("GET", f"{JELLYFIN}/System/Info/Public"))

    wait_for("Jellyfin", ping)
    if not info.get("StartupWizardCompleted"):
        lang = ENV.get("METADATA_LANGUAGE", "pt-BR")
        country = ENV.get("METADATA_COUNTRY", "BR")
        hdr = {"Authorization": JF_AUTH}
        retry(lambda: h.req("POST", f"{JELLYFIN}/Startup/Configuration", headers=hdr, body={
            "UICulture": lang, "MetadataCountryCode": country, "PreferredMetadataLanguage": lang.split("-")[0]}))
        # Cria o primeiro usuário (GET inicializa, POST define nome/senha)
        try:
            h.req("GET", f"{JELLYFIN}/Startup/FirstUser", headers=hdr)
        except RuntimeError:
            h.req("GET", f"{JELLYFIN}/Startup/User", headers=hdr)
        h.req("POST", f"{JELLYFIN}/Startup/User", headers=hdr, body={"Name": USER, "Password": PASSWORD})
        h.req("POST", f"{JELLYFIN}/Startup/RemoteAccess", headers=hdr,
              body={"EnableRemoteAccess": True, "EnableAutomaticPortMapping": False})
        h.req("POST", f"{JELLYFIN}/Startup/Complete", headers=hdr)
        log("Jellyfin: assistente inicial concluído")

    auth = retry(lambda: h.req("POST", f"{JELLYFIN}/Users/AuthenticateByName",
                               headers={"Authorization": JF_AUTH}, body={"Username": USER, "Pw": PASSWORD}))
    token = auth["AccessToken"]
    hdr = {"Authorization": f'{JF_AUTH}, Token="{token}"'}

    def api_key():
        for k in h.req("GET", f"{JELLYFIN}/Auth/Keys", headers=hdr).get("Items", []):
            if k.get("AppName") == "arr-stack":
                return k["AccessToken"]
        return None

    key = api_key()
    if not key:
        h.req("POST", f"{JELLYFIN}/Auth/Keys?app=arr-stack", headers=hdr)
        key = api_key()
    log("Jellyfin: chave de API 'arr-stack' pronta")

    existing = {f["Name"] for f in h.req("GET", f"{JELLYFIN}/Library/VirtualFolders", headers=hdr)}
    for name, ctype, path in (("Filmes", "movies", MOVIES), ("Séries", "tvshows", TV)):
        if name in existing:
            continue
        q = urllib.parse.urlencode({"name": name, "collectionType": ctype, "refreshLibrary": "true"})
        h.req("POST", f"{JELLYFIN}/Library/VirtualFolders?{q}", headers=hdr, body={"LibraryOptions": {
            "PathInfos": [{"Path": path}],
            "PreferredMetadataLanguage": ENV.get("METADATA_LANGUAGE", "pt-BR").split("-")[0],
            "MetadataCountryCode": ENV.get("METADATA_COUNTRY", "BR"),
            "EnableRealtimeMonitor": True,
        }})
        log(f"Jellyfin: biblioteca '{name}' -> {path}")

    # O aviso do Radarr/Sonarr (/Library/Media/Updated) às vezes não dispara a varredura;
    # sem isso, um filme importado só aparece na varredura agendada (padrão: a cada 12 h).
    hours = int(ENV.get("JELLYFIN_SCAN_INTERVAL_HOURS", "1"))
    task = next(t for t in h.req("GET", f"{JELLYFIN}/ScheduledTasks", headers=hdr) if t["Key"] == "RefreshLibrary")
    h.req("POST", f"{JELLYFIN}/ScheduledTasks/{task['Id']}/Triggers", headers=hdr,
          body=[{"Type": "IntervalTrigger", "IntervalTicks": hours * 3600 * 10**7}])
    log(f"Jellyfin: varredura da biblioteca a cada {hours} h")

    # Legenda padrão: só preenche usuários sem preferência, para não desfazer escolhas feitas no app
    sub_lang = ENV.get("JELLYFIN_SUBTITLE_LANGUAGE", "por")
    sub_mode = ENV.get("JELLYFIN_SUBTITLE_MODE", "Always")
    for u in h.req("GET", f"{JELLYFIN}/Users", headers=hdr):
        cfg = u["Configuration"]
        if cfg.get("SubtitleLanguagePreference"):
            continue
        cfg.update(SubtitleLanguagePreference=sub_lang, SubtitleMode=sub_mode)
        h.req("POST", f"{JELLYFIN}/Users/{u['Id']}/Configuration", headers=hdr, body=cfg)
        log(f"Jellyfin: legenda padrão de '{u['Name']}' -> {sub_lang} ({sub_mode})")
    return key


# ---------------------------------------------------------------- Servarr (Radarr/Sonarr/Prowlarr)
def arr(app, method, path, body=None):
    return Http().req(method, f"{app['url']}{app['api']}{path}", body=body, headers={"X-Api-Key": app["key"]})


def fill_fields(item, values):
    for f in item.get("fields", []):
        if f["name"] in values:
            f["value"] = values[f["name"]]
    return item


def add_from_schema(app, resource, implementation, name, values, extra=None):
    """Cria um recurso (downloadclient/notification/applications) a partir do schema, se ainda não existir."""
    if any(x.get("name") == name for x in arr(app, "GET", f"/{resource}")):
        return False
    schema = next(s for s in arr(app, "GET", f"/{resource}/schema") if s["implementation"] == implementation)
    schema = fill_fields(schema, values)
    schema["name"] = name
    schema.pop("id", None)
    schema.update(extra or {})
    retry(lambda: arr(app, "POST", f"/{resource}", schema))
    return True


def set_arr_auth(app):
    cfg = arr(app, "GET", "/config/host")
    cfg.update({"authenticationMethod": "forms", "authenticationRequired": "enabled",
                "username": USER, "password": PASSWORD, "passwordConfirmation": PASSWORD})
    arr(app, "PUT", f"/config/host/{cfg['id']}", cfg)
    log(f"{app['name']}: login por formulário com usuário do .env")


def setup_arr(app, root, jellyfin_key):
    wait_for(app["name"], lambda: arr(app, "GET", "/system/status"))
    set_arr_auth(app)

    if not any(r["path"].rstrip("/") == root for r in arr(app, "GET", "/rootfolder")):
        arr(app, "POST", "/rootfolder", {"path": root})
        log(f"{app['name']}: pasta raiz {root}")

    category = app["name"].lower()
    if add_from_schema(app, "downloadclient", "QBittorrent", "qBittorrent", {
        "host": "qbittorrent", "port": 8080, "username": USER, "password": PASSWORD,
        "movieCategory": category, "tvCategory": category,
    }, {"enable": True}):
        log(f"{app['name']}: cliente de download qBittorrent (categoria '{category}')")

    naming = arr(app, "GET", "/config/naming")
    if app is RADARR:
        naming.update({"renameMovies": True,
                       "standardMovieFormat": "{Movie Title} ({Release Year})",
                       "movieFolderFormat": "{Movie Title} ({Release Year})"})
    else:
        naming.update({"renameEpisodes": True,
                       "standardEpisodeFormat": "{Series Title} - S{season:00}E{episode:00} - {Episode Title}",
                       "seriesFolderFormat": "{Series Title}",
                       "seasonFolderFormat": "Season {season:00}"})
    arr(app, "PUT", f"/config/naming/{naming['id']}", naming)

    mm = arr(app, "GET", "/config/mediamanagement")
    mm["copyUsingHardlinks"] = True
    arr(app, "PUT", f"/config/mediamanagement/{mm['id']}", mm)
    log(f"{app['name']}: renomeação e hardlinks ativados")

    schema = next(s for s in arr(app, "GET", "/notification/schema") if s["implementation"] == "MediaBrowser")
    events = {k: True for k in schema if k.startswith("on") and schema.get("supportsO" + k[1:])}
    if add_from_schema(app, "notification", "MediaBrowser", "Jellyfin", {
        "host": "jellyfin", "port": 8096, "apiKey": jellyfin_key, "updateLibrary": True, "notify": False,
    }, events):
        log(f"{app['name']}: conexão Jellyfin (atualiza biblioteca ao importar)")


DEFAULT_INDEXERS = "1337x,thepiratebay,Knaben,limetorrents,uindex,yts,eztv,nyaasi"
# Sites atrás da Cloudflare: o teste inicial às vezes passa, mas as buscas são bloqueadas sem FlareSolverr
DEFAULT_FLARESOLVERR_INDEXERS = "1337x,uindex,eztv"


def env_list(name, default):
    return [n.strip() for n in ENV.get(name, default).split(",") if n.strip()]


def prowlarr_flaresolverr_tag():
    """Cria a tag 'flaresolverr' e o proxy FlareSolverr; indexers com essa tag passam por ele."""
    tag = next((t for t in arr(PROWLARR, "GET", "/tag") if t["label"] == "flaresolverr"), None)
    if not tag:
        tag = arr(PROWLARR, "POST", "/tag", {"label": "flaresolverr"})
    if add_from_schema(PROWLARR, "indexerproxy", "FlareSolverr", "FlareSolverr", {
        "host": "http://flaresolverr:8191/", "requestTimeout": 60,
    }, {"tags": [tag["id"]]}):
        log("Prowlarr: proxy FlareSolverr adicionado (tag 'flaresolverr')")
    return tag["id"]


def setup_prowlarr_indexers():
    wanted = env_list("PROWLARR_INDEXERS", DEFAULT_INDEXERS)
    if not wanted:
        return
    cloudflare = {n.lower() for n in env_list("FLARESOLVERR_INDEXERS", DEFAULT_FLARESOLVERR_INDEXERS)}
    fs_tag = prowlarr_flaresolverr_tag()
    existing = {i["definitionName"].lower(): i for i in arr(PROWLARR, "GET", "/indexer")}
    schemas = {s["definitionName"].lower(): s for s in arr(PROWLARR, "GET", "/indexer/schema")}
    changed = []
    for name in wanted:
        key = name.lower()
        current = existing.get(key)
        if current:
            # Indexer já cadastrado: só garante a tag do FlareSolverr quando necessário
            if key in cloudflare and fs_tag not in current["tags"]:
                current["tags"].append(fs_tag)
                arr(PROWLARR, "PUT", f"/indexer/{current['id']}?forceSave=true", current)
                changed.append(f"{name} (agora via FlareSolverr)")
            continue
        schema = schemas.get(key)
        if not schema:
            log(f"Prowlarr: indexer '{name}' não existe nesta versão, pulando")
            continue
        schema.update(enable=True, appProfileId=1)
        # O POST testa a conexão; se falhar sem FlareSolverr, tenta de novo com ele
        attempts = ([fs_tag],) if key in cloudflare else ([], [fs_tag])
        err = None
        for tags in attempts:
            schema["tags"] = tags
            try:
                arr(PROWLARR, "POST", "/indexer", schema)
                changed.append(name + (" (via FlareSolverr)" if tags else ""))
                break
            except RuntimeError as e:
                err = e
        else:
            log(f"Prowlarr: AVISO indexer '{name}' fora do ar agora, pulando ({str(err)[:120]})")
    if changed:
        # O Prowlarr envia cada indexer ao Radarr/Sonarr sozinho; uma sincronização manual em
        # paralelo causa conflito ("Should be unique"). Só repete no fim para pegar falhas pontuais.
        time.sleep(30)
        arr(PROWLARR, "POST", "/command", {"name": "ApplicationIndexerSync"})
        log(f"Prowlarr: indexers configurados: {', '.join(changed)}")


def setup_prowlarr():
    wait_for("Prowlarr", lambda: arr(PROWLARR, "GET", "/system/status"))
    set_arr_auth(PROWLARR)
    for target in (RADARR, SONARR):
        if add_from_schema(PROWLARR, "applications", target["name"], target["name"], {
            "prowlarrUrl": PROWLARR["url"], "baseUrl": target["url"], "apiKey": target["key"],
        }, {"syncLevel": "fullSync"}):
            log(f"Prowlarr: aplicação {target['name']} adicionada (sincronização completa)")
    setup_prowlarr_indexers()


# ---------------------------------------------------------------- Bazarr
def bazarr_api_key():
    section = None
    with open("/bazarr-config/config/config.yaml") as f:
        for line in f:
            m = re.match(r"^(\w+):\s*$", line)
            if m:
                section = m.group(1)
                continue
            m = re.match(r"^\s+apikey:\s*['\"]?([^'\"\s]+)", line)
            if m and section == "auth":
                return m.group(1)
    raise RuntimeError("apikey do Bazarr não encontrada")


def setup_bazarr():
    key = {}

    def ping():
        key["k"] = bazarr_api_key()
        Http().req("GET", f"{BAZARR}/api/system/status", headers={"X-API-KEY": key["k"]})

    wait_for("Bazarr", ping)
    hdr = {"X-API-KEY": key["k"]}
    langs = [l.strip() for l in ENV.get("SUBTITLE_LANGUAGES", "pb,en").split(",") if l.strip()]
    profile = [{
        "profileId": 1, "name": "Padrão", "cutoff": None, "mustContain": [], "mustNotContain": [],
        "originalFormat": False, "tag": None,
        "items": [{"id": i + 1, "language": l, "forced": "False", "hi": "False", "audio_exclude": "False", "audio_only_include": "False"}
                  for i, l in enumerate(langs)],
    }]
    providers = ["podnapisi", "addic7ed"]
    form = {
        "settings-general-use_radarr": "true",
        "settings-radarr-ip": "radarr", "settings-radarr-port": "7878", "settings-radarr-apikey": RADARR["key"],
        "settings-general-use_sonarr": "true",
        "settings-sonarr-ip": "sonarr", "settings-sonarr-port": "8989", "settings-sonarr-apikey": SONARR["key"],
        "languages-enabled": langs,
        "languages-profiles": json.dumps(profile),
        "settings-general-serie_default_enabled": "true", "settings-general-serie_default_profile": "1",
        "settings-general-movie_default_enabled": "true", "settings-general-movie_default_profile": "1",
        "settings-general-minimum_score": "90", "settings-general-minimum_score_movie": "90",
        "settings-subsync-use_subsync": "true",
    }
    if ENV.get("OPENSUBTITLES_USERNAME"):
        providers.insert(0, "opensubtitlescom")
        form["settings-opensubtitlescom-username"] = ENV["OPENSUBTITLES_USERNAME"]
        form["settings-opensubtitlescom-password"] = ENV.get("OPENSUBTITLES_PASSWORD", "")
    form["settings-general-enabled_providers"] = providers
    Http().req("POST", f"{BAZARR}/api/system/settings", form=form, headers=hdr)
    # Provedores bloqueados antes (ex.: sem credenciais) continuam "throttled" por horas mesmo
    # depois de configurados; libera todos para a próxima busca já usar a configuração nova.
    Http().req("POST", f"{BAZARR}/api/providers", form={"action": "reset"}, headers=hdr)
    log(f"Bazarr: Radarr/Sonarr conectados, idiomas {langs}, provedores {providers}")


# ---------------------------------------------------------------- Jellyseerr
def setup_jellyseerr():
    h = Http()
    status = {}

    def ping():
        status.update(h.req("GET", f"{JELLYSEERR}/api/v1/settings/public"))

    wait_for("Jellyseerr", ping)
    if status.get("initialized"):
        log("Jellyseerr já inicializado, pulando")
        return

    login = {"username": USER, "password": PASSWORD}
    try:
        h.req("POST", f"{JELLYSEERR}/api/v1/auth/jellyfin", body=dict(
            login, hostname="jellyfin", port=8096, useSsl=False, urlBase="",
            email=f"{USER}@localhost", serverType=2))
        log("Jellyseerr: admin criado a partir do Jellyfin")
    except RuntimeError as e:
        if "already configured" not in str(e):
            raise
        h.req("POST", f"{JELLYSEERR}/api/v1/auth/jellyfin", body=login)

    jf = h.req("GET", f"{JELLYSEERR}/api/v1/settings/jellyfin")
    for read_only in ("name", "libraries", "serverId", "serverID"):
        jf.pop(read_only, None)
    jf["externalHostname"] = f"http://{SERVER_HOST}:8096"
    h.req("POST", f"{JELLYSEERR}/api/v1/settings/jellyfin", body=jf)
    libs = h.req("GET", f"{JELLYSEERR}/api/v1/settings/jellyfin/library?sync=true")
    ids = ",".join(l["id"] for l in libs)
    h.req("GET", f"{JELLYSEERR}/api/v1/settings/jellyfin/library?enable={ids}")
    log(f"Jellyseerr: {len(libs)} bibliotecas habilitadas")

    for app, port, root in ((RADARR, 7878, MOVIES), (SONARR, 8989, TV)):
        kind = app["name"].lower()
        if h.req("GET", f"{JELLYSEERR}/api/v1/settings/{kind}"):
            continue
        conn ={"hostname": kind, "port": port, "apiKey": app["key"], "useSsl": False, "baseUrl": ""}
        test = h.req("POST", f"{JELLYSEERR}/api/v1/settings/{kind}/test", body=conn)
        profiles = test["profiles"]
        profile = next((p for p in profiles if p["name"] in ("HD-1080p", "HD - 720p/1080p")), profiles[0])
        body = dict(conn, name=app["name"], activeProfileId=profile["id"], activeProfileName=profile["name"],
                    activeDirectory=root, is4k=False, isDefault=True, syncEnabled=False, preventSearch=False,
                    externalUrl=f"http://{SERVER_HOST}:{port}", tags=[])
        if app is RADARR:
            body["minimumAvailability"] = "released"
        else:
            body.update(enableSeasonFolders=True, seriesType="standard", animeSeriesType="anime",
                        activeAnimeProfileId=profile["id"], activeAnimeProfileName=profile["name"],
                        activeAnimeDirectory=root, animeTags=[])
            if test.get("languageProfiles"):
                body["activeLanguageProfileId"] = test["languageProfiles"][0]["id"]
        h.req("POST", f"{JELLYSEERR}/api/v1/settings/{kind}", body=body)
        log(f"Jellyseerr: {app['name']} conectado (perfil {profile['name']}, pasta {root})")

    h.req("POST", f"{JELLYSEERR}/api/v1/settings/initialize")
    log("Jellyseerr: configuração inicial concluída")


# ---------------------------------------------------------------- main
def post():
    failures = []

    def step(name, fn, *args):
        try:
            return fn(*args)
        except Exception as e:  # noqa: BLE001
            log(f"ERRO em {name}: {e}")
            failures.append(name)
            return None

    step("qBittorrent", setup_qbittorrent)
    jf_key = step("Jellyfin", setup_jellyfin)
    step("Radarr", setup_arr, RADARR, MOVIES, jf_key)
    step("Sonarr", setup_arr, SONARR, TV, jf_key)
    step("Prowlarr", setup_prowlarr)
    step("Bazarr", setup_bazarr)
    step("Jellyseerr", setup_jellyseerr)

    h = SERVER_HOST
    print(f"""
==================== Stack pronto ====================
 Jellyfin     http://{h}:8096
 Jellyseerr   http://{h}:5055
 Radarr       http://{h}:7878
 Sonarr       http://{h}:8989
 Prowlarr     http://{h}:9696
 qBittorrent  http://{h}:8080
 Bazarr       http://{h}:6767
 Login em todos: {USER} / (ADMIN_PASSWORD do .env)
======================================================""", flush=True)
    if failures:
        log(f"Etapas com falha: {', '.join(failures)} (rode 'docker compose up setup' para tentar de novo)")
        sys.exit(1)


if __name__ == "__main__":
    {"pre": pre, "post": post}[sys.argv[1]]()
