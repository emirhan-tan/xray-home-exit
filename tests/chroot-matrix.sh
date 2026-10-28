#!/usr/bin/env bash
# Ev betiğini (client/install.sh) farklı mimari ve dağıtımlarda qemu-user + chroot
# içinde gerçekten çalıştırır ve tünelin trafik taşıdığını doğrular.
#
# Gereken: x86-64 Linux sunucu, root, qemu-user-static + binfmt (F bayraklı),
# bu sunucuda --fallback block ile kurulmuş bir test örneği:
#   bash server/install.sh --name hearch --mode standalone --port 20088 \
#        --entry-port 0 --socks-port 21082 --fallback block
#
# Kullanım: tests/chroot-matrix.sh 'vless://…' 21082 [hedef …]
set -uo pipefail

LINK=$1; SOCKS=$2; shift 2
HERE=$(cd "$(dirname "$0")" && pwd)
CLIENT=$HERE/../client/install.sh
WORK=${WORK:-/root/he/rootfs}
OW=https://downloads.openwrt.org/releases
mkdir -p "$WORK/cache"

# id | rootfs URL | ek ortam | ek install argümanları
TARGETS=(
	"ow24-aarch64|$OW/24.10.6/targets/armsr/armv8/openwrt-24.10.6-armsr-armv8-rootfs.tar.gz||"
	"ow24-armv7|$OW/24.10.6/targets/armsr/armv7/openwrt-24.10.6-armsr-armv7-rootfs.tar.gz||"
	"ow24-mips|$OW/24.10.6/targets/malta/be/openwrt-24.10.6-malta-be-default-rootfs.tar.gz||"
	"ow24-mipsel|$OW/24.10.6/targets/malta/le/openwrt-24.10.6-malta-le-default-rootfs.tar.gz||"
	"ow24-x86_64|$OW/24.10.6/targets/x86/64/openwrt-24.10.6-x86-64-rootfs.tar.gz||"
	"ow24-i386|$OW/24.10.6/targets/x86/generic/openwrt-24.10.6-x86-generic-rootfs.tar.gz||"
	"ow24-aarch64-ram|$OW/24.10.6/targets/armsr/armv8/openwrt-24.10.6-armsr-armv8-rootfs.tar.gz||--ram"
	"ow25-aarch64|$OW/25.12.6/targets/armsr/armv8/openwrt-25.12.6-armsr-armv8-rootfs.tar.gz||"
	"ow25-mipsel|$OW/25.12.6/targets/malta/le/openwrt-25.12.6-malta-le-default-rootfs.tar.gz||"
	"debian-arm64|lxc:debian/bookworm/arm64|HE_FORCE_INIT=systemd|"
	"debian-armhf|lxc:debian/bookworm/armhf|HE_FORCE_INIT=systemd|"
	"alpine-armv6|alpine:armhf|HE_FORCE_INIT=openrc QEMU_CPU=arm1176|"
	"alpine-riscv64|alpine:riscv64|HE_FORCE_INIT=openrc|"
)

resolve_url() {
	case "$1" in
		lxc:*)
			local p=${1#lxc:} b=https://images.linuxcontainers.org/images
			local d; d=$(curl -fsSL "$b/$p/default/" | grep -oE '[0-9]{8}_[0-9]{2}(:|%3A)[0-9]{2}' | sort -u | tail -1)
			echo "$b/$p/default/$d/rootfs.tar.xz" ;;
		alpine:*)
			local a=${1#alpine:} b=https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases
			local f; f=$(curl -fsSL "$b/$a/latest-releases.yaml" | awk '/file: alpine-minirootfs/{print $2; exit}')
			echo "$b/$a/$f" ;;
		*) echo "$1" ;;
	esac
}

