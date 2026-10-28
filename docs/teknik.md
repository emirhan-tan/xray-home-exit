# Teknik notlar

## Mimari

Xray 26'nın **VLESS Reverse Proxy** özelliği kullanılır (eski üst seviye `"reverse": {bridges, portals}`
yapısı 26.x'te kaldırıldı).

- **Sunucu:** VLESS inbound'undaki bir istemciye `"reverse": {"tag": "<ad>-portal"}` eklenir.
  Bu istemciyle bağlanan cihaz, `<ad>-portal` adında sanal bir **outbound** olur. Routing'de bu
  outbound'a gönderilen trafik, o cihaza tünellenir.
- **Ev cihazı:** VLESS outbound'una `"reverse": {"tag": "bridge"}` eklenir. Bu bağlantı açık
  kaldıkça sunucudan gelen istekler `bridge` adında sanal bir **inbound** olarak görünür ve
  freedom ile ev internetine çıkar.

Yedek hat: sunucuda `selector: ["<ad>-portal"]`, `fallbackTag: "direct"` olan bir `leastPing`
balancer ve `burstObservatory` (10 sn'de bir `generate_204` denemesi) vardır. Tünel yoksa deneme
başarısız olur ve balancer `direct`'e düşer.

## Sunucu yapılandırması (el ile)

```json
{
  "inbounds": [
    {
      "tag": "home-exit-bridge", "port": 10086, "protocol": "vless",
      "settings": {
        "clients": [{ "id": "UUID", "email": "home-exit-bridge", "reverse": { "tag": "home-exit-portal" } }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": { "target": "www.apple.com:443", "serverNames": ["www.apple.com"],
                             "privateKey": "PRIVATE_KEY", "shortIds": ["SHORT_ID"] },
        "sockopt": { "tcpNoDelay": true, "tcpKeepAliveIdle": 30 }
      }
    },
    { "tag": "home-exit-socks", "listen": "127.0.0.1", "port": 1080, "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true } }
  ],
  "routing": {
    "balancers": [{ "tag": "home-exit-lb", "selector": ["home-exit-portal"],
                    "fallbackTag": "direct", "strategy": { "type": "leastPing" } }],
    "rules": [
      { "type": "field", "user": ["kullanici1"], "ip": ["::/0"], "outboundTag": "blocked" },
      { "type": "field", "user": ["kullanici1"], "balancerTag": "home-exit-lb" },
      { "type": "field", "inboundTag": ["home-exit-socks"], "ip": ["::/0"], "outboundTag": "blocked" },
      { "type": "field", "inboundTag": ["home-exit-socks"], "balancerTag": "home-exit-lb" }
    ]
  },
  "burstObservatory": {
    "subjectSelector": ["home-exit-portal"],
    "pingConfig": { "destination": "http://www.gstatic.com/generate_204", "interval": "10s",
                    "sampling": 2, "timeout": "4s" }
  }
}
```

x-ui / 3x-ui'de bu parçalar **Panel Ayarları → Xray Yapılandırması** şablonuna (`settings`
tablosundaki `xrayTemplateConfig`) eklenir; panel kullanıcıları (`inbounds` tablosu) değişmez.
Şablon değişikliği x-ui yeniden başlatılınca uygulanır. Betik bunu otomatik yapar: önce tam
yapılandırmayı `xray run -test` ile doğrular, veritabanını yedekler (`x-ui.db.bak-*`), x-ui
25 sn içinde açılmazsa yedeği geri yükler.

## Ev cihazı yapılandırması

