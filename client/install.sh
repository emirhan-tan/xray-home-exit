#!/bin/sh
# xray-home-exit — ev cihazı kurulumu (OpenWrt, Raspberry Pi, Debian/Ubuntu, Alpine…)
#
# Evdeki cihaz sunucuya içeriden dışarıya kalıcı bir VLESS Reverse tüneli açar;
# sunucudaki seçili trafik bu tünelden ev internetine çıkar. CGNAT, dinamik IP
# veya port yönlendirme gerekmez.
#
#   wget -qO- https://raw.githubusercontent.com/emirhan-tan/xray-home-exit/main/client/install.sh | sh -s -- 'vless://…'
#
# Komutlar: install (varsayılan) | uninstall | status
# Seçenekler:
#   --name AD          servis adı (varsayılan: home-exit)
#   --allow-lan        sunucudan ev yerel ağına (192.168.x vb.) erişime izin ver
#   --ipv6 / --no-ipv6 IPv6 çıkışını aç/kapat (varsayılan: linkteki ipv6=1, yoksa kapalı)
#   --mark N           giden paketlere SO_MARK (OpenWrt'de varsayılan 255; 0 = kapalı)
#   --ram              Xray'i flash yerine RAM'de tut, her açılışta indir (küçük flash)
#   --xray-version V   indirilecek Xray sürümü (varsayılan: latest)
#   --no-service       servis kurma/başlatma (test ve özel init sistemleri için)
set -eu

VERSION=1.0.0
NAME=home-exit
LINK=""
ALLOW_LAN=0
IPV6=""
MARK=""
RAM=0
XRAY_VERSION=latest
NO_SERVICE=${HE_NO_SERVICE:-0}
ACTION=install

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		install|uninstall|status) ACTION=$1 ;;
		vless://*) LINK=$1 ;;
		--link) LINK=$2; shift ;;
		--name) NAME=$2; shift ;;
		--allow-lan) ALLOW_LAN=1 ;;
		--ipv6) IPV6=1 ;;
		--no-ipv6) IPV6=0 ;;
		--mark) MARK=$2; shift ;;
		--ram) RAM=1 ;;
		--xray-version) XRAY_VERSION=$2; shift ;;
		--no-service) NO_SERVICE=1 ;;
		-v|--version) echo "xray-home-exit $VERSION"; exit 0 ;;
		-h|--help) sed -n '2,20p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "Bilinmeyen seçenek: $1" ;;
	esac
	shift
done

[ "$(id -u)" = 0 ] || die "root olarak çalıştırın (sudo sh …)"
case "$NAME" in *[!a-z0-9-]*|"") die "--name yalnızca küçük harf, rakam ve - içerebilir" ;; esac

# ------------------------------------------------------------------ platform

if [ -f /etc/openwrt_release ]; then
	PLATFORM=openwrt
	. /etc/openwrt_release
	CONF_DIR=/etc/$NAME
	LIB=/usr/lib/$NAME
	[ -n "$MARK" ] || MARK=255
elif [ -d /run/systemd/system ] || [ "${HE_FORCE_INIT:-}" = systemd ]; then
	PLATFORM=systemd
elif command -v rc-service >/dev/null 2>&1 || [ "${HE_FORCE_INIT:-}" = openrc ]; then
	PLATFORM=openrc
else
	PLATFORM=none
fi
if [ "$PLATFORM" != openwrt ]; then
	CONF_DIR=/etc/$NAME
	LIB=/usr/local/lib/$NAME
fi
[ -n "$MARK" ] || MARK=0
CONF=$CONF_DIR/config.json
ENVF=$CONF_DIR/env
RAM_DIR=/tmp/$NAME

pkg_install() {
	case "$PLATFORM" in
		openwrt)
			if command -v apk >/dev/null 2>&1; then apk update >/dev/null 2>&1; apk add "$@"
			else opkg update >/dev/null 2>&1; opkg install "$@"; fi ;;
		*)
			if command -v apt-get >/dev/null 2>&1; then apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
			elif command -v apk >/dev/null 2>&1; then apk add "$@"
			elif command -v dnf >/dev/null 2>&1; then dnf install -y "$@"
			elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm "$@"
			else return 1; fi ;;
	esac
}

