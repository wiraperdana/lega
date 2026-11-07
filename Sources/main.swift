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


var quickTargets: [CacheTarget] { [
    CacheTarget(id: "codex", name: tr("Versi lama Codex", "Old Codex versions"), note: tr("Versi aktif dan dua terbaru disimpan", "The active and two newest are kept"), icon: "shippingbox", paths: [], codexReleases: true, app: "Codex"),
    CacheTarget(id: "arc", name: "Cache Arc", note: tr("Dibuat ulang saat browsing", "Rebuilt while you browse"), icon: "globe", paths: ["~/Library/Caches/Arc", "~/Library/Application Support/Arc/User Data/Default/Service Worker/CacheStorage"], blockers: ["Arc"], app: "Arc"),
    CacheTarget(id: "comet", name: "Cache Comet", note: tr("Dibuat ulang saat browsing", "Rebuilt while you browse"), icon: "globe", paths: ["~/Library/Caches/Comet", "~/Library/Application Support/Comet/Default/Service Worker/CacheStorage"], blockers: ["Comet"], app: "Comet"),
    CacheTarget(id: "chrome", name: "Cache Google Chrome", note: tr("Dibuat ulang saat browsing", "Rebuilt while you browse"), icon: "globe", paths: ["~/Library/Caches/Google/Chrome", "~/Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage"], blockers: ["Google Chrome"], app: "Google Chrome"),
    CacheTarget(id: "zoom", name: "Cache Zoom", note: tr("Dibuat ulang saat Zoom dipakai", "Rebuilt when Zoom is used"), icon: "video", paths: ["~/Library/Caches/us.zoom.xos"], blockers: ["zoom.us"], app: "zoom.us"),
    CacheTarget(id: "zcode", name: tr("Unduhan update zcode", "zcode update downloads"), note: tr("Diunduh ulang saat update berikutnya", "Downloaded again at the next update"), icon: "arrow.down.circle", paths: ["~/Library/Caches/@zcodedesktop-updater"]),
    CacheTarget(id: "brew", name: "Cache Homebrew", note: tr("Unduhan paket lama", "Old package downloads"), icon: "mug", paths: ["~/Library/Caches/Homebrew"]),
    CacheTarget(id: "npm", name: "Cache npm", note: tr("Unduhan paket Node.js", "Node.js package downloads"), icon: "cube", paths: ["~/.npm/_cacache"]),
    CacheTarget(id: "pip", name: tr("Cache pip dan uv", "pip and uv cache"), note: tr("Unduhan paket Python", "Python package downloads"), icon: "cube", paths: ["~/Library/Caches/pip", "~/.cache/uv"]),
    CacheTarget(id: "build", name: tr("Cache build Go dan node-gyp", "Go and node-gyp build cache"), note: tr("Hasil kompilasi sementara", "Temporary build output"), icon: "hammer", paths: ["~/Library/Caches/go-build", "~/Library/Caches/node-gyp"]),
    CacheTarget(id: "clang", name: tr("Cache compiler Clang dan Swift", "Clang and Swift compiler cache"), note: tr("Dibuat ulang saat kompilasi berikutnya", "Rebuilt at the next compile"), icon: "hammer", paths: [userCacheDir() + "clang/ModuleCache"]),
] }

