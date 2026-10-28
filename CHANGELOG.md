# Değişiklik günlüğü

Sürümler [Semantic Versioning](https://semver.org/lang/tr/) kurallarına uyar.

## [1.0.0] — 2026-10-28

İlk sürüm.

### Sunucu (`server/install.sh`)
- x-ui / 3x-ui otomatik algılama: köprü yalnızca Xray şablonuna eklenir, panel kullanıcılarına dokunulmaz.
  Önce tam yapılandırma `xray run -test` ile doğrulanır, veritabanı yedeklenir, x-ui açılmazsa geri alınır.
- x-ui yoksa standalone Xray kurulumu ve telefon/PC için hazır VLESS REALITY linki.
- Kullanıcı bazlı yönlendirme (`--users`) ve sunucu içi `127.0.0.1:1080` SOCKS5.
- Otomatik yedek hat: ev tüneli düşünce ~10 sn içinde sunucu IP'sine geçiş, geri gelince eve dönüş
  (`--fallback direct|block`).
- REALITY varsayılan; hedef site gerçek bir el sıkışmayla otomatik seçilir. İsteğe bağlı TLS.
- İsteğe bağlı IPv6 (`--ipv6`), kuru çalıştırma (`--dry-run`), `link` / `status` / `users` / `uninstall`.

### Ev cihazı (`client/install.sh`, `client/install.ps1`)
- OpenWrt 24.10 (opkg) ve 25.12 (apk), procd servisi + cron bekçi, `sysupgrade` koruması.
- Raspberry Pi OS / Debian / Ubuntu (systemd + bekçi zamanlayıcısı), Alpine (OpenRC).
- Windows 10/11: SYSTEM zamanlanmış görevi, kapanınca 5 sn'de yeniden başlatma, bekçi.
- Mimari otomatik: arm64, armv7, armv6, armv5, mips/mipsel (softfloat), mips64, x86_64, i386, riscv64, loong64.
- Küçük flash'lı router'lar için RAM modu (`--ram`).
- Ev yerel ağına erişim ve IPv6 varsayılan olarak engelli (`--allow-lan`, `--ipv6`).
- Xray 26.10+ için freedom `finalRules` (reverse trafiğinin varsayılan engellenmesini kaldırır).

### Test edilenler
OpenWrt 24.10 (aarch64, armv7, mips, mipsel, x86_64, i386, RAM modu), OpenWrt 25.12 (aarch64, mipsel),
Debian 12 (arm64, armhf), Alpine (armv6, riscv64) — qemu + chroot ile tünelden gerçek trafik;
gerçek donanımda OpenWrt 25.12 arm64 router ve Windows 10 x64.

[1.0.0]: https://github.com/emirhan-tan/xray-home-exit/releases/tag/v1.0.0