is_little_endian() {
	case "${DISTRIB_ARCH:-}" in mipsel*|mips64el*) return 0 ;; mips_*|mips64_*) return 1 ;; esac
	# ELF başlığının 6. baytı: 1 = little-endian, 2 = big-endian
	[ "$(dd if=/bin/sh bs=1 skip=5 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')" = 1 ]
}

xray_arch() {
	# OpenWrt: kullanıcı alanının mimarisi (64 bit çekirdekte 32 bit imaj olabilir)
	case "${DISTRIB_ARCH:-}" in
		x86_64) echo 64; return ;;
		i386*) echo 32; return ;;
		aarch64*) echo arm64-v8a; return ;;
		arm_arm1176*|arm_arm11*) echo arm32-v6; return ;;
		arm_arm926*|arm_xscale*|arm_fa526*|arm_arm9*) echo arm32-v5; return ;;
		arm_*) echo arm32-v7a; return ;;
		mipsel_*) echo mips32le; return ;;
		mips_*) echo mips32; return ;;
		mips64el_*) echo mips64le; return ;;
		mips64_*) echo mips64; return ;;
		riscv64*) echo riscv64; return ;;
		loongarch64*) echo loong64; return ;;
	esac
	case "$(uname -m)" in
		x86_64|amd64) echo 64 ;;
		i?86) echo 32 ;;
		aarch64|arm64) echo arm64-v8a ;;
		armv7*|armv8l) echo arm32-v7a ;;
		armv6*) echo arm32-v6 ;;
		armv5*|armv4*) echo arm32-v5 ;;
		mips64) if is_little_endian; then echo mips64le; else echo mips64; fi ;;
		mips*) if is_little_endian; then echo mips32le; else echo mips32; fi ;;
		riscv64) echo riscv64 ;;
		loongarch64) echo loong64 ;;
		ppc64le) echo ppc64le ;;
		s390x) echo s390x ;;
		*) die "Desteklenmeyen mimari: $(uname -m)" ;;
	esac
}

xray_major() { "$1" version 2>/dev/null | awk 'NR==1{split($2,v,"."); print v[1]+0}'; }

free_kb() {   # $1 dizininin bulunduğu dosya sistemindeki boş alan (kB)
	d=$1; while [ ! -d "$d" ]; do d=$(dirname "$d"); done
	v=$(df -k "$d" 2>/dev/null | awk 'NR>1{v=$4} END{if (NR>1) print v+0}')
	echo "${v:-999999999}"   # ölçülemiyorsa (ör. chroot) engelleme
}

xray_url() {
	if [ "$XRAY_VERSION" = latest ]; then
		echo "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$(xray_arch).zip"
	else
		echo "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-$(xray_arch).zip"
	fi
}

# İndirme yardımcıları: RAM modunda açılışta çalışan "run" betiğine aynen
# kopyalanır, bu yüzden yalnızca kendi argümanlarını kullanırlar.
DL_FUNCS='
fetch() {   # fetch URL DOSYA
	if command -v curl >/dev/null 2>&1; then curl -fsL --retry 3 -o "$2" "$1"
	elif command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -q -O "$2" "$1"
	else wget -q -O "$2" "$1"; fi
}
has_unzip() {
	command -v unzip >/dev/null 2>&1 || busybox --list 2>/dev/null | grep -qx unzip || command -v python3 >/dev/null 2>&1
}
download_xray() {   # download_xray URL HEDEF
	tmp=$(mktemp -d /tmp/he.XXXXXX)
	fetch "$1" "$tmp/x.zip" || { rm -rf "$tmp"; return 1; }
	if command -v unzip >/dev/null 2>&1; then unzip -qo "$tmp/x.zip" -d "$tmp"
	elif busybox --list 2>/dev/null | grep -qx unzip; then busybox unzip -qo "$tmp/x.zip" -d "$tmp"
	else python3 -m zipfile -e "$tmp/x.zip" "$tmp"; fi || { rm -rf "$tmp"; return 2; }
	bin=$tmp/xray
	# MIPS yönlendiricilerde çoğunlukla FPU yoktur
	case "$1" in *-mips*) [ -f "$tmp/xray_softfloat" ] && bin=$tmp/xray_softfloat ;; esac
	mkdir -p "$(dirname "$2")"
	mv "$bin" "$2.tmp" && chmod 755 "$2.tmp" && mv "$2.tmp" "$2"
	rc=$?; rm -rf "$tmp"; return $rc
}
'
eval "$DL_FUNCS"

