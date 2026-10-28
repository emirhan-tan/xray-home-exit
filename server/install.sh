#!/usr/bin/env bash
# xray-home-exit — sunucu (VDS) kurulumu
#
# İstemciler sunucuya bağlanır; seçilen kullanıcıların ve yerel SOCKS portunun
# trafiği, evdeki cihazın açtığı VLESS Reverse tünelinden ev internetine çıkar.
# Ev tüneli koparsa trafik otomatik olarak sunucunun kendi IP'sine düşer.
#
#   curl -fsSL https://raw.githubusercontent.com/emirhan-tan/xray-home-exit/main/server/install.sh | bash -s -- [seçenekler]
#
# Komutlar:  install (varsayılan) | uninstall | link | status | users
set -euo pipefail

VERSION=1.0.1
REPO="${HE_REPO:-emirhan-tan/xray-home-exit}"
RAW="https://raw.githubusercontent.com/$REPO/main"

NAME=home-exit
MODE=auto              # auto | xui | standalone
BRIDGE_PORT=10086
SECURITY=reality       # reality | tls
SNI=""                 # reality: taklit edilecek site / tls: alan adı
TLS_CERT=""
TLS_KEY=""
USERS=""               # x-ui: eve yönlenecek kullanıcı e-postaları (virgülle)
SOCKS_PORT=1080        # sunucu içi 127.0.0.1 SOCKS5 (0 = kapalı)
FALLBACK=direct        # ev tüneli yokken: direct | block
ENTRY_PORT=443         # standalone: istemcilerin bağlanacağı port (0 = kapalı)
ADDRESS=""             # ev cihazının bağlanacağı adres (boşsa otomatik IP)
XRAY_VERSION=latest
REGEN=0
DRY_RUN=0
IPV6=0                 # 1 = eve yönlenen trafikte IPv6'ya izin ver
ACTION=install

XUI_DB=${HE_XUI_DB:-/etc/x-ui/x-ui.db}
XUI_BIN_DIR=/usr/local/x-ui/bin
STATE_DIR=/etc/home-exit
LIB_DIR=/usr/local/lib/home-exit
# geoip.dat gerektirmeden özel ağlar (sunucunun yerel ağına erişimi engeller)
PRIVATE_NETS='"0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","fc00::/7","fe80::/10"'
REALITY_CANDIDATES="www.apple.com www.cloudflare.com dl.google.com www.samsung.com addons.mozilla.org"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'; c_off=$'\e[0m'
log()  { echo "${c_cyn}==>${c_off} $*"; }
ok()   { echo "${c_grn}✔${c_off} $*"; }
warn() { echo "${c_ylw}!${c_off} $*" >&2; }
die()  { echo "${c_red}✘ $*${c_off}" >&2; exit 1; }

usage() {
	cat <<EOF
Kullanım: install.sh [komut] [seçenekler]

Komutlar:
  install            Kur veya ayarları güncelle (varsayılan)
  uninstall          Kaldır
  link               Ev cihazı için bağlantı linkini ve kurulum komutlarını yeniden yazdır
  status             Ev tüneli bağlı mı, çıkış IP'si ne
  users              x-ui kullanıcılarını listele

Seçenekler:
  --name AD          Kurulum adı (varsayılan: home-exit)
  --mode M           auto | xui | standalone (varsayılan: auto)
  --port N           Ev cihazının bağlanacağı port (varsayılan: 10086)
  --users a,b        x-ui: trafiği eve gidecek kullanıcı e-postaları
  --socks-port N     Sunucu içi 127.0.0.1 SOCKS5 portu (varsayılan: 1080, 0 = kapalı)
  --fallback F       Ev tüneli yokken: direct (sunucu IP'si) | block (varsayılan: direct)
  --entry-port N     standalone: istemci giriş portu (varsayılan: 443, 0 = kapalı)
  --sni SITE         reality: taklit edilecek site (boşsa otomatik seçilir)
  --tls-cert DOSYA   TLS kullan (sertifika); --tls-key ve --sni ALANADI ile
  --tls-key DOSYA
  --address ADRES    Ev cihazının bağlanacağı adres (varsayılan: sunucu IPv4)
  --xray-version V   standalone: Xray sürümü (varsayılan: latest, örn. v26.3.27)
  --ipv6             Eve yönlenen trafikte IPv6'ya izin ver (varsayılan: yalnızca IPv4)
  --no-ipv6          IPv6'yı tekrar kapat
  --regen            Anahtarları/UUID'yi yeniden üret (ev cihazı yeniden kurulmalı)
  --dry-run          Yalnızca oluşacak ayarı doğrula; hiçbir şeyi değiştirme
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		install|uninstall|link|status|users) ACTION=$1 ;;
		--name) NAME=$2; shift ;;
		--mode) MODE=$2; shift ;;
		--port) BRIDGE_PORT=$2; shift ;;
		--users) USERS=$2; shift ;;
		--socks-port) SOCKS_PORT=$2; shift ;;
		--fallback) FALLBACK=$2; shift ;;
		--entry-port) ENTRY_PORT=$2; shift ;;
		--sni) SNI=$2; shift ;;
		--tls-cert) TLS_CERT=$2; SECURITY=tls; shift ;;
		--tls-key) TLS_KEY=$2; shift ;;
		--address) ADDRESS=$2; shift ;;
		--xray-version) XRAY_VERSION=$2; shift ;;
		--regen) REGEN=1 ;;
		--dry-run) DRY_RUN=1 ;;
		--ipv6) IPV6=1 ;;
		--no-ipv6) IPV6=off ;;
		-h|--help) usage; exit 0 ;;
		-v|--version) echo "xray-home-exit $VERSION"; exit 0 ;;
		*) die "Bilinmeyen seçenek: $1 (yardım: --help)" ;;
	esac
	shift
