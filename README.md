# Bersih Storage

Pembersih storage Mac dengan satu tombol. Bersih Storage menghapus cache yang akan dibuat ulang sendiri, lalu menampilkan data besar lain yang bisa Anda bereskan dengan konfirmasi.

*A one-button storage cleaner for macOS. It removes caches that rebuild themselves, then lists larger items you can clean up after confirming. The interface is in Indonesian.*

Produk open source dari [InnovationKit](https://github.com/wiraperdana), dirilis dengan lisensi MIT.

## Fitur

- **Pembersihan cepat, satu tombol.** Cache browser, Zoom, Homebrew, npm, pip, uv, Go, node-gyp, unduhan update yang tertunda, dan versi lama Codex.
- **Aman untuk aplikasi yang sedang terbuka.** Cache milik aplikasi yang masih berjalan dilewati, jadi Anda tidak perlu restart Mac.
- **Opsi lanjutan dengan konfirmasi.** Media WhatsApp, VM Claude Desktop, file AutoRecovery Office, browser Playwright, Trash, Microsoft AutoUpdate yang sudah yatim, dan item terbesar di Downloads.
- **Menu bar.** Lihat ruang kosong dan bersihkan cache tanpa membuka jendela.
- **Berjalan saat Mac menyala.** Bisa dimatikan di Pengaturan.
- **Tercatat.** Setiap pembersihan ditulis ke `~/Library/Logs/BersihStorage.log`.

## Prinsip keamanan

1. Yang dihapus permanen hanya cache yang dibuat ulang sendiri, dan data yang memang bisa diunduh ulang.
2. File milik Anda, seperti isi Downloads dan AutoRecovery, dipindah ke Trash, jadi masih bisa dikembalikan.
3. Data aplikasi yang punya database sendiri, seperti WhatsApp, tidak pernah dihapus langsung. Bersih Storage hanya membuka aplikasinya.
4. Microsoft AutoUpdate hanya bisa dihapus kalau tidak ada lagi aplikasi Microsoft yang terpasang.

## Kebutuhan

- macOS 15 Sequoia atau lebih baru
- Apple Silicon atau Intel (build universal)
- Command Line Tools untuk Xcode, untuk build dari sumber: `xcode-select --install`

## Build dan pasang

```bash
git clone https://github.com/wiraperdana/bersih-storage.git
cd bersih-storage
./build.sh
```

Script ini mengompilasi aplikasi untuk Apple Silicon dan Intel, lalu memasangnya ke `~/Applications`. Pakai `./build.sh --no-install` untuk build saja.

Aplikasi hasil build ditandatangani secara lokal (ad-hoc), tanpa Developer ID Apple. Ia langsung bisa dipakai di Mac tempat Anda membangunnya. Kalau `.app`-nya disalin ke Mac lain, Gatekeeper akan memblokirnya saat pertama dibuka. Klik kanan, pilih Open, lalu konfirmasi.

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

## Lisensi

MIT. Lihat [LICENSE](LICENSE).