ensure_unzip() {
	has_unzip && return 0
	log "unzip kuruluyor"
	pkg_install unzip >/tmp/he-pkg.log 2>&1 || { tail -5 /tmp/he-pkg.log >&2; die "unzip kurulamadı; elle kurup tekrar deneyin"; }
}

# XRAY değişkenini ayarlar: mevcut Xray (>=26) > OpenWrt paketi > resmi sürüm (flash) > RAM
setup_xray() {
	for c in "$LIB/xray" "$(command -v xray 2>/dev/null || true)"; do
		if [ -n "$c" ] && [ -x "$c" ] && [ "$(xray_major "$c")" -ge 26 ] 2>/dev/null && [ "$XRAY_VERSION" = latest ] && [ "$RAM" = 0 ]; then
			XRAY=$c; ok "Mevcut Xray kullanılıyor: $("$c" version | head -1)"; return
		fi
	done
	if [ "$PLATFORM" = openwrt ] && [ "$RAM" = 0 ] && [ "$XRAY_VERSION" = latest ]; then
		ver=""
		if command -v apk >/dev/null 2>&1; then
			apk update >/dev/null 2>&1 || true
			ver=$(apk search -x xray-core 2>/dev/null | sed -n 's/^xray-core-\([0-9]*\)\..*/\1/p' | head -1)
		else
			opkg update >/dev/null 2>&1 || true
			ver=$(opkg info xray-core 2>/dev/null | sed -n 's/^Version: \([0-9]*\)\..*/\1/p' | head -1)
		fi
		if [ -n "$ver" ] && [ "$ver" -ge 26 ] && [ "$(free_kb /usr/lib)" -gt 36000 ] 2>/dev/null; then
			log "OpenWrt paketi kuruluyor: xray-core ($ver.x)"
			if pkg_install xray-core >/dev/null 2>&1; then
				[ -x /etc/init.d/xray ] && { /etc/init.d/xray stop; /etc/init.d/xray disable; } >/dev/null 2>&1
				XRAY=$(command -v xray); ok "$("$XRAY" version | head -1)"; return
			fi
			warn "Paket kurulamadı, resmi sürüm indirilecek"
		fi
	fi
	ensure_unzip
	need=$(( 45000 ))
	if [ "$RAM" = 0 ] && [ "$(free_kb "$LIB")" -lt "$need" ] 2>/dev/null; then
		[ "$PLATFORM" = openwrt ] || die "Diskte yer yok (en az ~45 MB gerekli)"
		warn "Flash'ta yer yok; Xray RAM'de tutulacak ve her açılışta indirilecek"
		RAM=1
	fi
	if [ "$RAM" = 1 ]; then
		mem=$(awk '/MemTotal/{print $2}' /proc/meminfo)
		[ "$mem" -lt 120000 ] && warn "RAM ${mem} kB: 128 MB altı cihazlarda Xray zorlanabilir"
		XRAY=$RAM_DIR/xray
	else
		XRAY=$LIB/xray
	fi
	XRAY_URL=$(xray_url)
	log "Xray indiriliyor: $XRAY_URL"
	download_xray "$XRAY_URL" "$XRAY" || die "Xray indirilemedi"
	ok "$("$XRAY" version | head -1)"
}

# ---------------------------------------------------------------- link çözme