socks_ip() { curl -s -m 8 --socks5-hostname "127.0.0.1:$SOCKS" https://api.ipify.org; }

run_target() {
	local id=$1 src=$2 envs=$3 extra=$4 root="$WORK/$id" url tar log="$WORK/$id.log"
	url=$(resolve_url "$src"); tar="$WORK/cache/$(echo "$url" | md5sum | cut -c1-12).tar"
	[ -s "$tar" ] || curl -fsSL -o "$tar" "$url" || { echo "$id|İNDİRİLEMEDİ|$url"; return; }
	cleanup "$root"; [ -e "$root" ] && { echo "$id|ATLANDI|$root temizlenemedi"; return; }
	mkdir -p "$root"
	tar -xf "$tar" -C "$root" 2>/dev/null
	mkdir -p "$root"/{proc,tmp,run,var/lock}
	# Ana makinenin /dev'i ASLA bağlanmaz: chroot'a kendi aygıt düğümleri açılır
	rm -rf "$root/dev"; mkdir -p "$root/dev"
	mknod -m 666 "$root/dev/null" c 1 3; mknod -m 666 "$root/dev/zero" c 1 5
	mknod -m 666 "$root/dev/random" c 1 8; mknod -m 666 "$root/dev/urandom" c 1 9
	mknod -m 666 "$root/dev/tty" c 5 0
	mount -t proc proc "$root/proc"
	rm -f "$root/etc/resolv.conf"; cp /etc/resolv.conf "$root/etc/resolv.conf"; cp /etc/resolv.conf "$root/tmp/resolv.conf"
	cp "$CLIENT" "$root/install.sh"
	# Raspberry Pi OS / Debian'da curl, gerçek Alpine'de OpenRC zaten kuruludur (minirootfs'te yok)
	case "$id" in
		debian-*) chroot "$root" sh -c 'apt-get update -qq && apt-get install -y -qq curl ca-certificates' >>"$log" 2>&1 ;;
		alpine-*) chroot "$root" apk add -q openrc >>"$log" 2>&1 ;;
	esac

	local t0=$SECONDS rc lib res arch ver
	env $envs chroot "$root" /bin/sh /install.sh --name t "$LINK" --no-service $extra >"$log" 2>&1; rc=$?
	if [ $rc != 0 ]; then echo "$id|KURULUM HATASI|$(grep -E '✘' "$log" | tail -1)"; cleanup "$root"; return; fi
	lib=$(grep -oE '/usr(/local)?/lib/t/run' "$log" | head -1); [ -n "$lib" ] || lib=$( [ -x "$root/usr/lib/t/run" ] && echo /usr/lib/t/run || echo /usr/local/lib/t/run)
	[ "$extra" = --ram ] && rm -f "$root/tmp/t/xray"   # açılıştaki indirme yolunu da sına
	env $envs chroot "$root" "$lib" >>"$log" 2>&1 &
	local pid=$!
	res=""; for _ in $(seq 1 45); do sleep 2; res=$(socks_ip) && [ -n "$res" ] && break; done
	arch=$(env $envs chroot "$root" uname -m)
	ver=$(grep -oE 'Xray [0-9.]+' "$log" | head -1)
	kill $pid 2>/dev/null; sleep 1; pkill -9 -f "run -c /etc/t/config.json" 2>/dev/null
	local how; how=$(grep -oE 'OpenWrt paketi kuruluyor|Mevcut Xray|Xray indiriliyor[^:]*|RAM' "$log" | head -1)
	if [ -n "$res" ]; then echo "$id|OK|$arch, $ver, ${how:-?}, $((SECONDS - t0)) sn"; else echo "$id|TÜNEL YOK|$arch, $ver; günlük: $log"; fi
	cleanup "$root"
}

cleanup() {
	umount "$1/proc" 2>/dev/null
	if findmnt -rn -o TARGET | grep -q "^$1/"; then
		echo "UYARI: $1 altında hâlâ bağlı dosya sistemi var, silinmedi" >&2; return
	fi
	[ "${KEEP:-0}" = 1 ] || rm -rf --one-file-system "$1"
}

[ -z "$(socks_ip)" ] || { echo "SOCKS $SOCKS zaten çıkış veriyor: test sunucusunu --fallback block ile kurun ve başka köprüyü kapatın"; exit 1; }

for t in "${TARGETS[@]}"; do
	IFS='|' read -r id src envs extra <<<"$t"
	if [ $# -gt 0 ]; then case " $* " in *" $id "*) ;; *) continue ;; esac; fi
	run_target "$id" "$src" "$envs" "$extra"
done
echo "MATRIX_DONE"