done

[ "$(id -u)" = 0 ] || die "root olarak çalıştırın"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--name yalnızca küçük harf, rakam ve - içerebilir"
case "$FALLBACK" in direct|block) ;; *) die "--fallback direct veya block olmalı" ;; esac
STATE="$STATE_DIR/$NAME.env"

# ---------------------------------------------------------------- yardımcılar

port_busy() { ss -Htln "( sport = :$1 )" 2>/dev/null | grep -q .; }

public_ip() {
	local ip
	for u in https://api.ipify.org https://ifconfig.co/ip https://ipv4.icanhazip.com; do
		ip=$(curl -4 -fsS -m 6 "$u" 2>/dev/null | tr -d '[:space:]') && [ -n "$ip" ] && { echo "$ip"; return; }
	done
	hostname -I 2>/dev/null | awk '{print $1}'
}

xray_arch() {
	case "$(uname -m)" in
		x86_64|amd64) echo 64 ;;
		i?86) echo 32 ;;
		aarch64|arm64) echo arm64-v8a ;;
		armv7*|armv8l) echo arm32-v7a ;;
		armv6*) echo arm32-v6 ;;
		armv5*) echo arm32-v5 ;;
		riscv64) echo riscv64 ;;
		s390x) echo s390x ;;
		ppc64le) echo ppc64le ;;
		loongarch64) echo loong64 ;;
		*) die "Desteklenmeyen mimari: $(uname -m)" ;;
	esac
}

install_xray_standalone() {
	local bin="$LIB_DIR/xray"
	if [ -x "$bin" ] && [ "$XRAY_VERSION" = latest ] && [ "$REGEN" = 0 ]; then
		XRAY=$bin; return
	fi
	command -v unzip >/dev/null || { log "unzip kuruluyor"; (apt-get install -y unzip || dnf install -y unzip || yum install -y unzip || apk add unzip) >/dev/null 2>&1 || die "unzip kurulamadı"; }
	local url tmp
	if [ "$XRAY_VERSION" = latest ]; then
		url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$(xray_arch).zip"
	else
		url="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-$(xray_arch).zip"
	fi
	log "Xray indiriliyor: $url"
	tmp=$(mktemp -d)
	curl -fsSL --retry 3 -o "$tmp/x.zip" "$url" || die "Xray indirilemedi"
	unzip -qo "$tmp/x.zip" xray -d "$tmp" || die "Arşiv açılamadı"
	install -d "$LIB_DIR"; install -m 755 "$tmp/xray" "$bin"; rm -rf "$tmp"
	XRAY=$bin
	ok "$("$XRAY" version | head -1)"
}

find_xui_xray() {
	XRAY=$(ls "$XUI_BIN_DIR"/xray-linux-* 2>/dev/null | head -1)
	[ -x "$XRAY" ] || die "x-ui Xray çekirdeği bulunamadı ($XUI_BIN_DIR)"
}

check_xray_version() {
	local v; v=$("$XRAY" version | awk 'NR==1{print $2}')
	[ "${v%%.*}" -ge 26 ] 2>/dev/null || die "Xray $v çok eski; VLESS Reverse için 26.x gerekir (x-ui panelinden Xray'i güncelleyin)"
}