urldecode() { printf '%b' "$(echo "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"; }
param() { echo "$QUERY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1 | { read -r v || true; urldecode "${v:-}"; }; }

parse_link() {
	[ -n "$LINK" ] || die "Bağlantı linki gerekli: install.sh 'vless://…' (sunucuda: install.sh link)"
	rest=${LINK#vless://}; rest=${rest%%#*}
	UUID=${rest%%@*}; rest=${rest#*@}
	QUERY=""; case "$rest" in *\?*) QUERY=${rest#*\?}; rest=${rest%%\?*} ;; esac
	rest=${rest%/}
	case "$rest" in
		\[*) HOST=${rest%%]*}; HOST=${HOST#[}; PORT=${rest##*]:} ;;
		*) HOST=${rest%:*}; PORT=${rest##*:} ;;
	esac
	SECURITY=$(param security); SNI=$(param sni); PBK=$(param pbk); SID=$(param sid); FP=$(param fp)
	[ -n "$FP" ] || FP=chrome
	[ -n "$IPV6" ] || { [ "$(param ipv6)" = 1 ] && IPV6=1 || IPV6=0; }
	echo "$UUID" | grep -Eq '^[0-9a-fA-F-]{36}$' || die "Linkteki UUID geçersiz"
	echo "$PORT" | grep -Eq '^[0-9]+$' || die "Linkteki port geçersiz"
	case "$SECURITY" in
		reality) [ -n "$PBK" ] && [ -n "$SNI" ] || die "REALITY linkinde pbk/sni eksik" ;;
		tls) [ -n "$SNI" ] || SNI=$HOST ;;
		*) die "Desteklenmeyen güvenlik türü: '$SECURITY' (reality veya tls)" ;;
	esac
}

write_config() {
	if [ "$SECURITY" = reality ]; then
		sec="\"security\": \"reality\", \"realitySettings\": {\"serverName\": \"$SNI\", \"fingerprint\": \"$FP\", \"publicKey\": \"$PBK\", \"shortId\": \"$SID\"}"
	else
		sec="\"security\": \"tls\", \"tlsSettings\": {\"serverName\": \"$SNI\", \"fingerprint\": \"$FP\"}"
	fi
	m=""; [ "$MARK" != 0 ] && m=", \"mark\": $MARK"
	# engellenecek hedefler: IPv6 kapalıysa tamamı, açıksa yalnızca yerel IPv6 aralıkları
	if [ "$IPV6" = 1 ]; then nets='"224.0.0.0/3", "ff00::/8"'; ds=UseIPv4v6
	else nets='"224.0.0.0/3", "::/0"'; ds=UseIPv4; fi
	[ "$ALLOW_LAN" = 1 ] || nets="$nets, \"0.0.0.0/8\", \"10.0.0.0/8\", \"100.64.0.0/10\", \"127.0.0.0/8\", \"169.254.0.0/16\", \"172.16.0.0/12\", \"192.168.0.0/16\", \"::1/128\", \"fc00::/7\", \"fe80::/10\""
	mkdir -p "$CONF_DIR"; umask 077
	cat >"$CONF_DIR/config.new.json" <<EOF
{
  "log": { "loglevel": "warning", "access": "none" },
  "outbounds": [
    {
      "tag": "home-direct", "protocol": "freedom",
      "settings": { "finalRules": [ { "action": "block", "ip": [$nets], "blockDelay": "0" }, { "action": "allow" } ] },
      "streamSettings": { "sockopt": { "domainStrategy": "$ds", "tcpNoDelay": true, "tcpKeepAliveIdle": 30$m } }
    },
    {
      "tag": "to-server", "protocol": "vless",
      "settings": { "address": "$HOST", "port": $PORT, "id": "$UUID", "encryption": "none", "reverse": { "tag": "bridge" } },
      "streamSettings": { "network": "tcp", $sec,
        "sockopt": { "tcpNoDelay": true, "tcpKeepAliveIdle": 30$m } }
    },
    { "tag": "block", "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["bridge"], "ip": [$nets], "outboundTag": "block" },
      { "type": "field", "inboundTag": ["bridge"], "outboundTag": "home-direct" }
    ]
  }
}
EOF
	"$XRAY" run -test -c "$CONF_DIR/config.new.json" >/dev/null 2>&1 || { "$XRAY" run -test -c "$CONF_DIR/config.new.json" >&2 || true; rm -f "$CONF_DIR/config.new.json"; die "Oluşan ayar geçersiz"; }
	mv "$CONF_DIR/config.new.json" "$CONF"
	umask 022
	cat >"$ENVF" <<EOF
NAME=$NAME
HOST=$HOST
PORT=$PORT
XRAY=$XRAY
RAM=$RAM
XRAY_URL=${XRAY_URL:-}
EOF
}

# ------------------------------------------------------------------ servisler

write_helpers() {
	mkdir -p "$LIB"
	# Ön plan çalıştırıcı: RAM modunda Xray yoksa ağ gelene kadar indirmeyi dener
	{
		echo '#!/bin/sh'
		echo ". $ENVF"
		printf '%s\n' "$DL_FUNCS"
		cat <<'EOF'
if [ ! -x "$XRAY" ]; then
	i=0
	until download_xray "$XRAY_URL" "$XRAY"; do
		i=$((i + 1)); [ $i -gt 60 ] && exit 1; sleep 10
	done
fi
export GOMEMLIMIT=${GOMEMLIMIT:-40MiB} GOGC=${GOGC:-50}
EOF
		echo "exec \"\$XRAY\" run -c $CONF"
	} >"$LIB/run"
	# Bekçi: sunucuya kurulu bağlantı yoksa 2. ardışık kontrolde yeniden başlat
	cat >"$LIB/watchdog" <<EOF
#!/bin/sh
. $ENVF
F=/tmp/\$NAME.miss
if command -v ss >/dev/null 2>&1; then
	ss -Htn state established "( dport = :\$PORT )" 2>/dev/null | grep -q . && { rm -f "\$F"; exit 0; }
else
	netstat -tn 2>/dev/null | grep -Eq ":\$PORT[[:space:]]+ESTABLISHED" && { rm -f "\$F"; exit 0; }
fi
n=\$(( \$(cat "\$F" 2>/dev/null || echo 0) + 1 )); echo \$n >"\$F"
[ \$n -lt 2 ] && exit 0
logger -t \$NAME "sunucu bağlantısı yok, yeniden başlatılıyor" 2>/dev/null || true
rm -f "\$F"
EOF
	case "$PLATFORM" in
		openwrt) echo "/etc/init.d/$NAME restart" >>"$LIB/watchdog" ;;
		systemd) echo "systemctl restart $NAME" >>"$LIB/watchdog" ;;
		openrc)  echo "rc-service $NAME restart" >>"$LIB/watchdog" ;;
	esac
	chmod 755 "$LIB/run" "$LIB/watchdog"
}

