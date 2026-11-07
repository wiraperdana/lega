// Lega: pembersih storage Mac satu tombol.
// Pembersihan cepat hanya menyentuh cache yang akan dibuat ulang sendiri.
// Opsi lanjutan menyentuh data yang lebih besar, dan selalu meminta konfirmasi.
// Lisensi MIT. Lihat LICENSE.

import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Data

struct CacheTarget: Identifiable {
    let id: String
    let name: String
    let note: String
    let icon: String
    let paths: [String]
    var blockers: [String] = []      // nama aplikasi yang harus tertutup dulu
    var codexReleases = false        // target khusus: versi lama Codex
    var app: String? = nil           // nama aplikasi untuk ikon aslinya
}

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let modified: Date
}

struct Pending {
    let title: String
    let message: String
    let confirm: String
    let action: () -> Void
}

let quickTargets: [CacheTarget] = [
    CacheTarget(id: "codex", name: "Versi lama Codex", note: "Versi aktif dan dua terbaru disimpan", icon: "shippingbox", paths: [], codexReleases: true, app: "Codex"),
    CacheTarget(id: "arc", name: "Cache Arc", note: "Dibuat ulang saat browsing", icon: "globe", paths: ["~/Library/Caches/Arc"], blockers: ["Arc"], app: "Arc"),
    CacheTarget(id: "comet", name: "Cache Comet", note: "Dibuat ulang saat browsing", icon: "globe", paths: ["~/Library/Caches/Comet"], blockers: ["Comet"], app: "Comet"),
    CacheTarget(id: "chrome", name: "Cache Google Chrome", note: "Dibuat ulang saat browsing", icon: "globe", paths: ["~/Library/Caches/Google/Chrome"], blockers: ["Google Chrome"], app: "Google Chrome"),
    CacheTarget(id: "zoom", name: "Cache Zoom", note: "Dibuat ulang saat Zoom dipakai", icon: "video", paths: ["~/Library/Caches/us.zoom.xos"], blockers: ["zoom.us"], app: "zoom.us"),
    CacheTarget(id: "zcode", name: "Unduhan update zcode", note: "Diunduh ulang saat update berikutnya", icon: "arrow.down.circle", paths: ["~/Library/Caches/@zcodedesktop-updater"]),
    CacheTarget(id: "brew", name: "Cache Homebrew", note: "Unduhan paket lama", icon: "mug", paths: ["~/Library/Caches/Homebrew"]),
    CacheTarget(id: "npm", name: "Cache npm", note: "Unduhan paket Node.js", icon: "cube", paths: ["~/.npm/_cacache"]),
    CacheTarget(id: "pip", name: "Cache pip dan uv", note: "Unduhan paket Python", icon: "cube", paths: ["~/Library/Caches/pip", "~/.cache/uv"]),
    CacheTarget(id: "build", name: "Cache build Go dan node-gyp", note: "Hasil kompilasi sementara", icon: "hammer", paths: ["~/Library/Caches/go-build", "~/Library/Caches/node-gyp"]),
]

// MARK: - Engine (berjalan di luar main thread)

enum Engine {
    static let fm = FileManager.default

    static func url(_ s: String) -> URL { URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }

    static func size(_ u: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return 0 }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if !isDir.boolValue {
            return Int64((try? u.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: u, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
            for case let f as URL in e {
                if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                    total += Int64(v.totalFileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    static func disk() -> (free: Int64, total: Int64) {
        let v = try? url("~").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeTotalCapacity ?? 0))
    }

    static func runningAppNames() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName })
    }

    static func shell(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Versi Codex yang boleh dihapus: bukan `current`, bukan dua terbaru, dan tidak sedang dipakai proses.
    static func codexOldReleases() -> [URL] {
        let running = shell("/bin/ps", ["-axo", "command"]).out
        var out: [URL] = []
        for pkg in ["standalone", "app-server-daemon"] {
            let root = url("~/.codex/packages/\(pkg)")
            let rel = root.appendingPathComponent("releases")
            guard let names = try? fm.contentsOfDirectory(atPath: rel.path) else { continue }
            let current = (try? fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent("current").path))
                .map { ($0 as NSString).lastPathComponent }
            let sorted = names.filter { !$0.hasPrefix(".") }
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            let keep = Set(sorted.suffix(2)).union(current.map { [$0] } ?? [])
            for n in sorted where !keep.contains(n) {
                let dir = rel.appendingPathComponent(n)
                if running.contains(dir.path + "/") { continue }
                out.append(dir)
            }
        }
        return out
    }

