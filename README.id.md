# Lega

Pembersih storage Mac dengan satu tombol. Lega menghapus cache yang akan dibuat ulang sendiri, lalu menampilkan data besar lain yang bisa Anda bereskan dengan konfirmasi.

*[English](README.md) · Bahasa Indonesia*

Produk open source dari [InnovationKit](https://wiraperdana.com), dirilis dengan lisensi MIT.

## Download

Unduh DMG dari [lega.wiraperdana.com](https://lega.wiraperdana.com/#download):

- [Lega untuk Apple Silicon](https://lega.wiraperdana.com/download/Lega-1.0.0-AppleSilicon.dmg) (M1 dan seterusnya)
- [Lega untuk Intel](https://lega.wiraperdana.com/download/Lega-1.0.0-Intel.dmg)

Buka DMG, lalu seret Lega ke Applications. Lega belum ditandatangani Developer ID Apple, jadi macOS menahannya saat pertama dibuka. Buka System Settings, Privacy & Security, lalu klik Open Anyway. Cukup sekali.

## Fitur

- **Satu Scan, satu Clean.** Scan mengukur cache, sisa aplikasi, Trash, file besar, dan data aplikasi. Hasilnya satu daftar kategori beserta ukurannya. Centang yang Anda mau, lalu tekan Clean sekali.
- **Risiko selalu terlihat.** Setiap kategori bertanda Aman, Periksa dulu, atau Lewat aplikasinya. Yang tercentang default hanya yang Aman dan sisa aplikasi.
- **Cache.** Cache browser (termasuk Service Worker Arc, Chrome, dan Comet), Zoom, Homebrew, npm, pip, uv, Go, node-gyp, cache compiler Clang dan Swift, unduhan update yang tertunda, dan versi lama Codex. Cache milik aplikasi yang sedang terbuka dilewati.
- **Sisa aplikasi.** Folder di atas 100 MB peninggalan aplikasi yang sudah Anda hapus, yang tidak dipakai aplikasi terpasang mana pun dan tidak berubah selama 14 hari. Tiap folder bisa dihilangkan centangnya atau dibuka di Finder dulu.
- **Uninstall bersih.** Uninstall aplikasi ikut membuang data, cache, dan pengaturannya di Library, dalam satu konfirmasi.
- **File besar.** Item terbesar di Downloads, sebagai daftar atau grid, untuk dicentang dan ikut dibersihkan.
- **Data aplikasi.** Media WhatsApp (dirapikan lewat WhatsApp), VM Claude Desktop, file AutoRecovery Office, browser Playwright, dan Microsoft AutoUpdate yang sudah yatim.
- **Peta ruang.** Folder terbesar di home Anda, termasuk data yang tidak pernah dihapus Lega sendiri.
- **Satu izin, sekali saja.** Layar sambutan meminta Full Disk Access sekali, menggantikan izin per folder.
- **Saran restart.** Muncul saat swap di disk melewati 2 GB atau Mac sudah menyala tiga hari.
- **English dan Bahasa Indonesia**, dengan mode terang, gelap, atau ikuti sistem.
- **Menu bar.** Lihat ruang kosong dan bersihkan cache tanpa membuka jendela.
- **Berjalan saat Mac menyala.** Bisa dimatikan di Pengaturan.
- **Tercatat.** Setiap pembersihan ditulis ke `~/Library/Logs/Lega.log`.

## Prinsip keamanan

1. Yang dihapus permanen hanya cache yang dibuat ulang sendiri, dan data yang memang bisa diunduh ulang.
2. File milik Anda, seperti isi Downloads dan AutoRecovery, dipindah ke Trash, jadi masih bisa dikembalikan.
3. Data aplikasi yang punya database sendiri, seperti WhatsApp, tidak pernah dihapus langsung. Lega hanya membuka aplikasinya.
4. Microsoft AutoUpdate hanya bisa dihapus kalau tidak ada lagi aplikasi Microsoft yang terpasang.

## Kebutuhan

- macOS 15 Sequoia atau lebih baru
- Apple Silicon atau Intel (build universal)
- Command Line Tools untuk Xcode, untuk build dari sumber: `xcode-select --install`

## Build dan pasang

```bash
git clone https://github.com/wiraperdana/lega.git
cd lega
./build.sh
```

Script ini mengompilasi aplikasi untuk Apple Silicon dan Intel, lalu memasangnya ke `~/Applications`. Pakai `./build.sh --no-install` untuk build saja.

Jalankan `Scripts/make-cert.sh` sekali sebelum build pertama. Script ini membuat sertifikat self-signed "Lega Developer" di login keychain, supaya setiap build punya identitas yang sama dan macOS cukup menanyakan izin sekali. Tanpa sertifikat itu, build ditandatangani ad-hoc dan izin ditanyakan ulang setiap build.

Aplikasi hasil build ditandatangani secara lokal (ad-hoc), tanpa Developer ID Apple. Ia langsung bisa dipakai di Mac tempat Anda membangunnya. Kalau `.app`-nya disalin ke Mac lain, Gatekeeper akan menahannya saat pertama dibuka. Buka System Settings, Privacy & Security, lalu klik Open Anyway.

Untuk membuat DMG Apple Silicon dan Intel, jalankan `./build.sh --no-install` lalu `Scripts/make-dmg.sh`. Hasilnya di `build/dmg/`.

## Izin yang akan diminta macOS

| Izin | Kapan | Untuk apa |
|---|---|---|
| Akses folder Downloads | Pemindaian pertama | Menampilkan item terbesar |
| Kontrol Finder (Automation) | Saat mengosongkan Trash | Finder yang mengosongkan Trash |
| Password admin | Saat menghapus Microsoft AutoUpdate | Berkasnya ada di folder sistem |
| Login item | Peluncuran pertama | Berjalan saat Mac menyala |

## Menambah target pembersihan

Daftar pembersihan cepat ada di array `quickTargets` di `Sources/main.swift`. Satu target berisi nama, path, ikon SF Symbol, dan nama aplikasi yang harus tertutup lebih dulu:

```swift
CacheTarget(id: "slack", name: "Cache Slack", note: "Dibuat ulang saat Slack dipakai",
            icon: "bubble.left", paths: ["~/Library/Caches/com.tinyspeck.slackmacgap"], blockers: ["Slack"]),
```

Hanya tambahkan folder yang benar-benar cache. Kalau ragu, jadikan opsi lanjutan dengan konfirmasi.

## Struktur

| Path | Isi |
|---|---|
| `Sources/main.swift` | Seluruh aplikasi SwiftUI |
| `Scripts/make-icon.swift` | Menggambar ikon jadi `Resources/AppIcon.icns` |
| `build.sh` | Build universal, tanda tangan ad-hoc, dan pemasangan |
| `Scripts/make-dmg.sh` | DMG terpisah untuk Apple Silicon dan Intel |
| `docs/` | Landing page lega.wiraperdana.com, disajikan GitHub Pages |

## Lisensi

MIT. Lihat [LICENSE](LICENSE).