add_cron() {   # $1 = crontab dosyası
	touch "$1"
	grep -q "$LIB/watchdog" "$1" || echo "*/2 * * * * $LIB/watchdog" >>"$1"
}

install_service() {
	case "$PLATFORM" in
	openwrt)
		cat >/etc/init.d/$NAME <<EOF
#!/bin/sh /etc/rc.common
# xray-home-exit ev köprüsü

START=99
STOP=10
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command $LIB/run
	procd_set_param env GOMEMLIMIT=25MiB GOGC=30
	procd_set_param file $CONF
	procd_set_param respawn 3600 5 0
	procd_set_param limits nofile="65535 65535"
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
EOF
		chmod 755 /etc/init.d/$NAME
		add_cron /etc/crontabs/root
		for f in "$CONF_DIR/" "$LIB/" "/etc/init.d/$NAME"; do
			grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >>/etc/sysupgrade.conf
		done
		[ "$NO_SERVICE" = 1 ] && return
		/etc/init.d/cron enable; /etc/init.d/cron restart
		/etc/init.d/$NAME enable
		/etc/init.d/$NAME stop >/dev/null 2>&1 || true
		/etc/init.d/$NAME start ;;
	systemd)
		cat >/etc/systemd/system/$NAME.service <<EOF
[Unit]
Description=xray-home-exit ev köprüsü
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$LIB/run
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
		cat >/etc/systemd/system/$NAME-watchdog.service <<EOF
[Unit]
Description=xray-home-exit bekçi

[Service]
Type=oneshot
ExecStart=$LIB/watchdog
EOF
		cat >/etc/systemd/system/$NAME-watchdog.timer <<EOF
[Unit]
Description=xray-home-exit bekçi (2 dk)

[Timer]
OnBootSec=3min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF
		[ "$NO_SERVICE" = 1 ] && return
		systemctl daemon-reload
		systemctl enable -q $NAME $NAME-watchdog.timer
		systemctl restart $NAME; systemctl start $NAME-watchdog.timer ;;
	openrc)
		mkdir -p /etc/init.d /etc/crontabs
		cat >/etc/init.d/$NAME <<EOF