/// Folder cache per pengguna milik macOS, misalnya /var/folders/xx/.../C/.
func userCacheDir() -> String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    return confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count) > 0 ? String(cString: buf) : NSTemporaryDirectory()
}

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
        if r.code != 0 { return r.out.contains("-128") ? tr("Dibatalkan.", "Cancelled.") : tr("Gagal: \(r.out)", "Failed: \(r.out)") }
        return mauInstalled() ? tr("Sebagian file MAU masih tersisa.", "Some MAU files are still there.") : tr("Microsoft AutoUpdate sudah dihapus.", "Microsoft AutoUpdate has been removed.")
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

    /// Ukuran file swap di disk (vm.swapusage, total).
    static func swapTotal() -> Int64 {
        var u = xsw_usage()
        var n = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &u, &n, nil, 0) == 0 ? Int64(u.xsu_total) : 0
    }

    static func bootDate() -> Date {
        var tv = timeval()
        var n = MemoryLayout<timeval>.size
        return sysctlbyname("kern.boottime", &tv, &n, nil, 0) == 0 ? Date(timeIntervalSince1970: Double(tv.tv_sec)) : Date()
    }

    /// Aplikasi terbesar di /Applications dan ~/Applications.
    static func appsTop(_ n: Int) -> [FileItem] {
        let dirs = [URL(fileURLWithPath: "/Applications"), url("~/Applications")]
        let apps = dirs.flatMap { d in
            ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "app" }
        }
        return apps.map { u in
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

/// Bahasa antarmuka: "en" (default) atau "id".
func tr(_ id: String, _ en: String) -> String {
    (UserDefaults.standard.string(forKey: "language") ?? "en") == "id" ? id : en
}

func uptimeText(_ t: TimeInterval) -> String {
    let d = Int(t) / 86_400, h = Int(t) % 86_400 / 3_600
    return d > 0 ? tr("\(d) hari \(h) jam", "\(d) d \(h) h") : tr("\(h) jam", "\(h) h")
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
    @Published var apps: [FileItem] = []
    @Published var mauInstalled = false
    @Published var msApps: [String] = []
    @Published var scanning = false      // pemindaian cepat (cache)
    @Published var scanningAdv = false   // pemindaian lanjutan (WhatsApp, Downloads)
    @Published var busy = false
    @Published var result: String?
    @Published var pane: Pane = .cepat
    @Published var showSettings = false
    @Published var swapBytes: Int64 = 0
    @Published var bootDate = Date()

    var uptime: TimeInterval { Date().timeIntervalSince(bootDate) }
    /// Saran restart: swap besar, atau Mac sudah lama tidak dimatikan.
    var suggestRestart: Bool { swapBytes >= 2_000_000_000 || uptime >= 3 * 86_400 }

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
            let sizes = s, swap = Engine.swapTotal(), boot = Engine.bootDate()
            await MainActor.run {
                withAnimation(.snappy) { self.sizes = sizes; self.free = f; self.total = tot }
                self.swapBytes = swap; self.bootDate = boot; self.scanning = false
            }

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
            let ap = Engine.appsTop(12)
            await MainActor.run { self.apps = ap }
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
                    st[t.id] = tr("Dilewati, \(b) sedang terbuka", "Skipped, \(b) is open")
                    continue
                }
                let r = Engine.clean(t)
                freed += r.freed
                if let e = r.error { st[t.id] = tr("Sebagian gagal: \(e)", "Partly failed: \(e)") }
            }
            Engine.log("cepat: dibebaskan \(fmt(freed))")
            let statuses = st, total = freed
            await MainActor.run {
                self.statuses = statuses
                let skipped = statuses.count
                if total > 0 {
                    self.result = tr("\(fmt(total)) dibebaskan.", "\(fmt(total)) freed.")
                } else if skipped > 0 {
                    self.result = tr("Belum ada yang dibersihkan. \(skipped) cache dilewati karena aplikasinya terbuka.",
                                     "Nothing cleaned yet. \(skipped) cache skipped because its app is open.")
                } else {
                    self.result = tr("Tidak ada yang perlu dibersihkan.", "Nothing to clean.")
                }
                self.busy = false
                self.refresh()
            }
        }
    }

    // Opsi lanjutan

    func ask(_ title: String, _ message: String, confirm: String = tr("Hapus", "Delete"), _ action: @escaping () -> Void) {
        // NSAlert bekerja dari jendela utama maupun panel menu bar
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: confirm).hasDestructiveAction = true
        a.addButton(withTitle: tr("Batal", "Cancel"))
        if a.runModal() == .alertFirstButtonReturn { action() }
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
        if let b = blocked(by: blockers) { result = tr("Tutup \(b) dulu.", "Quit \(b) first."); return }
        ask(title, message) { [self] in
            runAdvanced(label) {
                let u = Engine.url(path)
                let s = Engine.size(u)
                do { try FileManager.default.removeItem(at: u); return tr("\(fmt(s)) dibebaskan.", "\(fmt(s)) freed.") }
                catch { return tr("Gagal: \(error.localizedDescription)", "Failed: \(error.localizedDescription)") }
            }
        }
    }

    func cleanAutoRecover() {
        if let b = blocked(by: Array(Engine.officeApps.values)) { result = tr("Tutup \(b) dulu.", "Quit \(b) first."); return }
        ask(tr("Pindahkan file AutoRecovery ke Trash?", "Move AutoRecovery files to the Trash?"),
            tr("Ini salinan darurat Word, Excel, dan PowerPoint. Pastikan dokumen aslinya sudah tersimpan. File masih bisa dikembalikan dari Trash.", "These are emergency copies from Word, Excel and PowerPoint. Make sure the original documents are saved. The files can still be restored from the Trash."),
            confirm: tr("Ke Trash", "Move to Trash")) { [self] in
            runAdvanced("autorecover") {
                var n = 0
                for f in Engine.autoRecoverFiles() where (try? FileManager.default.trashItem(at: f, resultingItemURL: nil)) != nil { n += 1 }
                return tr("\(n) file AutoRecovery dipindah ke Trash.", "\(n) AutoRecovery files moved to the Trash.")
            }
        }
    }

    func removeMAU() {
        ask(tr("Hapus Microsoft AutoUpdate?", "Remove Microsoft AutoUpdate?"),
            tr("Tidak ada aplikasi Microsoft yang terdeteksi, jadi updater ini tidak lagi punya tugas. macOS akan meminta password admin.", "No Microsoft apps were found, so this updater has nothing left to do. macOS will ask for an admin password.")) { [self] in
            runAdvanced("mau") { Engine.removeMAU() }
        }
    }

    /// Satu pintu untuk tombol Trash: aplikasi dan file Downloads.
    func trash(_ item: FileItem) {
        item.url.pathExtension == "app" ? trashApp(item) : trashDownload(item)
    }

    func trashApp(_ item: FileItem) {
        let name = item.url.deletingPathExtension().lastPathComponent
        if item.url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { result = tr("Lega tidak bisa membuang dirinya sendiri.", "Lega cannot move itself to the Trash."); return }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.standardizedFileURL == item.url.standardizedFileURL }) {
            result = tr("Tutup \(name) dulu.", "Quit \(name) first."); return
        }
        ask(tr("Pindahkan \(name) ke Trash?", "Move \(name) to the Trash?"),
            tr("\(fmt(item.size)). Aplikasinya dipindah ke Trash dan masih bisa dikembalikan. Pengaturan dan datanya di Library tidak disentuh.", "\(fmt(item.size)). The app moves to the Trash and can still be restored. Its settings and data in Library stay untouched."),
            confirm: tr("Ke Trash", "Move to Trash")) { [self] in
            NSWorkspace.shared.recycle([item.url]) { _, error in
                Task { @MainActor in
                    if let error {
                        self.result = tr("Gagal: \(error.localizedDescription)", "Failed: \(error.localizedDescription)")
                    } else {
                        Engine.log("lanjutan: trash aplikasi \(item.url.path)")
                        self.apps.removeAll { $0.id == item.id }
                        self.result = tr("\(name) dipindah ke Trash. Kosongkan Trash supaya ruangnya kembali.", "\(name) moved to the Trash. Empty the Trash to get the space back.")
                    }
                }
            }
        }
    }

    func trashDownload(_ item: FileItem) {
        ask(tr("Pindahkan ke Trash?", "Move to the Trash?"), tr("\(item.url.lastPathComponent) (\(fmt(item.size))). Masih bisa dikembalikan dari Trash.", "\(item.url.lastPathComponent) (\(fmt(item.size))). It can still be restored from the Trash."), confirm: tr("Ke Trash", "Move to Trash")) { [self] in
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                Engine.log("lanjutan: trash \(item.url.path)")
                downloads.removeAll { $0.id == item.id }
                result = tr("\(item.url.lastPathComponent) dipindah ke Trash. Kosongkan Trash supaya ruangnya kembali.", "\(item.url.lastPathComponent) moved to the Trash. Empty the Trash to get the space back.")
            } catch { result = tr("Gagal: \(error.localizedDescription)", "Failed: \(error.localizedDescription)") }
        }
    }

    /// Dialog restart bawaan macOS, yang masih menanyakan konfirmasi.
    func restartMac() {
        Engine.log("saran restart: swap \(fmt(swapBytes))")
        NSAppleScript(source: "tell application \"loginwindow\" to «event aevtrrst»")?.executeAndReturnError(nil)
    }

    func showSettingsPage() {
        if (UserDefaults.standard.string(forKey: "viewMode") ?? "sidebar") == "sidebar" { pane = .pengaturan }
        else { showSettings = true }
    }

    func emptyTrash() {
        ask(tr("Kosongkan Trash?", "Empty the Trash?"), tr("Semua isi Trash dihapus permanen.", "Everything in the Trash is deleted permanently."), confirm: tr("Kosongkan", "Empty")) { [self] in
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&err)
            result = err == nil ? tr("Trash dikosongkan.", "Trash emptied.") : tr("Gagal. Izinkan Lega mengontrol Finder di System Settings, Privacy & Security, Automation.", "Failed. Allow Lega to control Finder in System Settings, Privacy & Security, Automation.")
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
                             note: tr("Rapikan lewat Settings, Storage di WhatsApp. Jangan hapus filenya langsung.", "Tidy up in WhatsApp under Settings, Storage. Never delete its files directly."),
                             short: tr("Dirapikan lewat aplikasinya", "Tidied up in the app itself"), button: tr("Buka aplikasi", "Open app"), prominent: true) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/WhatsApp.app"))
            })
        }
        if (adv["claudevm"] ?? 0) > 0 {
            a.append(AdvItem(id: "claudevm", symbol: "cpu", initials: "VM", title: "VM Claude Desktop", size: adv["claudevm"],
                             note: tr("Diunduh ulang kalau fitur agent dipakai lagi. Claude harus tertutup.", "Downloaded again if the agent feature is used. Claude must be closed."),
                             short: tr("Diunduh ulang saat dipakai", "Downloaded again when needed"), button: tr("Hapus", "Delete")) { [self] in
                removeFolder("claudevm", "~/Library/Application Support/Claude/vm_bundles", blockers: ["Claude"],
                             title: tr("Hapus VM Claude Desktop?", "Delete the Claude Desktop VM?"),
                             message: tr("Claude Desktop akan mengunduhnya ulang kalau fitur agent dipakai lagi. Penghapusan ini permanen.", "Claude Desktop downloads it again if the agent feature is used. This deletion is permanent."))
            })
        }
        if mauInstalled {
            a.append(AdvItem(id: "mau", symbol: "arrow.triangle.2.circlepath", initials: "MS", title: "Microsoft AutoUpdate", size: nil,
                             note: msApps.isEmpty ? tr("Tidak ada aplikasi Microsoft lagi. Updater ini aman dihapus.", "No Microsoft apps left. This updater is safe to remove.")
                                                  : tr("Masih dipakai \(msApps.joined(separator: ", ")).", "Still used by \(msApps.joined(separator: ", "))."),
                             short: msApps.isEmpty ? tr("Tak ada aplikasi Microsoft", "No Microsoft apps left") : tr("Masih dipakai aplikasi Microsoft", "Still used by Microsoft apps"),
                             button: tr("Hapus", "Delete"), enabled: msApps.isEmpty) { [self] in removeMAU() })
        }
        if (adv["autorecover"] ?? 0) > 0 {
            a.append(AdvItem(id: "autorecover", symbol: "doc.badge.clock", initials: "AR", title: "AutoRecovery Office", size: adv["autorecover"],
                             note: tr("Salinan darurat Word, Excel, PowerPoint yang tertinggal.", "Leftover emergency copies from Word, Excel and PowerPoint."),
                             short: tr("Salinan darurat tertinggal", "Leftover emergency copies"), button: tr("Ke Trash", "Move to Trash")) { [self] in cleanAutoRecover() })
        }
        if (adv["playwright"] ?? 0) > 0 {
            a.append(AdvItem(id: "playwright", symbol: "theatermasks", initials: "PW", title: "Browser Playwright", size: adv["playwright"],
                             note: tr("Browser uji otomatis. Diunduh ulang saat dibutuhkan.", "Browsers for automated tests. Downloaded again when needed."),
                             short: tr("Browser uji otomatis", "Browsers for automated tests"), button: tr("Hapus", "Delete")) { [self] in
                removeFolder("playwright", "~/Library/Caches/ms-playwright",
                             title: tr("Hapus browser Playwright?", "Delete the Playwright browsers?"),
                             message: tr("Akan diunduh ulang saat playwright install dijalankan. Penghapusan ini permanen.", "They download again when playwright install runs. This deletion is permanent."))
            })
        }
        a.append(AdvItem(id: "trash", symbol: "trash", initials: "TR", title: "Trash", size: nil,
                         note: tr("File di Trash baru membebaskan ruang setelah dikosongkan.", "Files in the Trash only free space once it is emptied."),
                         short: tr("Kosongkan lewat Finder", "Emptied through Finder"), button: tr("Kosongkan", "Empty")) { [self] in emptyTrash() })
        return a
    }
}