    static func urls(for t: CacheTarget) -> [URL] {
        t.codexReleases ? codexOldReleases() : t.paths.map(url).filter { fm.fileExists(atPath: $0.path) }
    }

    static func size(of t: CacheTarget) -> Int64 { urls(for: t).reduce(0) { $0 + size($1) } }

    /// Menghapus permanen. Mengembalikan jumlah byte yang dibebaskan.
    static func clean(_ t: CacheTarget) -> (freed: Int64, error: String?) {
        var freed: Int64 = 0
        var err: String?
        for u in urls(for: t) {
            let s = size(u)
            do { try fm.removeItem(at: u); freed += s } catch { err = error.localizedDescription }
        }
        return (freed, err)
    }

    static let officeApps = ["Powerpoint": "Microsoft PowerPoint", "Word": "Microsoft Word", "Excel": "Microsoft Excel"]

    static func autoRecoverFiles() -> [URL] {
        officeApps.keys.flatMap { app -> [URL] in
            let dir = url("~/Library/Containers/com.microsoft.\(app)/Data/Library/Preferences/AutoRecovery")
            return (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        }
    }

    // Microsoft AutoUpdate (MAU)

    static let mauDir = "/Library/Application Support/Microsoft/MAU2.0"
    static let microsoftApps = ["Microsoft Word", "Microsoft Excel", "Microsoft PowerPoint", "Microsoft Outlook",
                                "Microsoft OneNote", "OneDrive", "Microsoft Teams", "Microsoft Defender"]

    static func mauInstalled() -> Bool { fm.fileExists(atPath: mauDir) }

    /// Aplikasi Microsoft yang masih bergantung pada MAU untuk update.
    static func microsoftAppsInstalled() -> [String] {
        microsoftApps.filter { fm.fileExists(atPath: "/Applications/\($0).app") }
    }

    /// Menghapus MAU beserta cache dan helper-nya. Meminta password admin lewat dialog macOS.
    static func removeMAU() -> String {
        let uid = getuid()
        _ = shell("/bin/launchctl", ["bootout", "gui/\(uid)/com.microsoft.update.agent"])
        let root = [
            "launchctl bootout system /Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist",
            "launchctl bootout system /Library/LaunchDaemons/com.microsoft.office.licensingV2.helper.plist",
            "rm -rf '\(mauDir)' /Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist "
                + "/Library/LaunchDaemons/com.microsoft.office.licensingV2.helper.plist "
                + "/Library/LaunchAgents/com.microsoft.update.agent.plist "
                + "/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper "
                + "/Library/PrivilegedHelperTools/com.microsoft.office.licensingV2.helper "
                + "/Library/Caches/com.microsoft.autoupdate.helper /Library/Caches/com.microsoft.autoupdate.fba "
                + "'/Applications/Microsoft Defender Shim.app'",
            "rmdir '/Library/Application Support/Microsoft'",
        ].map { $0 + " 2>/dev/null" }.joined(separator: "; ") + "; true"
        let script = "do shell script \"\(root)\" with prompt \"Lega ingin menghapus Microsoft AutoUpdate.\" with administrator privileges"
        let r = shell("/usr/bin/osascript", ["-e", script])
        for p in ["~/Library/Preferences/com.microsoft.autoupdate2.plist", "~/Library/Caches/com.microsoft.autoupdate2",
                  "~/Library/Application Support/Microsoft AU Daemon"] {
            try? fm.removeItem(at: url(p))
        }
        if r.code != 0 { return r.out.contains("-128") ? "Dibatalkan." : "Gagal: \(r.out)" }
        return mauInstalled() ? "Sebagian file MAU masih tersisa." : "Microsoft AutoUpdate sudah dihapus."
    }

    static func downloadsTop(_ n: Int) -> [FileItem] {
        let dir = url("~/Downloads")
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return items.map { u in
            FileItem(url: u, size: size(u),
                     modified: (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        .sorted { $0.size > $1.size }
        .prefix(n).map { $0 }
    }

    static func log(_ line: String) {
        let f = url("~/Library/Logs/Lega.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: f)
        }
    }
}

func fmt(_ b: Int64) -> String {
    b <= 0 ? "0 MB" : ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

let accent = Color(red: 0.05, green: 0.56, blue: 0.50)

/// "sistem" mengikuti macOS, "terang" dan "gelap" memaksa salah satunya.
func scheme(_ appearance: String) -> ColorScheme? {
    switch appearance { case "terang": .light; case "gelap": .dark; default: nil }
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var free: Int64 = 0
    @Published var total: Int64 = 0
    @Published var sizes: [String: Int64] = [:]
    @Published var statuses: [String: String] = [:]
    @Published var adv: [String: Int64] = [:]
    @Published var downloads: [FileItem] = []
    @Published var mauInstalled = false
    @Published var msApps: [String] = []
    @Published var scanning = false      // pemindaian cepat (cache)
    @Published var scanningAdv = false   // pemindaian lanjutan (WhatsApp, Downloads)
    @Published var busy = false
    @Published var result: String?
    @Published var pending: Pending?

    var quickTotal: Int64 { sizes.values.reduce(0, +) }
    var usedFraction: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
    var isLow: Bool { total > 0 && free < 10_000_000_000 }

    init() {
        refresh()
        // Pindai ulang tiap 30 menit supaya angka di menu bar tetap segar
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !scanning, !scanningAdv else { return }
        scanning = true
        scanningAdv = true
        Task.detached {
            var s: [String: Int64] = [:]
            for t in quickTargets { s[t.id] = Engine.size(of: t) }
            let (f, tot) = Engine.disk()
            let sizes = s
            await MainActor.run { self.sizes = sizes; self.free = f; self.total = tot; self.scanning = false }

            // Yang cepat lebih dulu, WhatsApp paling akhir karena isinya puluhan GB
            let mau = Engine.mauInstalled()
            let ms = Engine.microsoftAppsInstalled()
            await MainActor.run { self.mauInstalled = mau; self.msApps = ms }
            for (key, path) in [("claudevm", "~/Library/Application Support/Claude/vm_bundles"),
                                ("playwright", "~/Library/Caches/ms-playwright")] {
                let v = Engine.size(Engine.url(path))
                await MainActor.run { self.adv[key] = v }
            }
            let ar = Engine.autoRecoverFiles().reduce(0) { $0 + Engine.size($1) }
            await MainActor.run { self.adv["autorecover"] = ar }
            let dl = Engine.downloadsTop(12)
            await MainActor.run { self.downloads = dl }
            let wa = Engine.size(Engine.url("~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"))
            await MainActor.run { self.adv["whatsapp"] = wa; self.scanningAdv = false }
        }
    }

    func cleanQuick() {
        busy = true
        result = nil
        let running = Engine.runningAppNames()
        Task.detached {
            var st: [String: String] = [:]
            var freed: Int64 = 0
            for t in quickTargets {
                if let b = t.blockers.first(where: running.contains) {
                    st[t.id] = "Dilewati, \(b) sedang terbuka"
                    continue
                }
                let r = Engine.clean(t)
                freed += r.freed
                if let e = r.error { st[t.id] = "Sebagian gagal: \(e)" }
            }
            Engine.log("cepat: dibebaskan \(fmt(freed))")
            let statuses = st, total = freed
            await MainActor.run {
                self.statuses = statuses
                self.result = total > 0 ? "\(fmt(total)) dibebaskan." : "Tidak ada yang perlu dibersihkan."
                self.busy = false
                self.refresh()
            }
        }
    }

    // Opsi lanjutan

    func ask(_ title: String, _ message: String, confirm: String = "Hapus", _ action: @escaping () -> Void) {
        pending = Pending(title: title, message: message, confirm: confirm, action: action)
    }

    func blocked(by apps: [String]) -> String? {
        let running = Engine.runningAppNames()
        return apps.first(where: running.contains)
    }

    func runAdvanced(_ label: String, _ work: @escaping @Sendable () -> String) {
        busy = true
        Task.detached {
            let msg = work()
            Engine.log("lanjutan: \(label): \(msg)")
            await MainActor.run { self.result = msg; self.busy = false; self.refresh() }
        }
    }

    func removeFolder(_ label: String, _ path: String, blockers: [String] = [], title: String, message: String) {
        if let b = blocked(by: blockers) { result = "Tutup \(b) dulu."; return }
        ask(title, message) { [self] in
            runAdvanced(label) {
                let u = Engine.url(path)
                let s = Engine.size(u)
                do { try FileManager.default.removeItem(at: u); return "\(fmt(s)) dibebaskan." }
                catch { return "Gagal: \(error.localizedDescription)" }
            }
        }
    }

    func cleanAutoRecover() {
        if let b = blocked(by: Array(Engine.officeApps.values)) { result = "Tutup \(b) dulu."; return }
        ask("Pindahkan file AutoRecovery ke Trash?",
            "Ini salinan darurat Word, Excel, dan PowerPoint. Pastikan dokumen aslinya sudah tersimpan. File masih bisa dikembalikan dari Trash.",
            confirm: "Ke Trash") { [self] in
            runAdvanced("autorecover") {
                var n = 0
                for f in Engine.autoRecoverFiles() where (try? FileManager.default.trashItem(at: f, resultingItemURL: nil)) != nil { n += 1 }
                return "\(n) file AutoRecovery dipindah ke Trash."
            }
        }
    }

    func removeMAU() {
        ask("Hapus Microsoft AutoUpdate?",
            "Tidak ada aplikasi Microsoft yang terdeteksi, jadi updater ini tidak lagi punya tugas. macOS akan meminta password admin.") { [self] in
            runAdvanced("mau") { Engine.removeMAU() }
        }
    }

    func trashDownload(_ item: FileItem) {
        ask("Pindahkan ke Trash?", "\(item.url.lastPathComponent) (\(fmt(item.size))). Masih bisa dikembalikan dari Trash.", confirm: "Ke Trash") { [self] in
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                Engine.log("lanjutan: trash \(item.url.path)")
                downloads.removeAll { $0.id == item.id }
                result = "\(item.url.lastPathComponent) dipindah ke Trash. Kosongkan Trash supaya ruangnya kembali."
            } catch { result = "Gagal: \(error.localizedDescription)" }
        }
    }

    func emptyTrash() {
        ask("Kosongkan Trash?", "Semua isi Trash dihapus permanen.", confirm: "Kosongkan") { [self] in
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&err)
            result = err == nil ? "Trash dikosongkan." : "Gagal. Izinkan Lega mengontrol Finder di System Settings, Privacy & Security, Automation."
            Engine.log("lanjutan: kosongkan trash")
            refresh()
        }
    }
}

// Item opsi lanjutan, dipakai bersama oleh kedua tampilan
struct AdvItem: Identifiable {
    let id: String
    let symbol: String
    let initials: String
    let title: String
    let size: Int64?
    let note: String
    let short: String
    let button: String
    var enabled = true
    var prominent = false
    let action: () -> Void
}

extension Model {
    var visibleQuick: [CacheTarget] {
        quickTargets.filter { (sizes[$0.id] ?? 0) > 0 || statuses[$0.id] != nil }
    }

    var advItems: [AdvItem] {
        var a: [AdvItem] = []
        if (adv["whatsapp"] ?? 0) > 0 {
            a.append(AdvItem(id: "whatsapp", symbol: "message", initials: "WA", title: "Media WhatsApp", size: adv["whatsapp"],
                             note: "Rapikan lewat Settings, Storage di WhatsApp. Jangan hapus filenya langsung.",
                             short: "Dirapikan lewat aplikasinya", button: "Buka aplikasi", prominent: true) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/WhatsApp.app"))
            })
        }
        if (adv["claudevm"] ?? 0) > 0 {
            a.append(AdvItem(id: "claudevm", symbol: "cpu", initials: "VM", title: "VM Claude Desktop", size: adv["claudevm"],
                             note: "Diunduh ulang kalau fitur agent dipakai lagi. Claude harus tertutup.",
                             short: "Diunduh ulang saat dipakai", button: "Hapus") { [self] in
                removeFolder("claudevm", "~/Library/Application Support/Claude/vm_bundles", blockers: ["Claude"],
                             title: "Hapus VM Claude Desktop?",
                             message: "Claude Desktop akan mengunduhnya ulang kalau fitur agent dipakai lagi. Penghapusan ini permanen.")
            })
        }
        if mauInstalled {
            a.append(AdvItem(id: "mau", symbol: "arrow.triangle.2.circlepath", initials: "MS", title: "Microsoft AutoUpdate", size: nil,
                             note: msApps.isEmpty ? "Tidak ada aplikasi Microsoft lagi. Updater ini aman dihapus."
                                                  : "Masih dipakai \(msApps.joined(separator: ", ")).",
                             short: msApps.isEmpty ? "Tak ada aplikasi Microsoft" : "Masih dipakai aplikasi Microsoft",
                             button: "Hapus", enabled: msApps.isEmpty) { [self] in removeMAU() })
        }
        if (adv["autorecover"] ?? 0) > 0 {
            a.append(AdvItem(id: "autorecover", symbol: "doc.badge.clock", initials: "AR", title: "AutoRecovery Office", size: adv["autorecover"],
                             note: "Salinan darurat Word, Excel, PowerPoint yang tertinggal.",
                             short: "Salinan darurat tertinggal", button: "Ke Trash") { [self] in cleanAutoRecover() })
        }
        if (adv["playwright"] ?? 0) > 0 {
            a.append(AdvItem(id: "playwright", symbol: "theatermasks", initials: "PW", title: "Browser Playwright", size: adv["playwright"],
                             note: "Browser uji otomatis. Diunduh ulang saat dibutuhkan.",
                             short: "Browser uji otomatis", button: "Hapus") { [self] in
                removeFolder("playwright", "~/Library/Caches/ms-playwright",
                             title: "Hapus browser Playwright?",
                             message: "Akan diunduh ulang saat playwright install dijalankan. Penghapusan ini permanen.")
            })
        }
        a.append(AdvItem(id: "trash", symbol: "trash", initials: "TR", title: "Trash", size: nil,
                         note: "File di Trash baru membebaskan ruang setelah dikosongkan.",
                         short: "Kosongkan lewat Finder", button: "Kosongkan") { [self] in emptyTrash() })
        return a
    }
}

// MARK: - Komponen

struct Ring: View {
    let fraction: Double
    let low: Bool
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(low ? Color.red : accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: fraction)
        }
    }
}

