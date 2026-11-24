// Versi dan pengecekan pembaruan.
// Lega membaca https://lega.wiraperdana.com/version.json, berkas kecil yang terbit bersama landing page.
// Yang dikirim hanya permintaan HTTP biasa ke situs itu, tanpa data apa pun tentang Mac Anda.
// Lisensi MIT. Lihat LICENSE.

import SwiftUI
import AppKit

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

struct RemoteVersion: Decodable {
    let version: String
    let notes: String?
    let notesId: String?
    let appleSilicon: String
    let intel: String
    let page: String?
}

/// Membandingkan "1.10.0" dan "1.9.2" per angka, bukan per huruf.
func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}

@MainActor final class Updater: ObservableObject {
    static let shared = Updater()
    /// Alamat feed. `defaults write id.innovationkit.lega updateFeed <url>` menggantinya untuk pengujian.
    static var feed: URL {
        UserDefaults.standard.string(forKey: "updateFeed").flatMap(URL.init(string:)) ?? URL(string: "https://lega.wiraperdana.com/version.json")!
    }

    @Published var latest: RemoteVersion?
    @Published var checking = false
    @Published var status: String?

    var available: Bool { latest.map { isNewer($0.version, than: appVersion) } ?? false }

    /// Dipanggil saat Lega dibuka: cek sekali sehari bila pengguna tidak mematikannya.
    func autoCheck() {
        let d = UserDefaults.standard
        if d.object(forKey: "autoUpdateCheck") != nil && !d.bool(forKey: "autoUpdateCheck") { return }
        if let last = d.object(forKey: "lastUpdateCheck") as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        check(silent: true)
    }

    func check(silent: Bool = false) {
        guard !checking else { return }
        checking = true
        if !silent { status = nil }
        var req = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("Lega/\(appVersion)", forHTTPHeaderField: "User-Agent")
        Task {
            defer { checking = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let r = try JSONDecoder().decode(RemoteVersion.self, from: data)
                latest = r
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                status = isNewer(r.version, than: appVersion)
                    ? tr("Lega \(r.version) sudah tersedia.", "Lega \(r.version) is available.")
                    : tr("Lega sudah versi terbaru.", "Lega is up to date.")
            } catch {
                if !silent { status = tr("Gagal mengecek pembaruan. Periksa koneksi internet.", "Could not check for updates. Check your internet connection.") }
            }
        }
    }

    /// Unduh DMG yang cocok dengan chip Mac ini lewat browser.
    func download() {
        guard let r = latest else { return }
        #if arch(arm64)
        let link = r.appleSilicon
        #else
        let link = r.intel
        #endif
        if let u = URL(string: link) { NSWorkspace.shared.open(u) }
    }

    var notes: String? {
        guard let r = latest else { return nil }
        return tr(r.notesId ?? r.notes ?? "", r.notes ?? "").nilIfEmpty
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

/// Bagian Pembaruan di Settings.
struct UpdateSettings: View {
    @ObservedObject var u = Updater.shared
    @AppStorage("autoUpdateCheck") private var auto = true

    var body: some View {
        Section(tr("Pembaruan", "Updates")) {
            LabeledContent(tr("Versi", "Version"), value: "Lega \(appVersion)")
            Toggle(tr("Cek pembaruan otomatis setiap hari", "Check for updates automatically every day"), isOn: $auto)
            HStack {
                Button(tr("Cek sekarang", "Check now")) { u.check() }.disabled(u.checking)
                if u.checking { ProgressView().controlSize(.small) }
                if let s = u.status { Text(s).foregroundStyle(.secondary) }
                Spacer()
                if u.available { Button(tr("Download \(u.latest?.version ?? "")", "Download \(u.latest?.version ?? "")")) { u.download() }.buttonStyle(.borderedProminent).tint(accent) }
            }
            if u.available, let n = u.notes { Text(n).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Kartu kecil di Beranda saat ada versi baru.
struct UpdateBanner: View {
    @ObservedObject var u = Updater.shared

    var body: some View {
        if u.available, let r = u.latest {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Lega \(r.version) sudah tersedia", "Lega \(r.version) is available")).font(.headline)
                    Text(u.notes ?? tr("Anda memakai \(appVersion).", "You have \(appVersion)."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Download") { u.download() }.buttonStyle(.borderedProminent).tint(accent)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        }
    }
}