#!/sbin/openrc-run
description="xray-home-exit ev köprüsü"
command=$LIB/run
command_background=true
pidfile=/run/$NAME.pid
supervisor=supervise-daemon
respawn_delay=5
respawn_max=0
depend() { need net; }
EOF
		chmod 755 /etc/init.d/$NAME
		add_cron /etc/crontabs/root
		[ "$NO_SERVICE" = 1 ] && return
		rc-update add crond default >/dev/null 2>&1 || true; rc-service crond start >/dev/null 2>&1 || true
		rc-update add $NAME default; rc-service $NAME restart ;;
	none)
		warn "Tanınan bir servis yöneticisi yok. Elle çalıştırın: $LIB/run"
		NO_SERVICE=1 ;;
	esac
}

wait_connected() {
	log "Sunucuya bağlanılıyor ($HOST:$PORT)"
	i=0
	while [ $i -lt 20 ]; do
		sleep 1; i=$((i + 1))
		if command -v ss >/dev/null 2>&1; then
			ss -Htn state established "( dport = :$PORT )" 2>/dev/null | grep -q . && return 0
		else
			netstat -tn 2>/dev/null | grep -Eq ":$PORT[[:space:]]+ESTABLISHED" && return 0
		fi
	done
	return 1
}

# ------------------------------------------------------------------- komutlar

do_install() {
	parse_link
	log "xray-home-exit $VERSION — platform: $PLATFORM ($(uname -m)${DISTRIB_DESCRIPTION:+, $DISTRIB_DESCRIPTION}), IPv6: $([ "$IPV6" = 1 ] && echo açık || echo kapalı)"
	setup_xray
	write_config
	write_helpers
	install_service
	if [ "$NO_SERVICE" = 1 ]; then
		ok "Dosyalar kuruldu (servis başlatılmadı). Çalıştırmak için: $LIB/run"
		return
	fi
	if wait_connected; then
		ok "Tünel kuruldu. Sunucuda kontrol: bash install.sh status"
	else
		warn "20 sn içinde bağlantı kurulamadı. Linki, sunucunun $PORT portunu ve günlüğü kontrol edin:"
		case "$PLATFORM" in
			openwrt) warn "  logread -e xray | tail" ;;
			systemd) warn "  journalctl -u $NAME -n 30" ;;
		esac
		exit 1
	fi
}

do_uninstall() {
	case "$PLATFORM" in
		openwrt)
			[ -x /etc/init.d/$NAME ] && { /etc/init.d/$NAME stop; /etc/init.d/$NAME disable; } 2>/dev/null
			rm -f /etc/init.d/$NAME
			sed -i "\#$LIB/watchdog#d" /etc/crontabs/root 2>/dev/null; /etc/init.d/cron restart 2>/dev/null
			sed -i "\#^$CONF_DIR/\$#d; \#^$LIB/\$#d; \#^/etc/init.d/$NAME\$#d" /etc/sysupgrade.conf 2>/dev/null ;;
		systemd)
			systemctl disable --now $NAME $NAME-watchdog.timer 2>/dev/null || true
			rm -f /etc/systemd/system/$NAME.service /etc/systemd/system/$NAME-watchdog.service /etc/systemd/system/$NAME-watchdog.timer
			systemctl daemon-reload ;;
		openrc)
			rc-service $NAME stop 2>/dev/null; rc-update del $NAME default 2>/dev/null
			rm -f /etc/init.d/$NAME; sed -i "\#$LIB/watchdog#d" /etc/crontabs/root 2>/dev/null ;;
	esac
	rm -rf "$CONF_DIR" "$LIB" "$RAM_DIR" /tmp/$NAME.miss
	ok "'$NAME' kaldırıldı (OpenWrt xray-core paketi kuruluysa: apk del xray-core / opkg remove xray-core)"
}

do_status() {
	[ -f "$ENVF" ] || die "'$NAME' kurulu değil"
	. "$ENVF"
	echo "Sunucu: $HOST:$PORT   Xray: $XRAY"
	if wait_connected >/dev/null 2>&1; then ok "Tünel bağlı"; else warn "Tünel bağlı değil"; fi
}

case "$ACTION" in
	install) do_install ;;
	uninstall) do_uninstall ;;
	status) do_status ;;
esac