// MARK: - Komponen

struct Ring: View {
    let fraction: Double
    let low: Bool
    var lineWidth: CGFloat = 12
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown ? fraction : 0)
                .stroke(low ? Color.red : accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: fraction)
        }
        .onAppear { withAnimation(.spring(response: 1.1, dampingFraction: 0.8).delay(0.15)) { shown = true } }
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
    var size: CGFloat = 32
    var body: some View {
        let hue = Double(initials.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) } % 360) / 360
        Text(initials)
            .font(.system(size: size * 0.375, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(hue: hue, saturation: 0.45, brightness: 0.45))
            .frame(width: size, height: size)
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

/// Saran restart saat swap besar atau Mac sudah lama menyala.
/// Logo Lega: ikon aplikasinya sendiri, plus nama.
struct LegaMark: View {
    var size: CGFloat = 28
    var body: some View {
        HStack(spacing: size * 0.35) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: size, height: size)
            Text("Lega").font(.system(size: size * 0.62, weight: .semibold, design: .rounded))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lega")
    }
}

struct RestartCard: View {
    @EnvironmentObject var m: Model
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: compact ? 20 : 26))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Mac menyala \(uptimeText(m.uptime))", "Mac on for \(uptimeText(m.uptime))")).font(.callout.weight(.semibold))
                Text(compact ? tr("Restart mengembalikan \(fmt(m.swapBytes)) swap.", "A restart frees \(fmt(m.swapBytes)) of swap.")
                             : tr("Swap, yaitu RAM cadangan di disk, memakai \(fmt(m.swapBytes)). Restart mengembalikan ruang itu dan menyegarkan memori.", "Swap, the backup RAM on your disk, takes \(fmt(m.swapBytes)). A restart frees that space and refreshes memory."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if compact {
                Button("Restart") { m.restartMac() }
                    .buttonStyle(.link).font(.callout)
            } else {
                Button("Restart") { m.restartMac() }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(compact ? 10 : 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Jendela utama

struct MainView: View {
    @EnvironmentObject var m: Model
    @AppStorage("viewMode") private var viewMode = "sidebar"
    @AppStorage("appearance") private var appearance = "sistem"

    var body: some View {
        Group {
            if viewMode == "sidebar" { SidebarLayout().frame(minWidth: 940, minHeight: 600) } else { classic }
        }
        .sheet(isPresented: $m.showSettings) {
            VStack(spacing: 0) {
                SettingsView(embedded: true)
                HStack { Spacer(); Button(tr("Selesai", "Done")) { m.showSettings = false }.keyboardShortcut(.defaultAction) }
                    .padding([.horizontal, .bottom], 20)
            }
            .frame(width: 480)
        }
        .toolbar {
            ToolbarItem {
                Picker(tr("Tampilan", "Layout"), selection: $viewMode) {
                    Image(systemName: "sidebar.left").tag("sidebar").help(tr("Tampilan sidebar", "Sidebar layout"))
                    Image(systemName: "rectangle.grid.1x2").tag("halaman").help(tr("Tampilan satu halaman", "Single page layout"))
                }
                .pickerStyle(.segmented)
                .help(tr("Pilih tampilan", "Choose a layout"))
            }
            ToolbarItem {
                Menu {
                    Picker("Mode", selection: $appearance) {
                        Label(tr("Ikuti sistem", "Match system"), systemImage: "circle.lefthalf.filled").tag("sistem")
                        Label(tr("Terang", "Light"), systemImage: "sun.max").tag("terang")
                        Label(tr("Gelap", "Dark"), systemImage: "moon").tag("gelap")
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: appearance == "terang" ? "sun.max" : appearance == "gelap" ? "moon" : "circle.lefthalf.filled")
                }
                .help(tr("Mode terang atau gelap", "Light or dark mode"))
            }
            ToolbarItem {
                Button { m.refresh() } label: { Label(tr("Pindai ulang", "Scan again"), systemImage: "arrow.clockwise") }
                    .disabled(m.scanning || m.scanningAdv || m.busy)
                    .help(tr("Pindai ulang", "Scan again"))
            }
            ToolbarItem {
                Button { m.showSettingsPage() } label: { Label(tr("Pengaturan", "Settings"), systemImage: "gearshape") }
                    .help(tr("Pengaturan", "Settings"))
            }
        }
    }

    @State private var classicH: CGFloat = 640

    /// Tampilan satu halaman: lebar tetap, tinggi jendela mengikuti isi sampai setinggi layar.
    var classic: some View {
        let maxH = (NSScreen.main?.visibleFrame.height ?? 900) - 60
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LegaMark(size: 34)
                hero
                if m.suggestRestart { RestartCard() }
                if let r = m.result { resultBanner(r) }
                quickSection
                advancedSection
                downloadsSection
                appsSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            .animation(.spring(response: 0.4), value: m.result)
            .animation(.spring(response: 0.4), value: m.suggestRestart)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(HeightKey.self) { classicH = $0 }
        .frame(width: 760, height: min(max(classicH, 320), maxH))
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var hero: some View {
        HStack(spacing: 28) {
            ZStack {
                Ring(fraction: m.usedFraction, low: m.isLow, lineWidth: 14)
                VStack(spacing: 0) {
                    Text("\(Int((m.usedFraction * 100).rounded()))%")
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(tr("terpakai", "used")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 132, height: 132)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fmt(m.free))
                        .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(m.isLow ? .red : .primary)
                        .contentTransition(.numericText())
                    Text(m.isLow ? tr("Kosong. Di bawah 10 GB, Mac bisa melambat.", "Free. Under 10 GB, a Mac can slow down.") : tr("Kosong dari \(fmt(m.total))", "Free of \(fmt(m.total))"))
                        .foregroundStyle(.secondary)
                }
                Button { m.cleanQuick() } label: {
                    HStack(spacing: 8) {
                        if m.busy { ProgressView().controlSize(.small).tint(.white) }
                        else { Image(systemName: "sparkles").symbolEffect(.bounce, value: m.result) }
                        Text(m.busy ? tr("Membersihkan", "Cleaning") : tr("Bersihkan \(fmt(m.quickTotal))", "Clean \(fmt(m.quickTotal))"))
                            .contentTransition(.numericText())
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
            SectionTitle(text: tr("Pembersihan cepat", "Quick clean"))
            Text(tr("Cache yang dibuat ulang sendiri. Cache aplikasi yang sedang terbuka dilewati.", "Caches that rebuild themselves. Caches of apps that are open are skipped."))
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                if visible.isEmpty {
                    HStack(spacing: 10) {
                        IconTile(symbol: "checkmark")
                        Text(m.scanning ? tr("Memindai cache", "Scanning caches") : tr("Semua cache sudah bersih.", "All caches are clean."))
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
            SectionTitle(text: tr("Opsi lanjutan", "Advanced options"))
            Text(tr("Data yang lebih besar. Setiap tindakan meminta konfirmasi dulu.", "Larger data. Every action asks you first."))
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(m.advItems) { it in
                    card(it.symbol, it.title, it.size, it.note, it.button, enabled: it.enabled, action: it.action)
                }
                if m.scanningAdv {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(tr("Memindai WhatsApp", "Scanning WhatsApp")).foregroundStyle(.secondary) }
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

    var appsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: tr("Aplikasi terbesar", "Largest apps"))
            VStack(spacing: 0) {
                if m.apps.isEmpty {
                    Text(m.scanningAdv ? tr("Memindai Applications", "Scanning Applications") : tr("Belum ada aplikasi yang terbaca.", "No apps found yet."))
                        .font(.callout).foregroundStyle(.secondary).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(m.apps.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { Divider().padding(.leading, 52) }
                    DownloadRow(item: f)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
        .disabled(m.busy)
    }

    var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: tr("Item terbesar di Downloads", "Largest items in Downloads"))
            VStack(spacing: 0) {
                if m.downloads.isEmpty {
                    Text(m.scanningAdv && m.downloads.isEmpty ? tr("Memindai Downloads", "Scanning Downloads") : tr("Kosong, atau Lega belum diizinkan membaca Downloads.", "Empty, or Lega has no access to Downloads yet."))
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
                    .help(tr("Tampilkan di Finder", "Show in Finder"))
                Button { m.trash(item) } label: { Image(systemName: "trash") }
                    .help(tr("Pindahkan ke Trash", "Move to Trash"))
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

enum Pane: Hashable { case cepat, lanjutan, downloads, aplikasi, log, pengaturan }

struct SidebarLayout: View {
    @EnvironmentObject var m: Model
    var pane: Pane? { m.pane }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { m.pane }, set: { if let v = $0 { m.pane = v } })) {
                LegaMark(size: 26).padding(.vertical, 6).selectionDisabled()
                Label(tr("Cepat", "Quick"), systemImage: "sparkles").badge(m.visibleQuick.count).tag(Pane.cepat)
                Label(tr("Lanjutan", "Advanced"), systemImage: "slider.horizontal.3").badge(m.advItems.count).tag(Pane.lanjutan)
                Label("Downloads", systemImage: "arrow.down.circle").badge(m.downloads.count).tag(Pane.downloads)
                Label("Applications", systemImage: "square.grid.3x3").badge(m.apps.count).tag(Pane.aplikasi)
                Label("Log", systemImage: "list.bullet.rectangle").tag(Pane.log)
                Section {
                    Label(tr("Pengaturan", "Settings"), systemImage: "gearshape").tag(Pane.pengaturan)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            Group {
                switch pane ?? .cepat {
                case .cepat: QuickPane()
                case .lanjutan: AdvancedPane()
                case .downloads: DownloadsPane()
                case .aplikasi: DownloadsPane(apps: true)
                case .log: LogPane()
                case .pengaturan: ScrollView { SettingsView(embedded: true).padding(8) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle(title)
    }

    var title: String {
        switch pane ?? .cepat {
        case .cepat: tr("Pembersihan cepat", "Quick clean")
        case .lanjutan: tr("Opsi lanjutan", "Advanced options")
        case .downloads: "Downloads"
        case .aplikasi: "Applications"
        case .log: "Log"
        case .pengaturan: tr("Pengaturan", "Settings")
        }
    }
}

/// Status pemindaian berbentuk kapsul, misalnya tr("Memindai", "Scanning").
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
                .symbolEffect(.bounce, value: text)
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
                        Text(m.isLow ? tr("Kosong. Di bawah 10 GB, Mac bisa melambat.", "Free. Under 10 GB, a Mac can slow down.") : tr("kosong dari \(fmt(m.total))", "free of \(fmt(m.total))"))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(0)
                    Spacer(minLength: 8)
                    Button { m.cleanQuick() } label: {
                        HStack(spacing: 8) {
                            if m.busy { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: "sparkles").symbolEffect(.bounce, value: m.result) }
                            Text(m.busy ? tr("Membersihkan", "Cleaning") : tr("Bersihkan \(fmt(m.quickTotal))", "Clean \(fmt(m.quickTotal))"))
                                .contentTransition(.numericText())
                        }
                        .font(.headline)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .fixedSize()
                    }
                    .buttonStyle(.borderedProminent).tint(accent).clipShape(Capsule())
                    .disabled(m.busy || m.scanning || m.quickTotal == 0)
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08)))

                if m.suggestRestart { RestartCard() }
                if let r = m.result { ResultChip(text: r).transition(.scale(scale: 0.96).combined(with: .opacity)) }
                if m.scanning { ScanChip(text: tr("Memindai cache", "Scanning caches")).transition(.opacity) }

                VStack(spacing: 0) {
                    if m.visibleQuick.isEmpty && !m.scanning {
                        Text(tr("Semua cache sudah bersih.", "All caches are clean.")).foregroundStyle(.secondary)
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
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: m.visibleQuick.map(\.id))
                Text(tr("Cache yang dibuat ulang sendiri. Cache aplikasi yang sedang terbuka dilewati.", "Caches that rebuild themselves. Caches of apps that are open are skipped."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
            .animation(.spring(response: 0.4), value: m.result)
            .animation(.spring(response: 0.4), value: m.scanning)
        }
    }
}

struct AdvancedPane: View {
    @EnvironmentObject var m: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let r = m.result { ResultChip(text: r) }
                if m.scanningAdv { ScanChip(text: tr("Memindai data besar", "Scanning large data")) }
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
                Text(tr("Setiap tindakan meminta konfirmasi dulu.", "Every action asks you first.")).font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}

struct DownloadsPane: View {
    @EnvironmentObject var m: Model
    var apps = false
    @AppStorage("downloadsLayout") private var layout = "grid"
    var items: [FileItem] { apps ? m.apps : m.downloads }
    var emptyText: String { apps ? tr("Belum ada aplikasi yang terbaca.", "No apps found yet.") : tr("Kosong, atau Lega belum diizinkan membaca Downloads.", "Empty, or Lega has no access to Downloads yet.") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(apps ? tr("\(items.count) aplikasi terbesar", "\(items.count) largest apps") : tr("\(items.count) item terbesar", "\(items.count) largest items")).foregroundStyle(.secondary)
                    Spacer()
                    Picker(tr("Susunan", "Arrangement"), selection: $layout) {
                        Image(systemName: "square.grid.2x2").tag("grid").help("Grid")
                        Image(systemName: "list.bullet").tag("list").help("List")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if let r = m.result { ResultChip(text: r) }
                if m.scanningAdv && items.isEmpty { ScanChip(text: apps ? tr("Memindai Applications", "Scanning Applications") : tr("Memindai Downloads", "Scanning Downloads")) }
                if items.isEmpty && !m.scanningAdv {
                    Text(emptyText).foregroundStyle(.secondary)
                }
                if layout == "grid" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                        ForEach(items) { FileTile(item: $0) }
                    }
                    .transition(.opacity)
                } else if !items.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, f in
                            if i > 0 { Divider() }
                            DownloadRow(item: f).padding(.vertical, 4)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
                    .transition(.opacity)
                }
            }
            .padding(24)
            .animation(.easeInOut(duration: 0.2), value: layout)
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
                        .help(tr("Tampilkan di Finder", "Show in Finder"))
                    Button { m.trash(item) } label: { Image(systemName: "trash") }
                        .help(tr("Pindahkan ke Trash", "Move to Trash"))
                }
                .buttonStyle(.borderless).padding(6)
            }
        }
        .offset(y: hover ? -2 : 0)
        .animation(.easeOut(duration: 0.15), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button(tr("Tampilkan di Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button(tr("Pindahkan ke Trash", "Move to Trash")) { m.trash(item) }
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
                if lines.isEmpty { Text(tr("Belum ada catatan pembersihan.", "No cleanups logged yet.")).foregroundStyle(.secondary) }
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
        VStack(alignment: .leading, spacing: 12) {
            LegaMark(size: 22)
            HStack(spacing: 14) {
                Ring(fraction: m.usedFraction, low: m.isLow, lineWidth: 6).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 0) {
                    Text(fmt(m.free)).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(m.isLow ? .red : .primary)
                        .contentTransition(.numericText())
                    Text(tr("kosong dari \(fmt(m.total))", "free of \(fmt(m.total))")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if m.suggestRestart { RestartCard(compact: true) }
            Button { m.cleanQuick() } label: {
                HStack {
                    if m.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "sparkles").symbolEffect(.bounce, value: m.result) }
                    Text(m.busy ? tr("Membersihkan", "Cleaning") : tr("Bersihkan \(fmt(m.quickTotal))", "Clean \(fmt(m.quickTotal))"))
                }
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent).tint(accent).controlSize(.extraLarge)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(m.busy || m.scanning || m.quickTotal == 0)
            if let r = m.result { Text(r).font(.caption).foregroundStyle(.secondary) }

            Divider()
            Text(tr("Opsi lanjutan", "Advanced options")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(m.advItems.prefix(5)) { it in
                HStack(spacing: 10) {
                    Avatar(initials: it.initials, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(it.title).font(.callout).lineLimit(1)
                        if let s = it.size { Text(fmt(s)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    }
                    Spacer(minLength: 6)
                    Button(it.button, action: it.action)
                        .buttonStyle(PillButtonStyle(prominent: it.prominent))
                        .disabled(!it.enabled || m.busy)
                }
                .help(it.note)
            }

            Divider()
            HStack(spacing: 8) {
                Button { open(nil) } label: { Label(tr("Buka Lega", "Open Lega"), systemImage: "macwindow") }
                    .buttonStyle(.bordered)
                Spacer()
                Button { open(.pengaturan) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help(tr("Pengaturan", "Settings"))
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help(tr("Keluar", "Quit"))
            }
        }
        .padding(16)
        .frame(width: 320)
        .animation(.spring(response: 0.4), value: m.result)
    }

    /// Membuka jendela utama, opsional langsung ke halaman tertentu.
    func open(_ pane: Pane?) {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        if pane == .pengaturan { m.showSettingsPage() } else if let p = pane { m.pane = p }
    }
}

struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    let m: Model
    var body: some View {
        Button(tr("Pengaturan…", "Settings…")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            m.showSettingsPage()
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

// MARK: - Pengaturan

struct SettingsView: View {
    var embedded = false
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("viewMode") private var viewMode = "sidebar"
    @AppStorage("appearance") private var appearance = "sistem"
    @AppStorage("language") private var language = "en"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker("Language / Bahasa", selection: $language) {
                Text("English").tag("en")
                Text("Bahasa Indonesia").tag("id")
            }
            Picker(tr("Tampilan", "Layout"), selection: $viewMode) {
                Text("Sidebar").tag("sidebar")
                Text(tr("Satu halaman", "Single page")).tag("halaman")
            }
            Picker("Mode", selection: $appearance) {
                Text(tr("Ikuti sistem", "Match system")).tag("sistem")
                Text(tr("Terang", "Light")).tag("terang")
                Text(tr("Gelap", "Dark")).tag("gelap")
            }
            Toggle(tr("Buka saat Mac menyala", "Open at login"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in setLogin(on) }
            Toggle(tr("Tampilkan di menu bar", "Show in menu bar"), isOn: $showMenuBar)
            if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
            Text(tr("Kalau keduanya aktif, Lega berjalan diam-diam di menu bar setiap Mac menyala.", "With both on, Lega runs quietly in the menu bar every time your Mac starts."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(maxWidth: 560, alignment: .leading)
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = tr("Gagal mengubah login item: \(error.localizedDescription)", "Could not change the login item: \(error.localizedDescription)")
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
    @AppStorage("language") private var language = "en"

    init() {
        // Peluncuran pertama: daftarkan sebagai login item, sesuai default produk
        if !UserDefaults.standard.bool(forKey: "didSetupLogin") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didSetupLogin")
        }
    }

    var body: some Scene {
        Window("Lega", id: "main") {
            MainView().environmentObject(m)
                .id(language)   // bangun ulang semua teks saat bahasa diganti
                .preferredColorScheme(scheme(appearance))
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .appSettings) { SettingsCommand(m: m) } }
        // Saat menu bar aktif dan Mac baru menyala, jendela tidak ikut muncul
        .defaultLaunchBehavior(showMenuBar && wasLaunchedAtLogin ? .suppressed : .presented)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel().environmentObject(m).id(language).preferredColorScheme(scheme(appearance))
        } label: {
            Image(systemName: m.busy ? "sparkles.rectangle.stack" : "sparkles")
        }
        .menuBarExtraStyle(.window)
    }

    var wasLaunchedAtLogin: Bool {
        let e = NSAppleEventManager.shared().currentAppleEvent
        return e?.eventID == kAEOpenApplication
            && e?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