gen_keys() {
	local out; out=$("$XRAY" x25519)
	PRIV=$(echo "$out" | awk -F': *' '/^Private ?[Kk]ey/{print $2}')
	PUB=$(echo "$out" | awk -F': *' '/^(Password|Public ?[Kk]ey)/{print $2; exit}')
	[ -n "$PRIV" ] && [ -n "$PUB" ] || die "x25519 anahtarı üretilemedi"
}

# REALITY hedefini gerçek bir el sıkışmayla seç: bazı siteler (ör. www.microsoft.com)
# ağa göre REALITY ile çalışmaz.
reality_selftest() {
	local site=$1 tmp p1 p2 code pids
	tmp=$(mktemp -d); p1=$((30000 + RANDOM % 10000)); p2=$((p1 + 1))
	cat >"$tmp/s.json" <<EOF
{"log":{"loglevel":"none"},"inbounds":[{"listen":"127.0.0.1","port":$p1,"protocol":"vless",
 "settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},
 "streamSettings":{"network":"tcp","security":"reality","realitySettings":{"target":"$site:443","serverNames":["$site"],"privateKey":"$PRIV","shortIds":["$SID"]}}}],
 "outbounds":[{"protocol":"freedom"}]}
EOF
	cat >"$tmp/c.json" <<EOF
{"log":{"loglevel":"none"},"inbounds":[{"listen":"127.0.0.1","port":$p2,"protocol":"socks"}],
 "outbounds":[{"protocol":"vless","settings":{"address":"127.0.0.1","port":$p1,"id":"$UUID","encryption":"none"},
 "streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"$site","fingerprint":"chrome","publicKey":"$PUB","shortId":"$SID"}}}]}
EOF
	"$XRAY" run -c "$tmp/s.json" >/dev/null 2>&1 & pids=$!
	"$XRAY" run -c "$tmp/c.json" >/dev/null 2>&1 & pids="$pids $!"
	sleep 2
	code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -x "socks5h://127.0.0.1:$p2" http://www.gstatic.com/generate_204 || true)
	kill $pids 2>/dev/null; wait $pids 2>/dev/null || true; rm -rf "$tmp"
	[ "$code" = 204 ]
}

pick_reality_site() {
	local list=$REALITY_CANDIDATES
	[ -n "$SNI" ] && list="$SNI $list"
	for s in $list; do
		log "REALITY hedefi deneniyor: $s"
		if reality_selftest "$s"; then
			[ -n "$SNI" ] && [ "$s" != "$SNI" ] && warn "$SNI çalışmadı, $s seçildi"
			SNI=$s; ok "REALITY hedefi: $SNI"; return
		fi
	done
	die "Hiçbir REALITY hedefi çalışmadı (sunucunun dış bağlantısını kontrol edin)"
}

save_state() {
	install -d -m 700 "$STATE_DIR"
	cat >"$STATE" <<EOF
MODE=$MODE
BRIDGE_PORT=$BRIDGE_PORT
SECURITY=$SECURITY
SNI=$SNI
TLS_CERT=$TLS_CERT
TLS_KEY=$TLS_KEY
USERS=$USERS
SOCKS_PORT=$SOCKS_PORT
FALLBACK=$FALLBACK
ENTRY_PORT=$ENTRY_PORT
ADDRESS=$ADDRESS
UUID=$UUID
ENTRY_UUID=${ENTRY_UUID:-}
PRIV=${PRIV:-}
PUB=${PUB:-}
SID=${SID:-}
IPV6=$IPV6
EOF
	chmod 600 "$STATE"
}

# Önceki kurulumun değerlerini koru; komut satırında verilenler önceliklidir.
load_state() {
	[ -f "$STATE" ] || return 0
	local -A cli=()
	for v in MODE BRIDGE_PORT SECURITY SNI TLS_CERT TLS_KEY USERS SOCKS_PORT FALLBACK ENTRY_PORT ADDRESS IPV6; do cli[$v]=${!v}; done
	# shellcheck disable=SC1090
	. "$STATE"
	IPV6=${IPV6:-0}
	for v in "${!cli[@]}"; do
		case "$v=${cli[$v]}" in
			MODE=auto|BRIDGE_PORT=10086|SECURITY=reality|SNI=|TLS_CERT=|TLS_KEY=|USERS=|SOCKS_PORT=1080|FALLBACK=direct|ENTRY_PORT=443|ADDRESS=|IPV6=0) ;;
			*) printf -v "$v" '%s' "${cli[$v]}" ;;
		esac
	done
}

bridge_link() {
	local addr=${ADDRESS:-$(public_ip)} q
	if [ "$SECURITY" = reality ]; then
		q="type=tcp&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID"
	else
		q="type=tcp&security=tls&sni=$SNI&fp=chrome"
	fi
	[ "$IPV6" = 1 ] && q="$q&ipv6=1"
	echo "vless://$UUID@$addr:$BRIDGE_PORT?encryption=none&$q#$NAME-bridge"
}

entry_link() {
	local addr=${ADDRESS:-$(public_ip)} q="security=tls&sni=$SNI&fp=chrome"
	[ "$SECURITY" = reality ] && q="security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID"
	echo "vless://$ENTRY_UUID@$addr:$ENTRY_PORT?encryption=none&flow=xtls-rprx-vision&type=tcp&$q#$NAME"
}

print_links() {
	local link; link=$(bridge_link)
	echo
	echo "${c_grn}────────────────────────── EV CİHAZI ──────────────────────────${c_off}"
	echo "Bağlantı linki (gizli tutun — bilen herkes ev çıkışınızı devralabilir):"
	echo "  $link"
	echo
	echo "OpenWrt / Raspberry Pi / Linux (root):"
	echo "  wget -qO- $RAW/client/install.sh | sh -s -- '$link'"
	echo "  ya da: curl -fsSL $RAW/client/install.sh | sh -s -- '$link'"
	echo
	echo "Windows (Yönetici PowerShell):"
	echo "  & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString((New-Object Net.WebClient).DownloadData('$RAW/client/install.ps1')))) -Link '$link'"
	if [ "$MODE" = standalone ] && [ "$ENTRY_PORT" != 0 ]; then
		echo
		echo "${c_grn}─────────────────── TELEFON / PC İSTEMCİ LİNKİ ───────────────────${c_off}"
		echo "  $(entry_link)"
		echo "  (v2rayNG, Hiddify, v2rayN, Streisand vb. ile içe aktarın)"
	fi
	echo
}

# ------------------------------------------------------------ x-ui (3x-ui) modu

xui_patch() {   # $1 = apply | remove ; çıktı: geçici doğrulama config yolu
	HE_ACTION=$1 HE_NAME=$NAME HE_DB=$XUI_DB HE_PORT=$BRIDGE_PORT HE_UUID=$UUID HE_SECURITY=$SECURITY \
	HE_SNI=$SNI HE_PRIV=${PRIV:-} HE_SID=${SID:-} HE_CERT=$TLS_CERT HE_KEY=$TLS_KEY HE_USERS=$USERS \
	HE_SOCKS=$SOCKS_PORT HE_FALLBACK=$FALLBACK HE_IPV6=$IPV6 HE_OUT=$2 python3 - <<'PY'
import json, os, sqlite3, sys
E = os.environ
name, action = E["HE_NAME"], E["HE_ACTION"]
T = lambda s: f"{name}-{s}"
db = sqlite3.connect(E["HE_DB"])

row = db.execute("select value from settings where key='xrayTemplateConfig'").fetchone()
if row:
    tpl = json.loads(row[0])
else:  # panel varsayılan şablonu kullanıyor: çalışan config'ten DB inbound'larını ayıklayarak türet
    tpl = json.load(open("/usr/local/x-ui/bin/config.json"))
    ports = {r[0] for r in db.execute("select port from inbounds")}
    tpl["inbounds"] = [i for i in tpl.get("inbounds", []) if i.get("port") not in ports]

ours = lambda tag: isinstance(tag, str) and tag.startswith(name + "-")
tpl["inbounds"] = [i for i in tpl.get("inbounds", []) if not ours(i.get("tag"))]
tpl["outbounds"] = [o for o in tpl.get("outbounds", []) if not ours(o.get("tag"))]
r = tpl.setdefault("routing", {})
r["rules"] = [x for x in r.get("rules", []) if not (ours(x.get("outboundTag")) or ours(x.get("balancerTag"))
              or any(ours(t) for t in x.get("inboundTag", [])))]
r["balancers"] = [b for b in r.get("balancers", []) if not ours(b.get("tag"))]
if not r["balancers"]:
    r.pop("balancers")
bo = tpl.get("burstObservatory")
if bo:
    bo["subjectSelector"] = [s for s in bo.get("subjectSelector", []) if not ours(s)]
    if not bo["subjectSelector"]:
        tpl.pop("burstObservatory")

if action == "apply":
    def tag_of(proto, fallback):
        for o in tpl["outbounds"]:
            if o.get("protocol") == proto:
                return o["tag"]
        tpl["outbounds"].append({"tag": T(fallback), "protocol": proto, "settings": {}})
        return T(fallback)
    direct, block = tag_of("freedom", "direct"), tag_of("blackhole", "block")

    if E["HE_SECURITY"] == "reality":
        sec = {"security": "reality", "realitySettings": {"target": E["HE_SNI"] + ":443", "serverNames": [E["HE_SNI"]],
               "privateKey": E["HE_PRIV"], "shortIds": [E["HE_SID"]]}}
    else:
        sec = {"security": "tls", "tlsSettings": {"certificates": [{"certificateFile": E["HE_CERT"], "keyFile": E["HE_KEY"]}]}}
    tpl["inbounds"].append({
        "tag": T("bridge"), "listen": "0.0.0.0", "port": int(E["HE_PORT"]), "protocol": "vless",
        "settings": {"clients": [{"id": E["HE_UUID"], "email": T("bridge"), "reverse": {"tag": T("portal")}}], "decryption": "none"},
        "streamSettings": {"network": "tcp", **sec, "sockopt": {"tcpNoDelay": True, "tcpKeepAliveIdle": 30}}})
    socks = int(E["HE_SOCKS"])
    if socks:
        tpl["inbounds"].append({"tag": T("socks"), "listen": "127.0.0.1", "port": socks, "protocol": "socks",
                                "settings": {"auth": "noauth", "udp": True}})

    r.setdefault("balancers", []).append({"tag": T("lb"), "selector": [T("portal")],
        "fallbackTag": direct if E["HE_FALLBACK"] == "direct" else block, "strategy": {"type": "leastPing"}})
    bo = tpl.setdefault("burstObservatory", {"pingConfig": {"destination": "http://www.gstatic.com/generate_204",
                        "interval": "10s", "sampling": 2, "timeout": "4s", "connectivity": ""}})
    bo.setdefault("subjectSelector", []).append(T("portal"))

    users = [u for u in E["HE_USERS"].split(",") if u]
    new = []
    for match in ([{"user": users}] if users else []) + ([{"inboundTag": [T("socks")]}] if socks else []):
        if E["HE_IPV6"] != "1":
            new.append({"type": "field", **match, "ip": ["::/0"], "outboundTag": block})
        new.append({"type": "field", **match, "balancerTag": T("lb")})
    # api ve dns kurallarından hemen sonra: panelin diğer kuralları kullanıcılarımızı yakalamasın
    at = 0
    for i, x in enumerate(r["rules"]):
        if "api" in x.get("inboundTag", []) or x.get("outboundTag") in ("api", "dns-out"):
            at = i + 1
    r["rules"][at:at] = new

    known = set()
    for (s,) in db.execute("select settings from inbounds"):
        try:
            known |= {c.get("email") for c in json.loads(s).get("clients", [])}
        except Exception:
            pass
    for u in users:
        if u not in known:
            print(f"UYARI: x-ui'de '{u}' adlı kullanıcı yok", file=sys.stderr)

# doğrulama için şablon + panel inbound'larından tam config üret
full = json.loads(json.dumps(tpl))
for listen, port, proto, settings, stream, tag, sniff in db.execute(
        "select listen, port, protocol, settings, stream_settings, tag, sniffing from inbounds where enable=1"):
    ib = {"listen": listen or None, "port": port, "protocol": proto, "tag": tag,
          "settings": json.loads(settings or "{}")}
    if stream: ib["streamSettings"] = json.loads(stream)
    if sniff: ib["sniffing"] = json.loads(sniff)
    full["inbounds"].append(ib)
json.dump(full, open(E["HE_OUT"], "w"), indent=1)
json.dump(tpl, open(E["HE_OUT"] + ".tpl", "w"), indent=2)
PY
}

xui_write_template() {
	python3 - "$1" "$XUI_DB" <<'PY'
import sqlite3, sys
v = open(sys.argv[1]).read(); db = sqlite3.connect(sys.argv[2])
if db.execute("select 1 from settings where key='xrayTemplateConfig'").fetchone():
    db.execute("update settings set value=? where key='xrayTemplateConfig'", (v,))
else:
    db.execute("insert into settings(key, value) values('xrayTemplateConfig', ?)", (v,))
db.commit()
PY
}

xui_restart_verify() {   # $1 = beklenen port (boşsa sadece servis), $2 = yedek
	systemctl restart x-ui
	for _ in $(seq 1 25); do
		sleep 1
		if systemctl is-active -q x-ui && { [ -z "$1" ] || port_busy "$1"; }; then return 0; fi
	done
	warn "x-ui yeni ayarla açılmadı, yedek geri yükleniyor"
	systemctl stop x-ui; sqlite3 "$XUI_DB" ".restore $2"; systemctl start x-ui
	die "Kurulum geri alındı. Günlük: journalctl -u x-ui -n 50"
}

xui_apply() {   # $1 = apply | remove
	command -v python3 >/dev/null || die "python3 gerekli (apt install python3)"
	command -v sqlite3 >/dev/null || { apt-get install -y sqlite3 >/dev/null 2>&1 || die "sqlite3 gerekli"; }
	local tmp bak; tmp=$(mktemp -d)
	if [ "$DRY_RUN" = 1 ]; then   # canlı veritabanına yazılmaz: kopyası üzerinde çalış
		sqlite3 "$XUI_DB" ".backup $tmp/copy.db"; XUI_DB=$tmp/copy.db
	fi
	xui_patch "$1" "$tmp/full.json"
	"$XRAY" run -test -c "$tmp/full.json" >"$tmp/test.log" 2>&1 || { cat "$tmp/test.log" >&2; die "Oluşan Xray ayarı geçersiz, hiçbir şey değiştirilmedi"; }
	if [ "$DRY_RUN" = 1 ]; then
		ok "Kuru çalıştırma: tam x-ui yapılandırması geçerli ($("$XRAY" version | awk 'NR==1{print $1" "$2}'))"
		python3 - "$tmp/full.json.tpl" "$NAME" <<'PY'
import json, sys
t, n = json.load(open(sys.argv[1])), sys.argv[2] + "-"
mine = lambda x: n in json.dumps(x)
print("  eklenecek inbound'lar:", [i["tag"] + ":" + str(i["port"]) for i in t["inbounds"] if i["tag"].startswith(n)])
print("  eklenecek kurallar:"); [print("   ", json.dumps(r)) for r in t["routing"]["rules"] if mine(r)]
print("  balancer:", [b for b in t["routing"].get("balancers", []) if b["tag"].startswith(n)])
PY
		rm -rf "$tmp"; return
	fi
	bak="$XUI_DB.bak-$NAME-$(date +%Y%m%d-%H%M%S)"
	sqlite3 "$XUI_DB" ".backup $bak"; ok "Yedek: $bak"
	xui_write_template "$tmp/full.json.tpl"
	log "x-ui yeniden başlatılıyor (bağlı kullanıcılar birkaç saniye kopar)"
	if [ "$1" = apply ]; then xui_restart_verify "$BRIDGE_PORT" "$bak"; else xui_restart_verify "" "$bak"; fi
	rm -rf "$tmp"
}

# --------------------------------------------------------------- standalone mod

standalone_config() {
	local sec entry="" socks="" rules="" match=""
	if [ "$SECURITY" = reality ]; then
		sec="\"security\":\"reality\",\"realitySettings\":{\"target\":\"$SNI:443\",\"serverNames\":[\"$SNI\"],\"privateKey\":\"$PRIV\",\"shortIds\":[\"$SID\"]}"
	else
		sec="\"security\":\"tls\",\"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"$TLS_CERT\",\"keyFile\":\"$TLS_KEY\"}]}"
	fi
	if [ "$ENTRY_PORT" != 0 ]; then
		entry=",{\"tag\":\"$NAME-entry\",\"port\":$ENTRY_PORT,\"protocol\":\"vless\",
   \"settings\":{\"clients\":[{\"id\":\"$ENTRY_UUID\",\"flow\":\"xtls-rprx-vision\",\"email\":\"user1\"}],\"decryption\":\"none\"},
   \"streamSettings\":{\"network\":\"tcp\",$sec,\"sockopt\":{\"tcpNoDelay\":true}},
   \"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"routeOnly\":true}}"
		match="\"$NAME-entry\""
	fi
	if [ "$SOCKS_PORT" != 0 ]; then
		socks=",{\"tag\":\"$NAME-socks\",\"listen\":\"127.0.0.1\",\"port\":$SOCKS_PORT,\"protocol\":\"socks\",\"settings\":{\"auth\":\"noauth\",\"udp\":true}}"
		match="${match:+$match,}\"$NAME-socks\""
	fi
	if [ -n "$match" ]; then
		rules="{\"type\":\"field\",\"inboundTag\":[$match],\"balancerTag\":\"$NAME-lb\"}"
		[ "$IPV6" = 1 ] || rules="{\"type\":\"field\",\"inboundTag\":[$match],\"ip\":[\"::/0\"],\"outboundTag\":\"block\"},
   $rules"
	fi
	local ds=UseIPv4; [ "$IPV6" = 1 ] && ds=UseIPv4v6
	cat <<EOF
{
 "log": {"loglevel": "warning", "access": "none"},
 "inbounds": [
  {"tag":"$NAME-bridge","port":$BRIDGE_PORT,"protocol":"vless",
   "settings":{"clients":[{"id":"$UUID","email":"$NAME-bridge","reverse":{"tag":"$NAME-portal"}}],"decryption":"none"},
   "streamSettings":{"network":"tcp",$sec,"sockopt":{"tcpNoDelay":true,"tcpKeepAliveIdle":30}}}$entry$socks
 ],
 "outbounds": [
  {"tag":"direct","protocol":"freedom","settings":{},"streamSettings":{"sockopt":{"domainStrategy":"$ds","tcpNoDelay":true}}},
  {"tag":"block","protocol":"blackhole","settings":{}}
 ],
 "routing": {
  "domainStrategy": "AsIs",
  "balancers": [{"tag":"$NAME-lb","selector":["$NAME-portal"],"fallbackTag":"$([ "$FALLBACK" = direct ] && echo direct || echo block)","strategy":{"type":"leastPing"}}],
  "rules": [
   {"type":"field","ip":[$PRIVATE_NETS],"outboundTag":"block"}${rules:+,
   $rules}
  ]
 },
 "burstObservatory": {"subjectSelector":["$NAME-portal"],
  "pingConfig":{"destination":"http://www.gstatic.com/generate_204","interval":"10s","sampling":2,"timeout":"4s","connectivity":""}}
}
EOF
}

standalone_apply() {
	command -v systemctl >/dev/null || die "standalone mod systemd gerektirir"
	local conf="$STATE_DIR/$NAME.json" unit="/etc/systemd/system/$NAME.service" tmp
	tmp=$(mktemp --suffix=.json)
	standalone_config >"$tmp"
	"$XRAY" run -test -c "$tmp" >"$tmp.err" 2>&1 || { grep -v "^Xray\|unified" "$tmp.err" >&2; cp "$tmp" /tmp/$NAME-invalid.json; die "Oluşan Xray ayarı geçersiz"; }
	if [ "$DRY_RUN" = 1 ]; then ok "Kuru çalıştırma: yapılandırma geçerli"; rm -f "$tmp" "$tmp.err"; return; fi
	install -d -m 700 "$STATE_DIR"; install -m 600 "$tmp" "$conf"; rm -f "$tmp" "$tmp.err"
	cat >"$unit" <<EOF
[Unit]
Description=xray-home-exit sunucu ($NAME)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$XRAY run -c $conf
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable -q "$NAME"
	systemctl restart "$NAME"
	sleep 2
	systemctl is-active -q "$NAME" || { journalctl -u "$NAME" -n 20 --no-pager >&2; die "$NAME servisi başlamadı"; }
	port_busy "$BRIDGE_PORT" || die "$BRIDGE_PORT portu dinlenmiyor"
}

# --------------------------------------------------------------------- komutlar

detect_mode() {
	if [ "$MODE" = auto ]; then
		if [ -f "$XUI_DB" ] && ls "$XUI_BIN_DIR"/xray-linux-* >/dev/null 2>&1; then MODE=xui; else MODE=standalone; fi
	fi
	case "$MODE" in xui|standalone) ;; *) die "--mode auto, xui veya standalone olmalı" ;; esac
	log "xray-home-exit $VERSION — mod: $MODE"
}