```json
{
  "outbounds": [
    { "tag": "home-direct", "protocol": "freedom",
      "settings": { "finalRules": [
        { "action": "block", "ip": ["::/0", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8",
                                    "169.254.0.0/16", "100.64.0.0/10", "0.0.0.0/8", "224.0.0.0/3"], "blockDelay": "0" },
        { "action": "allow" } ] },
      "streamSettings": { "sockopt": { "domainStrategy": "UseIPv4", "tcpNoDelay": true, "tcpKeepAliveIdle": 30, "mark": 255 } } },
    { "tag": "to-server", "protocol": "vless",
      "settings": { "address": "SUNUCU_IP", "port": 10086, "id": "UUID", "encryption": "none",
                    "reverse": { "tag": "bridge" } },
      "streamSettings": { "network": "tcp", "security": "reality",
        "realitySettings": { "serverName": "www.apple.com", "fingerprint": "chrome",
                             "publicKey": "PUBLIC_KEY", "shortId": "SHORT_ID" },
        "sockopt": { "tcpNoDelay": true, "tcpKeepAliveIdle": 30, "mark": 255 } } },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["bridge"], "ip": ["::/0", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"], "outboundTag": "block" },
      { "type": "field", "inboundTag": ["bridge"], "outboundTag": "home-direct" }
    ]
  }
}
```

## Xray 26 tuzakları

1. **Freedom "blocked target":** Yeni Xray sürümlerinde freedom'ın varsayılan güvenlik politikası
   **VLESS reverse'ten gelen tüm hedefleri engeller**. Belirti:
   `proxy/freedom: blocked target: tcp:…, blackholing connection for 33s`.
   Çözüm `settings.finalRules` ile açık izin vermektir (yukarıdaki örnek: önce özel ağları engelle,
   sonra her şeye izin ver). Eski yöntem olan "aynı süreçte loopback SOCKS'tan geçirme" gerekmez.
   26.3'te bu politika henüz yoktu; `finalRules` orada da kabul edilir, iki sürümde de çalışır.
2. **Reverse hatta `xtls-rprx-vision` kullanmayın.** Vision iç TLS el sıkışmasını istemci → sunucu
   yönünde bekler; reverse tünelde ClientHello ters yönde aktığı için HTTPS siteler
   `curl: (35) SSL connect error` verir. Telefon → sunucu hattında vision kullanılabilir.
3. **REALITY hedefi her ağda çalışmaz.** Örneğin bazı sunuculardan `www.microsoft.com` hedefiyle
   el sıkışma tamamlanmaz (`REALITY: processed invalid connection … handshake did not complete`).
   Betik adayları (`www.apple.com`, `www.cloudflare.com`, …) gerçek bir yerel REALITY el
   sıkışmasıyla dener ve ilk çalışanı seçer.
4. **IPv6:** Ev hattında IPv6 varsa çözülen alan adları IPv6'ya gidip sızabilir/gecikebilir.
   Varsayılan olarak ev tarafında `sockopt.domainStrategy: "UseIPv4"`, iki tarafta da `::/0`
   engellenir. Sunucuda `--ipv6` verilirse sunucu `::/0` kuralını eklemez, köprü linkine
   `ipv6=1` koyar; ev tarafı da `UseIPv4v6` (önce IPv4, gerekirse IPv6) kullanır ve yalnızca yerel
   IPv6 aralıklarını (`::1`, `fc00::/7`, `fe80::/10`, `ff00::/8`) engeller.
5. **`tcpNoDelay`** küçük paketlerde (oyun, ping, WebSocket) 40–80 ms Nagle gecikmesini önler.
   Sunucuda `net.ipv4.tcp_congestion_control=bbr` + `net.core.default_qdisc=fq` önerilir.
6. **OpenWrt'de döngü:** Router'da şeffaf proxy (PassWall, OpenClash…) varsa freedom çıkışı yeniden
   proxy'ye girebilir. `sockopt.mark` ile işaretleyip şeffaf proxy kurallarında hariç tutun.

## Test

`tests/chroot-matrix.sh`, ev betiğini qemu-user ile OpenWrt/Debian/Alpine rootfs'leri içinde
çalıştırıp tünelden gerçekten trafik geçtiğini doğrular. Test sunucusu `--fallback block` ile
kurulmalıdır ki başarı yalnızca tünel çalışırken görülsün. Betik ana makinenin `/dev`'ini chroot'a
**bağlamaz** (kendi aygıt düğümlerini oluşturur) ve silmeden önce bağlı dosya sistemi kalmadığını
denetler.