struct IconTile: View {
    let symbol: String
    var tint: Color = accent
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.title3.weight(.semibold)).padding(.top, 8)
    }
}

/// Ikon asli aplikasinya bila terpasang, selain itu simbol bawaan.
struct TargetIcon: View {
    let target: CacheTarget
    var body: some View {
        if let path = appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 28, height: 28)
        } else {
            IconTile(symbol: target.icon)
        }
    }
    var appPath: String? {
        guard let a = target.app else { return nil }
        return ["/Applications/\(a).app", Engine.url("~/Applications/\(a).app").path]
            .first { FileManager.default.fileExists(atPath: $0) }
    }
}

/// Lingkaran berisi dua huruf, seperti di landing page.
struct Avatar: View {
    let initials: String
    var body: some View {
        let hue = Double(initials.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) } % 360) / 360
        Text(initials)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(hue: hue, saturation: 0.45, brightness: 0.45))
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color(hue: hue, saturation: 0.18, brightness: 0.95)))
            .overlay(Circle().stroke(.quaternary))
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        PillLabel(label: configuration.label, prominent: prominent, pressed: configuration.isPressed)
    }
}

struct PillLabel<L: View>: View {
    let label: L
    let prominent: Bool
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(prominent ? Color.primary : Color.secondary.opacity(0.6)).frame(width: 6, height: 6)
            label
        }
        .font(.callout.weight(prominent ? .medium : .regular))
        .foregroundStyle(enabled ? Color.primary : Color.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Capsule().fill(prominent ? Color.primary.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().stroke(Color.primary.opacity(hover && enabled ? 0.3 : 0.12)))
        .scaleEffect(pressed ? 0.97 : 1)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

// MARK: - Jendela utama

struct MainView: View {
    @EnvironmentObject var m: Model
    @AppStorage("viewMode") private var viewMode = "sidebar"
    @AppStorage("appearance") private var appearance = "sistem"

    var body: some View {
        Group {
            if viewMode == "sidebar" { SidebarLayout() } else { classic }
        }
        .toolbar {
            ToolbarItem {
                Picker("Tampilan", selection: $viewMode) {
                    Image(systemName: "sidebar.left").tag("sidebar").help("Tampilan sidebar")
                    Image(systemName: "rectangle.grid.1x2").tag("halaman").help("Tampilan satu halaman")
                }
                .pickerStyle(.segmented)
                .help("Pilih tampilan")
            }
            ToolbarItem {
                Menu {
                    Picker("Mode", selection: $appearance) {
                        Label("Ikuti sistem", systemImage: "circle.lefthalf.filled").tag("sistem")
                        Label("Terang", systemImage: "sun.max").tag("terang")
                        Label("Gelap", systemImage: "moon").tag("gelap")
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: appearance == "terang" ? "sun.max" : appearance == "gelap" ? "moon" : "circle.lefthalf.filled")
                }
                .help("Mode terang atau gelap")
            }
            ToolbarItem {
                Button { m.refresh() } label: { Label("Pindai ulang", systemImage: "arrow.clockwise") }
                    .disabled(m.scanning || m.scanningAdv || m.busy)
                    .help("Pindai ulang")
            }
        }
        .alert(m.pending?.title ?? "",
               isPresented: Binding(get: { m.pending != nil }, set: { if !$0 { m.pending = nil } }),
               presenting: m.pending) { p in
            Button(p.confirm, role: .destructive) { p.action() }
            Button("Batal", role: .cancel) {}
        } message: { p in Text(p.message) }
    }

    var classic: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                if let r = m.result { resultBanner(r) }
                quickSection
                advancedSection
                downloadsSection
            }
            .padding(28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var hero: some View {
        HStack(spacing: 28) {
            ZStack {
                Ring(fraction: m.usedFraction, low: m.isLow, lineWidth: 14)
                VStack(spacing: 0) {
                    Text("\(Int((m.usedFraction * 100).rounded()))%")
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("terpakai").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 132, height: 132)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fmt(m.free))
                        .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(m.isLow ? .red : .primary)
                        .contentTransition(.numericText())
                    Text(m.isLow ? "Kosong. Di bawah 10 GB, Mac bisa melambat." : "Kosong dari \(fmt(m.total))")
                        .foregroundStyle(.secondary)
                }
                Button { m.cleanQuick() } label: {
                    HStack(spacing: 8) {
                        if m.busy { ProgressView().controlSize(.small).tint(.white) }
                        else { Image(systemName: "sparkles") }
                        Text(m.busy ? "Membersihkan" : "Bersihkan \(fmt(m.quickTotal))")
                    }
                    .font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .clipShape(Capsule())
                .disabled(m.busy || m.scanning || m.quickTotal == 0)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    func resultBanner(_ r: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
            Text(r)
            Spacer()
            Button { m.result = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    var quickSection: some View {
        let visible = m.visibleQuick
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Pembersihan cepat")
            Text("Cache yang dibuat ulang sendiri. Cache aplikasi yang sedang terbuka dilewati.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                if visible.isEmpty {
                    HStack(spacing: 10) {
                        IconTile(symbol: "checkmark")
                        Text(m.scanning ? "Memindai cache" : "Semua cache sudah bersih.")
                        Spacer()
                    }
                    .padding(14)
                }
                ForEach(Array(visible.enumerated()), id: \.element.id) { i, t in
                    if i > 0 { Divider().padding(.leading, 52) }
                    HStack(spacing: 12) {
                        TargetIcon(target: t)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name)
                            Text(m.statuses[t.id] ?? t.note).font(.caption)
                                .foregroundStyle(m.statuses[t.id] == nil ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        Text(fmt(m.sizes[t.id] ?? 0)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Opsi lanjutan")
            Text("Data yang lebih besar. Setiap tindakan meminta konfirmasi dulu.")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(m.advItems) { it in
                    card(it.symbol, it.title, it.size, it.note, it.button, enabled: it.enabled, action: it.action)
                }
                if m.scanningAdv {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Memindai WhatsApp").foregroundStyle(.secondary) }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 168)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .disabled(m.busy)
    }

    func card(_ symbol: String, _ title: String, _ size: Int64?, _ note: String, _ button: String,
              enabled: Bool = true, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconTile(symbol: symbol)
                Spacer()
                if let s = size {
                    Text(fmt(s)).font(.title3.weight(.semibold)).monospacedDigit()
                }
            }
            Text(title).font(.headline)
            Text(note).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(button, action: action).controlSize(.regular).disabled(!enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Item terbesar di Downloads")
            VStack(spacing: 0) {
                if m.downloads.isEmpty {
                    Text(m.scanningAdv && m.downloads.isEmpty ? "Memindai Downloads" : "Kosong, atau Lega belum diizinkan membaca Downloads.")
                        .font(.callout).foregroundStyle(.secondary).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(m.downloads.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { Divider().padding(.leading, 52) }
                    DownloadRow(item: f)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
        .disabled(m.busy)
    }
}

struct DownloadRow: View {
    @EnvironmentObject var m: Model
    let item: FileItem
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(item.modified.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if hover {
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                    .help("Tampilkan di Finder")
                Button { m.trashDownload(item) } label: { Image(systemName: "trash") }
                    .help("Pindahkan ke Trash")
            }
            Text(fmt(item.size)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 70, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Tampilan sidebar

enum Pane: Hashable { case cepat, lanjutan, downloads, log }

struct SidebarLayout: View {
    @EnvironmentObject var m: Model
    @State private var pane: Pane? = .cepat

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Text("Cepat").badge(m.visibleQuick.count).tag(Pane.cepat)
                Text("Lanjutan").badge(m.advItems.count).tag(Pane.lanjutan)
                Text("Downloads").badge(m.downloads.count).tag(Pane.downloads)
                Text("Log").tag(Pane.log)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            Group {
                switch pane ?? .cepat {
                case .cepat: QuickPane()
                case .lanjutan: AdvancedPane()
                case .downloads: DownloadsPane()
                case .log: LogPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle(title)
    }

    var title: String {
        switch pane ?? .cepat {
        case .cepat: "Pembersihan cepat"
        case .lanjutan: "Opsi lanjutan"
        case .downloads: "Downloads"
        case .log: "Log"
        }
    }
}

/// Status pemindaian berbentuk kapsul, misalnya "Memindai".
struct ScanChip: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(text).font(.callout)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
    }
}

struct ResultChip: View {
    @EnvironmentObject var m: Model
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
            Text(text)
            Spacer()
            Button { m.result = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct QuickPane: View {
    @EnvironmentObject var m: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 20) {
                    ZStack {
                        Ring(fraction: m.usedFraction, low: m.isLow, lineWidth: 8)
                        Text("\(Int((m.usedFraction * 100).rounded()))%")
                            .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 68, height: 68)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fmt(m.free))
                            .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(m.isLow ? .red : .primary)
                            .contentTransition(.numericText())
                        Text(m.isLow ? "Kosong. Di bawah 10 GB, Mac bisa melambat." : "kosong dari \(fmt(m.total))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { m.cleanQuick() } label: {
                        HStack(spacing: 8) {
                            if m.busy { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "sparkles") }
                            Text(m.busy ? "Membersihkan" : "Bersihkan \(fmt(m.quickTotal))")
                        }
                        .font(.headline)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).tint(accent).clipShape(Capsule())
                    .disabled(m.busy || m.scanning || m.quickTotal == 0)
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08)))

                if let r = m.result { ResultChip(text: r) }
                if m.scanning { ScanChip(text: "Memindai cache") }

                VStack(spacing: 0) {
                    if m.visibleQuick.isEmpty && !m.scanning {
                        Text("Semua cache sudah bersih.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    ForEach(Array(m.visibleQuick.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { Divider() }
                        HStack(spacing: 14) {
                            TargetIcon(target: t)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.body.weight(.medium))
                                Text(m.statuses[t.id] ?? t.note).font(.callout)
                                    .foregroundStyle(m.statuses[t.id] == nil ? Color.secondary : Color.orange)
                            }
                            Spacer()
                            Text(fmt(m.sizes[t.id] ?? 0)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
                Text("Cache yang dibuat ulang sendiri. Cache aplikasi yang sedang terbuka dilewati.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}

struct AdvancedPane: View {
    @EnvironmentObject var m: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let r = m.result { ResultChip(text: r) }
                if m.scanningAdv { ScanChip(text: "Memindai data besar") }
                VStack(spacing: 0) {
                    ForEach(Array(m.advItems.enumerated()), id: \.element.id) { i, it in
                        if i > 0 { Divider() }
                        HStack(spacing: 14) {
                            Avatar(initials: it.initials)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.title).font(.body.weight(.medium))
                                Text(it.short).font(.callout).foregroundStyle(.secondary)
                            }
                            .help(it.note)
                            Spacer()
                            if let s = it.size { Text(fmt(s)).monospacedDigit().foregroundStyle(.secondary) }
                            Button(it.button, action: it.action)
                                .buttonStyle(PillButtonStyle(prominent: it.prominent))
                                .disabled(!it.enabled || m.busy)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
                Text("Setiap tindakan meminta konfirmasi dulu.").font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}

struct DownloadsPane: View {
    @EnvironmentObject var m: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let r = m.result { ResultChip(text: r) }
                if m.scanningAdv && m.downloads.isEmpty { ScanChip(text: "Memindai Downloads") }
                if m.downloads.isEmpty && !m.scanningAdv {
                    Text("Kosong, atau Lega belum diizinkan membaca Downloads.").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(m.downloads) { FileTile(item: $0) }
                }
            }
            .padding(24)
        }
    }
}

struct FileTile: View {
    @EnvironmentObject var m: Model
    let item: FileItem
    @State private var hover = false

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable().frame(width: 36, height: 36)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
            VStack(spacing: 2) {
                Text(item.url.lastPathComponent).font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(fmt(item.size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(hover ? 0.2 : 0.08)))
        .overlay(alignment: .topTrailing) {
            if hover {
                HStack(spacing: 2) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                        .help("Tampilkan di Finder")
                    Button { m.trashDownload(item) } label: { Image(systemName: "trash") }
                        .help("Pindahkan ke Trash")
                }
                .buttonStyle(.borderless).padding(6)
            }
        }
        .offset(y: hover ? -2 : 0)
        .animation(.easeOut(duration: 0.15), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Tampilkan di Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Pindahkan ke Trash") { m.trashDownload(item) }
        }
        .help(item.url.lastPathComponent)
        .disabled(m.busy)
    }
}

struct LogPane: View {
    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if lines.isEmpty { Text("Belum ada catatan pembersihan.").foregroundStyle(.secondary) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .onAppear(perform: load)
    }

    func load() {
        let text = (try? String(contentsOf: Engine.url("~/Library/Logs/Lega.log"), encoding: .utf8)) ?? ""
        lines = Array(text.split(separator: "\n").suffix(200).reversed().map(String.init))
    }
}

// MARK: - Menu bar

struct MenuBarPanel: View {
    @EnvironmentObject var m: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Ring(fraction: m.usedFraction, low: m.isLow, lineWidth: 6).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 0) {
                    Text(fmt(m.free)).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(m.isLow ? .red : .primary)
                    Text("kosong dari \(fmt(m.total))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button { m.cleanQuick() } label: {
                HStack {
                    if m.busy { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                    Text(m.busy ? "Membersihkan" : "Bersihkan \(fmt(m.quickTotal))")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
            .disabled(m.busy || m.scanning || m.quickTotal == 0)
            if let r = m.result { Text(r).font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("Opsi lanjutan") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.help("Pengaturan")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Keluar")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 280)
    }
}

// MARK: - Pengaturan

struct SettingsView: View {
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("viewMode") private var viewMode = "sidebar"
    @AppStorage("appearance") private var appearance = "sistem"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker("Tampilan", selection: $viewMode) {
                Text("Sidebar").tag("sidebar")
                Text("Satu halaman").tag("halaman")
            }
            Picker("Mode", selection: $appearance) {
                Text("Ikuti sistem").tag("sistem")
                Text("Terang").tag("terang")
                Text("Gelap").tag("gelap")
            }
            Toggle("Buka saat Mac menyala", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in setLogin(on) }
            Toggle("Tampilkan di menu bar", isOn: $showMenuBar)
            if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
            Text("Kalau keduanya aktif, Lega berjalan diam-diam di menu bar setiap Mac menyala.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .preferredColorScheme(scheme(appearance))
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Gagal mengubah login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - App

/// Menjaga aplikasi tetap hidup di menu bar setelah jendela ditutup.
/// Ikon Dock hanya tampil selama jendela utama terbuka.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "showMenuBar") && UserDefaults.standard.object(forKey: "showMenuBar") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow, closing.title == "Lega" || (closing.identifier?.rawValue.hasPrefix("main") ?? false) else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

@main
struct LegaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var m = Model()
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("didSetupLogin") private var didSetupLogin = false
    @AppStorage("appearance") private var appearance = "sistem"

    init() {
        // Peluncuran pertama: daftarkan sebagai login item, sesuai default produk
        if !UserDefaults.standard.bool(forKey: "didSetupLogin") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didSetupLogin")
        }
    }

    var body: some Scene {
        Window("Lega", id: "main") {
            MainView().environmentObject(m).frame(minWidth: 760, minHeight: 600)
                .preferredColorScheme(scheme(appearance))
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentMinSize)
        // Saat menu bar aktif dan Mac baru menyala, jendela tidak ikut muncul
        .defaultLaunchBehavior(showMenuBar && wasLaunchedAtLogin ? .suppressed : .presented)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel().environmentObject(m).preferredColorScheme(scheme(appearance))
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView() }
    }

    var wasLaunchedAtLogin: Bool {
        let e = NSAppleEventManager.shared().currentAppleEvent
        return e?.eventID == kAEOpenApplication
            && e?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