do_install() {
	load_state
	[ "$IPV6" = off ] && IPV6=0
	detect_mode
	command -v curl >/dev/null || die "curl gerekli"
	if [ "$MODE" = xui ]; then find_xui_xray; else install_xray_standalone; fi
	check_xray_version

	if [ "$SECURITY" = tls ]; then
		[ -r "$TLS_CERT" ] && [ -r "$TLS_KEY" ] || die "--tls-cert / --tls-key okunamıyor"
		[ -n "$SNI" ] || die "TLS için --sni ALANADI gerekli (sertifikadaki alan adı)"
	fi
	if [ -z "${UUID:-}" ] || [ "$REGEN" = 1 ]; then
		UUID=$("$XRAY" uuid); ENTRY_UUID=$("$XRAY" uuid)
		SID=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
		gen_keys
	fi
	[ -n "${ENTRY_UUID:-}" ] || ENTRY_UUID=$("$XRAY" uuid)
	if [ "$SECURITY" = reality ] && { [ ! -f "$STATE" ] || [ "$REGEN" = 1 ] || [ -z "$SNI" ]; }; then
		pick_reality_site
	fi

	local own_ports="$BRIDGE_PORT"
	[ "$SOCKS_PORT" != 0 ] && own_ports="$own_ports $SOCKS_PORT"
	[ "$MODE" = standalone ] && [ "$ENTRY_PORT" != 0 ] && own_ports="$own_ports $ENTRY_PORT"
	if ! [ -f "$STATE" ]; then
		for p in $own_ports; do port_busy "$p" && die "Port $p kullanımda (--port / --socks-port / --entry-port ile değiştirin)"; done
	fi

	if [ "$MODE" = xui ]; then xui_apply apply; else standalone_apply; fi
	[ "$DRY_RUN" = 1 ] && { ok "Kuru çalıştırma bitti, hiçbir şey değiştirilmedi"; return; }
	save_state
	if [ "$FALLBACK" = direct ]; then ok "Sunucu hazır. Ev cihazı bağlanana kadar trafik sunucunun kendi IP'sinden çıkar."
	else ok "Sunucu hazır. Ev cihazı bağlanana kadar yönlendirilen trafik engellenir."; fi
	[ "$MODE" = xui ] && [ -z "$USERS" ] && warn "Hiç x-ui kullanıcısı seçilmedi; yalnızca 127.0.0.1:$SOCKS_PORT eve gider. Eklemek için: --users e-posta1,e-posta2"
	print_links
}

