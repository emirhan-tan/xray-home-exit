"""assets/platforms.svg üretir: python assets/make-platforms.py"""
from pathlib import Path

CARDS = [
    ("router", "OpenWrt", "24.10 · 25.12", ["aarch64", "armv7", "mips", "mipsel", "x86_64", "i386"], "procd · opkg / apk"),
    ("pi", "Raspberry Pi", "Pi OS · Debian 12", ["arm64", "armhf", "armv6"], "systemd · Pi Zero → Pi 5"),
    ("term", "Linux", "Debian · Ubuntu · Alpine", ["x86_64", "arm64", "riscv64"], "systemd · OpenRC"),
    ("win", "Windows", "10 · 11", ["x64", "ARM64", "x86"], "zamanlanmış görev · task"),
    ("server", "Sunucu · Server", "x-ui · 3x-ui · standalone", ["Ubuntu", "Debian"], "Xray-core 26.x"),
]
MINT, VIO, ORA = "#78ffb4", "#b69cff", "#ffb86b"

ICONS = {
    "router": f'<rect x="0" y="12" width="34" height="16" rx="4" fill="none" stroke="{MINT}" stroke-width="2"/>'
              f'<path d="M7 12 4 2M27 12 30 2" stroke="{MINT}" stroke-width="2" stroke-linecap="round"/>'
              f'<circle cx="8" cy="20" r="1.8" fill="{MINT}"/><circle cx="14" cy="20" r="1.8" fill="{MINT}"/>',
    "pi": "".join(f'<circle cx="{x}" cy="{y}" r="5.5" fill="none" stroke="#ff6b8b" stroke-width="2"/>'
                  for x, y in ((11, 12), (23, 12), (17, 21), (8, 23), (26, 23)))
          + '<path d="M13 5Q17 1 21 5" fill="none" stroke="#78ffb4" stroke-width="2" stroke-linecap="round"/>',
    "term": f'<rect x="0" y="2" width="34" height="26" rx="5" fill="none" stroke="#c3cad3" stroke-width="2"/>'
            f'<path d="M7 11l5 4-5 4M16 20h9" fill="none" stroke="{MINT}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
    "win": "".join(f'<rect x="{x}" y="{y}" width="14" height="12" rx="1.5" fill="#4fa3ff"/>'
                   for x, y in ((2, 3), (18, 3), (2, 17), (18, 17))),
    "server": f'<rect x="0" y="2" width="34" height="12" rx="3" fill="none" stroke="{VIO}" stroke-width="2"/>'
              f'<rect x="0" y="17" width="34" height="12" rx="3" fill="none" stroke="{VIO}" stroke-width="2"/>'
              f'<circle cx="27" cy="8" r="1.8" fill="{MINT}"/><circle cx="27" cy="23" r="1.8" fill="{VIO}"/>',
}

W, H, X0, GAP, CW = 1200, 330, 40, 16, 212
out = [f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <title>Desteklenen sistemler · Supported systems</title>
  <style>
    .mono{{font-family:ui-monospace,SFMono-Regular,'JetBrains Mono',Consolas,'Liberation Mono',Menlo,monospace}}
    .sans{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','Helvetica Neue',Arial,sans-serif}}
    @keyframes rise{{from{{opacity:0;transform:translateY(8px)}}to{{opacity:1;transform:none}}}}
    .c{{animation:rise .6s ease-out both}}
  </style>
  <rect x=".5" y=".5" width="{W-1}" height="{H-1}" rx="20" fill="#0d1116" stroke="#1f252d"/>
  <rect x="56" y="0" width="72" height="3" rx="1.5" fill="{MINT}"/>
  <text x="56" y="46" class="mono" font-size="11" letter-spacing="1.5" fill="#6b7684">DESTEKLENEN SİSTEMLER · SUPPORTED SYSTEMS</text>
  <rect x="1004" y="27" width="156" height="28" rx="14" fill="{MINT}" fill-opacity=".08" stroke="{MINT}" stroke-opacity=".5"/>
  <text x="1082" y="46" class="mono" font-size="12" text-anchor="middle" fill="{MINT}">13/13 test ✓</text>''']

for i, (icon, title, sub, chips, foot) in enumerate(CARDS):
    x, y = X0 + i * (CW + GAP), 72
    out.append(f'  <g class="c" style="animation-delay:{i * .08:.2f}s">')
    out.append(f'    <rect x="{x}" y="{y}" width="{CW}" height="226" rx="14" fill="#12161b" stroke="#2a323c" stroke-width="1.5"/>')
    out.append(f'    <g transform="translate({x + 20} {y + 20})">{ICONS[icon]}</g>')
    out.append(f'    <text x="{x + 20}" y="{y + 84}" class="sans" font-size="17" font-weight="600" fill="#e8ecf1">{title}</text>')
    out.append(f'    <text x="{x + 20}" y="{y + 105}" class="sans" font-size="12.5" fill="#8a94a3">{sub}</text>')
    cx, cy = x + 20, y + 124
    for c in chips:
        w = round(len(c) * 6.8 + 16)
        if cx + w > x + CW - 16:
            cx, cy = x + 20, cy + 30
        out.append(f'    <rect x="{cx}" y="{cy}" width="{w}" height="22" rx="11" fill="#0d1116" stroke="#2a323c"/>'
                   f'<text x="{cx + w / 2:.1f}" y="{cy + 15}" class="mono" font-size="11" text-anchor="middle" fill="#c3cad3">{c}</text>')
        cx += w + 6
    out.append(f'    <path d="M{x + 20} {y + 196}h{CW - 40}" stroke="#1f252d"/>')
    out.append(f'    <text x="{x + 20}" y="{y + 214}" class="sans" font-size="11.5" fill="#6b7684">{foot}</text>')
    out.append('  </g>')
out.append('</svg>\n')
Path(__file__).with_name("platforms.svg").write_text("\n".join(out), encoding="utf-8")
print("platforms.svg yazıldı")
