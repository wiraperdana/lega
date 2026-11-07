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
    CacheTarget(id: "codex", name: "Versi lama Codex", note: "Versi aktif dan dua terbaru disimpan", icon: "shippingbox", paths: [], codexReleases: true),
    CacheTarget(id: "arc", name: "Cache Arc", note: "Dibuat ulang saat browsing", icon: "globe", paths: ["~/Library/Caches/Arc"], blockers: ["Arc"]),
    CacheTarget(id: "comet", name: "Cache Comet", note: "Dibuat ulang saat browsing", icon: "globe", paths: ["~/Library/Caches/Comet"], blockers: ["Comet"]),
    CacheTarget(id: "chrome", name: "Cache Google Chrome", note: "Dibuat ulang saat browsing", icon: "globe", paths: ["~/Library/Caches/Google/Chrome"], blockers: ["Google Chrome"]),
    CacheTarget(id: "zoom", name: "Cache Zoom", note: "Dibuat ulang saat Zoom dipakai", icon: "video", paths: ["~/Library/Caches/us.zoom.xos"], blockers: ["zoom.us"]),
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

// MARK: - Jendela utama

struct MainView: View {
    @EnvironmentObject var m: Model

    var body: some View {
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
        .toolbar {
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
        let visible = quickTargets.filter { (m.sizes[$0.id] ?? 0) > 0 || m.statuses[$0.id] != nil }
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
                        IconTile(symbol: t.icon)
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
                if (m.adv["whatsapp"] ?? 0) > 0 {
                    card("message", "Media WhatsApp", m.adv["whatsapp"],
                         "Rapikan lewat Settings, Storage di WhatsApp. Jangan hapus filenya langsung.", "Buka WhatsApp") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/WhatsApp.app"))
                    }
                }
                if (m.adv["claudevm"] ?? 0) > 0 {
                    card("cpu", "VM Claude Desktop", m.adv["claudevm"],
                         "Diunduh ulang kalau fitur agent dipakai lagi. Claude harus tertutup.", "Hapus") {
                        m.removeFolder("claudevm", "~/Library/Application Support/Claude/vm_bundles", blockers: ["Claude"],
                                       title: "Hapus VM Claude Desktop?",
                                       message: "Claude Desktop akan mengunduhnya ulang kalau fitur agent dipakai lagi. Penghapusan ini permanen.")
                    }
                }
                if m.mauInstalled {
                    card("arrow.triangle.2.circlepath", "Microsoft AutoUpdate", nil,
                         m.msApps.isEmpty ? "Tidak ada aplikasi Microsoft lagi. Updater ini aman dihapus."
                                          : "Masih dipakai \(m.msApps.joined(separator: ", ")).",
                         "Hapus", enabled: m.msApps.isEmpty) { m.removeMAU() }
                }
                if (m.adv["autorecover"] ?? 0) > 0 {
                    card("doc.badge.clock", "AutoRecovery Office", m.adv["autorecover"],
                         "Salinan darurat Word, Excel, PowerPoint yang tertinggal.", "Ke Trash") { m.cleanAutoRecover() }
                }
                if (m.adv["playwright"] ?? 0) > 0 {
                    card("theatermasks", "Browser Playwright", m.adv["playwright"],
                         "Browser uji otomatis. Diunduh ulang saat dibutuhkan.", "Hapus") {
                        m.removeFolder("playwright", "~/Library/Caches/ms-playwright",
                                       title: "Hapus browser Playwright?",
                                       message: "Akan diunduh ulang saat playwright install dijalankan. Penghapusan ini permanen.")
                    }
                }
                if m.scanningAdv {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Memindai WhatsApp").foregroundStyle(.secondary) }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 168)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                }
                card("trash", "Trash", nil,
                     "File di Trash baru membebaskan ruang setelah dikosongkan.", "Kosongkan") { m.emptyTrash() }
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
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Buka saat Mac menyala", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in setLogin(on) }
            Toggle("Tampilkan di menu bar", isOn: $showMenuBar)
            if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
            Text("Kalau keduanya aktif, Lega berjalan diam-diam di menu bar setiap Mac menyala.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
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

@main
struct LegaApp: App {
    @StateObject var m = Model()
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("didSetupLogin") private var didSetupLogin = false

    init() {
        // Peluncuran pertama: daftarkan sebagai login item, sesuai default produk
        if !UserDefaults.standard.bool(forKey: "didSetupLogin") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didSetupLogin")
        }
    }

    var body: some Scene {
        Window("Lega", id: "main") {
            MainView().environmentObject(m).frame(minWidth: 640, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        // Saat menu bar aktif dan Mac baru menyala, jendela tidak ikut muncul
        .defaultLaunchBehavior(showMenuBar && wasLaunchedAtLogin ? .suppressed : .presented)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel().environmentObject(m)
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