do_uninstall() {
	[ -f "$STATE" ] || die "'$NAME' kurulumu bulunamadı ($STATE)"
	. "$STATE"
	if [ "$MODE" = xui ]; then
		find_xui_xray; xui_apply remove
	else
		systemctl disable --now "$NAME" 2>/dev/null || true
		rm -f "/etc/systemd/system/$NAME.service" "$STATE_DIR/$NAME.json"; systemctl daemon-reload
		ls "$STATE_DIR"/*.env 2>/dev/null | grep -qv "^$STATE$" || rm -rf "$LIB_DIR"
	fi
	rm -f "$STATE"
	rmdir "$STATE_DIR" 2>/dev/null || true
	ok "'$NAME' kaldırıldı"
}

do_status() {
	[ -f "$STATE" ] || die "'$NAME' kurulumu bulunamadı"
	. "$STATE"
	local n; n=$(ss -Htn state established "( sport = :$BRIDGE_PORT )" | wc -l)
	echo "Mod: $MODE   Köprü portu: $BRIDGE_PORT   Bağlı ev tüneli: $n"
	ss -Htn state established "( sport = :$BRIDGE_PORT )" | awk '{print "  ev cihazı: " $4}' | sed 's/\[::ffff://; s/\]//' | sort -u
	if [ "$SOCKS_PORT" != 0 ]; then
		echo "Çıkış IP'si (127.0.0.1:$SOCKS_PORT): $(curl -s -m 10 --socks5-hostname "127.0.0.1:$SOCKS_PORT" https://api.ipify.org || echo erişilemedi)"
		echo "Sunucu IP'si:                       $(public_ip)"
	fi
}

do_users() {
	[ -f "$XUI_DB" ] || die "x-ui bulunamadı"
	python3 - "$XUI_DB" <<'PY'
import json, sqlite3, sys
for port, remark, s in sqlite3.connect(sys.argv[1]).execute("select port, remark, settings from inbounds"):
    for c in json.loads(s).get("clients", []):
        print(f"{port:>6}  {remark or '':<20} {c.get('email')}")
PY
}

case "$ACTION" in
	install) do_install ;;
	uninstall) do_uninstall ;;
	status) do_status ;;
	users) do_users ;;
	link)
		[ -f "$STATE" ] || die "'$NAME' kurulumu bulunamadı"
		. "$STATE"; print_links ;;
esac
