// Peta ruang dan sisa aplikasi.
// Peta ruang menjawab "ke mana ruang saya pergi", termasuk data yang tidak boleh dihapus otomatis.
// Sisa aplikasi adalah folder data milik aplikasi yang sudah di-uninstall. Menghapus aplikasi
// hanya membuang berkas .app, sedangkan datanya di ~/Library tetap tinggal.
// Lisensi MIT. Lihat LICENSE.

import SwiftUI
import AppKit

struct SpaceItem: Identifiable {
    var id: String { url.path }
    let url: URL
    let size: Int64
    let name: String       // nama yang ramah dibaca
    let place: String      // lokasi induknya, misalnya ~/Library/Application Support
}

extension Engine {
    /// Batas ukuran supaya daftar tidak dipenuhi folder kecil.
    static let leftoverMin: Int64 = 100_000_000
    /// Folder yang masih diubah dalam 14 hari terakhir dianggap masih dipakai sesuatu.
    static let recentDays: Double = 14

    /// Kata pengenal aplikasi yang terpasang: bundle ID, nama, dan nama program.
    static func installedOwners() -> (ids: [String], names: [String]) {
        var ids: [String] = [], names: [String] = []
        var dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"].map { URL(fileURLWithPath: $0) }
        dirs.append(url("~/Applications"))
        var apps: [URL] = []
        for d in dirs {
            let items = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for u in items {
                if u.pathExtension == "app" { apps.append(u) }
                else { // folder seperti "Chrome Apps.localized" berisi aplikasi lagi
                    apps += ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
                }
            }
        }
        for a in apps {
            names.append(norm(a.deletingPathExtension().lastPathComponent))
            if let b = Bundle(url: a) {
                if let i = b.bundleIdentifier { ids.append(i.lowercased()) }
                for k in ["CFBundleName", "CFBundleExecutable", "CFBundleDisplayName"] {
                    if let s = b.object(forInfoDictionaryKey: k) as? String { names.append(norm(s)) }
                }
            }
        }
        for r in NSWorkspace.shared.runningApplications {
            if let i = r.bundleIdentifier { ids.append(i.lowercased()) }
            if let n = r.localizedName { names.append(norm(n)) }
        }
        return (ids, names.filter { $0.count >= 3 })
    }

    static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Folder milik sistem atau dipakai bersama banyak aplikasi. Tidak pernah dianggap sisa.
    static let sharedFolders: Set<String> = [
        "google", "microsoft", "mozilla", "crashreporter", "diagnosticreports", "clouddocs", "cloudkit",
        "knowledge", "addressbook", "callhistorydb", "callhistorytransactions", "syncservices", "mobilesync",
        "fileprovider", "icloud", "familycircle", "accounts", "ids", "identityservices", "dock", "skylight",
        "ubiquity", "homebrew", "pip", "pypoetry", "node", "nodegyp", "gobuild", "jetbrains", "electron",
        "squirrel", "sparkle", "ms-playwright", "org.sparkle-project.sparkle", "com.crashlytics", "sentry", "lega",
    ]

    /// Pemilik dotfolder di home yang dikenal, dengan nama program baris perintahnya.
    static let dotOwners: [String: (apps: [String], cli: [String])] = [
        ".vscode": (["visualstudiocode", "code", "com.microsoft.vscode"], ["code"]),
        ".cursor": (["cursor"], ["cursor"]),
        ".windsurf": (["windsurf"], ["windsurf"]),
        ".codeium": (["windsurf", "codeium"], ["windsurf"]),
        ".lmstudio": (["lmstudio"], ["lms"]),
        ".ollama": (["ollama"], ["ollama"]),
        ".zed": (["zed"], ["zed"]),
    ]

    /// Apakah folder bernama `name` masih punya pemilik yang terpasang?
    static func owned(_ name: String, ids: [String], names: [String]) -> Bool {
        var l = name.lowercased()
        if l.contains("apple") || sharedFolders.contains(l) || sharedFolders.contains(norm(l)) { return true }
        if l.hasPrefix("group.") { l.removeFirst(6) }
        // Awalan Team ID Apple, misalnya "ubf8t346g9.office"
        if let dot = l.firstIndex(of: "."), l.distance(from: l.startIndex, to: dot) == 10,
           l[..<dot].allSatisfy({ $0.isLetter || $0.isNumber }) { l = String(l[l.index(after: dot)...]) }
        if l.contains(".") {
            if ids.contains(where: { l.hasPrefix($0) || $0.hasPrefix(l) }) { return true }
            // Cocokkan potongan bermakna, misalnya "whatsapp" dari net.whatsapp.WhatsApp.shared
            let parts = l.split(separator: ".").map { norm(String($0)) }.filter { $0.count >= 4 && !["com", "net", "org", "shared", "group", "app", "desktop", "macos", "mac"].contains($0) }
            return parts.contains { p in names.contains { $0 == p || $0.hasPrefix(p) || p.hasPrefix($0) } }
        }
        let n = norm(l)
        guard n.count >= 3 else { return true }
        return names.contains { n.hasPrefix($0) || $0.hasPrefix(n) } || ids.contains { $0.hasSuffix("." + n) }
    }

    /// Terakhir diubah: folder itu sendiri dan isi tingkat pertamanya.
    static func lastTouched(_ u: URL) -> Date {
        let k: Set<URLResourceKey> = [.contentModificationDateKey]
        var d = (try? u.resourceValues(forKeys: k).contentModificationDate) ?? .distantPast
        for c in (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: Array(k))) ?? [] {
            if let m = try? c.resourceValues(forKeys: k).contentModificationDate, m > d { d = m }
        }
        return d
    }

    static func cliExists(_ names: [String]) -> Bool {
        let bins = ["/opt/homebrew/bin", "/usr/local/bin", (("~/.local/bin") as NSString).expandingTildeInPath]
        return names.contains { n in bins.contains { fm.fileExists(atPath: "\($0)/\(n)") } }
    }

    static func friendly(_ name: String) -> String {
        let l = name.lowercased()
        if l.contains("whatsapp") { return "WhatsApp" }
        if name.filter({ $0 == "." }).count >= 2 {
            let generic: Set<String> = ["com", "net", "org", "group", "us", "io", "asc", "shared", "macos", "mac", "app", "direct", "client", "vpnclient", "desktop", "helper", "global"]
            let parts = name.split(separator: ".").map(String.init).filter { !generic.contains($0.lowercased()) }
            return parts.last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? name
        }
        return name
    }

    /// Satu pemindaian untuk dua hasil: peta ruang (terbesar dulu) dan daftar sisa aplikasi.
    static func spaceScan(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) -> (map: [SpaceItem], leftovers: [SpaceItem]) {
        let home = url("~")
        let lib = home.appendingPathComponent("Library")
        let libParts = ["Application Support", "Group Containers", "Containers", "Caches"]
        var map: [SpaceItem] = []
        var candidates: [SpaceItem] = []

        // Isi home tingkat pertama, kecuali Library yang dirinci di bawah
        // Daftar kerja dulu, supaya kemajuan bisa ditampilkan sebagai persentase
        let homeItems = ((try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent != "Library" }
        let libItems = libParts.flatMap { p in
            ((try? fm.contentsOfDirectory(at: lib.appendingPathComponent(p), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).map { (p, $0) }
        }
        let count = Double(max(1, homeItems.count + libItems.count))
        var step = 0.0
        func tick(_ u: URL) { step += 1; progress(step / count, u.lastPathComponent) }

        for u in homeItems {
            tick(u)
            let s = size(u)
            guard s > 0 else { continue }
            let it = SpaceItem(url: u, size: s, name: u.lastPathComponent, place: "~")
            map.append(it)
            if dotOwners[u.lastPathComponent] != nil { candidates.append(it) }
        }
        // Library dirinci per folder aplikasi, karena di sinilah data aplikasi menumpuk
        for (p, u) in libItems {
            tick(u)
            let s = size(u)
            guard s >= 20_000_000 else { continue }
            let it = SpaceItem(url: u, size: s, name: friendly(u.lastPathComponent), place: "~/Library/\(p)")
            map.append(it)
            candidates.append(it)
        }

        let (ids, names) = installedOwners()
        let cutoff = Date().addingTimeInterval(-recentDays * 86_400)
        let leftovers = candidates.filter { it in
            guard it.size >= leftoverMin else { return false }
            let folder = it.url.lastPathComponent
            if let d = dotOwners[folder] {
                let has = d.apps.contains { a in names.contains(a) || ids.contains(a) } || cliExists(d.cli)
                if has { return false }
            } else if owned(folder, ids: ids, names: names) || cliExists([folder.lowercased()]) { return false }
            return lastTouched(it.url) < cutoff
        }
        return (map.sorted { $0.size > $1.size }, leftovers.sorted { $0.size > $1.size })
    }
}

extension Model {
    /// Disk kritis: sisa ruang di bawah 5% kapasitas.
    var isCritical: Bool { total > 0 && Double(free) / Double(total) < 0.05 }
    var leftoverTotal: Int64 { leftovers.reduce(0) { $0 + $1.size } }

    func scanSpace(force: Bool = false) {
        guard !demo else { return }
        guard !scanningSpace else { return }   // hasil pemindaian yang sedang jalan tetap memicu tawaran
        scanningSpace = true
        spaceProgress = 0; spaceCurrent = ""
        Task.detached {
            let r = Engine.spaceScan { f, name in
                Task { @MainActor in self.spaceProgress = f; self.spaceCurrent = name }
            }
            Engine.log("peta ruang: sisa aplikasi " + r.leftovers.map { "\($0.place)/\($0.url.lastPathComponent) \(fmt($0.size))" }.joined(separator: "; "))
            await MainActor.run {
                withAnimation(.snappy) { self.space = Array(r.map.prefix(15)); self.leftovers = r.leftovers }
                self.scanningSpace = false
                self.spaceScannedAt = Date()
                if self.phase == .scanning && !self.scanningAdv { withAnimation(.spring(response: 0.5)) { self.phase = .results } }
            }
        }
    }

    func trashLeftover(_ it: SpaceItem) {
        ask(tr("Pindahkan \(it.name) ke Trash?", "Move \(it.name) to the Trash?"),
            tr("\(fmt(it.size)) di \(it.place). Tidak ada aplikasi terpasang yang memakai folder ini, dan isinya tidak berubah selama \(Int(Engine.recentDays)) hari. Masih bisa dikembalikan dari Trash.",
               "\(fmt(it.size)) in \(it.place). No installed app uses this folder, and it has not changed for \(Int(Engine.recentDays)) days. It can still be restored from the Trash."),
            confirm: tr("Ke Trash", "Move to Trash")) { [self] in removeLeftovers([it]) }
    }
}

// MARK: - Tampilan

struct SpaceRow: View {
    @EnvironmentObject var m: Model
    let item: SpaceItem
    var maxSize: Int64 = 0
    var leftover = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if maxSize > 0 {
                    GeometryReader { g in
                        Capsule().fill(accent.opacity(0.8))
                            .frame(width: max(4, g.size.width * CGFloat(Double(item.size) / Double(maxSize))))
                    }
                    .frame(height: 4)
                }
                Text(item.place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if hover || leftover {
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                    .help(tr("Tampilkan di Finder", "Show in Finder"))
            }
            if leftover {
                Button(tr("Ke Trash", "Move to Trash")) { m.trashLeftover(item) }
                    .buttonStyle(PillButtonStyle(prominent: false)).disabled(m.busy)
            }
            Text(fmt(item.size)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 70, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// Daftar bersama untuk tampilan sidebar dan satu halaman.
struct SpaceList: View {
    @EnvironmentObject var m: Model
    var leftovers = false

    var items: [SpaceItem] { leftovers ? m.leftovers : m.space }

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                Text(m.scanningSpace ? tr("Mengukur folder. Bisa beberapa menit di disk yang penuh.", "Measuring folders. This can take a few minutes on a full disk.")
                     : leftovers ? tr("Tidak ada sisa aplikasi yang ditemukan.", "No leftovers from removed apps found.")
                     : tr("Belum diukur.", "Not measured yet."))
                    .font(.callout).foregroundStyle(.secondary).padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                if i > 0 { Divider().padding(.leading, 52) }
                SpaceRow(item: it, maxSize: leftovers ? 0 : (items.first?.size ?? 0), leftover: leftovers)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
    }
}

struct SpacePane: View {
    @EnvironmentObject var m: Model
    var leftovers = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(leftovers
                     ? tr("Menghapus aplikasi hanya membuang berkas .app. Data, cache, dan model miliknya tetap tinggal di Library atau folder tersembunyi di home. Lega menampilkan folder di atas 100 MB yang tidak dipakai aplikasi terpasang mana pun dan tidak berubah selama 14 hari.",
                          "Removing an app only throws away the .app file. Its data, caches and models stay behind in Library or in hidden folders in your home. Lega lists folders over 100 MB that no installed app uses and that have not changed for 14 days.")
                     : tr("Folder terbesar di home Anda, termasuk data yang tidak dihapus otomatis. Rapikan lewat aplikasinya masing-masing bila memungkinkan.",
                          "The largest folders in your home, including data Lega never deletes on its own. Tidy them up in their own apps where you can."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let r = m.result { ResultChip(text: r) }
                if m.scanningSpace { MeasuringCard() }
                SpaceList(leftovers: leftovers)
                if leftovers {
                    Text(tr("Periksa nama foldernya dulu. Data yang masih Anda butuhkan, misalnya model AI yang dipakai lewat terminal, sebaiknya dibiarkan.",
                            "Check the folder name first. Keep anything you still need, for example AI models you use from the terminal."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .animation(.spring(response: 0.4), value: m.result)
        }
    }
}

// MARK: - Tawaran sisa aplikasi di Quick clean

extension Model {
    var leftoverChosen: [SpaceItem] { leftovers.filter { !leftoverSkip.contains($0.id) } }

    /// Satu konfirmasi untuk semua sisa aplikasi yang dicentang.
    func trashLeftovers() {
        let items = leftoverChosen
        guard !items.isEmpty else { return }
        let total = items.reduce(0) { $0 + $1.size }
        let list = items.prefix(12).map { "• \($0.name) (\(fmt($0.size)))" }.joined(separator: "\n")
            + (items.count > 12 ? tr("\n…dan \(items.count - 12) lainnya", "\n…and \(items.count - 12) more") : "")
        ask(tr("Pindahkan \(items.count) sisa aplikasi ke Trash?", "Move \(items.count) leftovers to the Trash?"),
            tr("\(fmt(total)) dari aplikasi yang sudah dihapus:\n\n\(list)\n\nMasih bisa dikembalikan dari Trash.",
               "\(fmt(total)) from apps you removed:\n\n\(list)\n\nThey can still be restored from the Trash."),
            confirm: tr("Ke Trash", "Move to Trash")) { [self] in removeLeftovers(items) }
    }
}

// MARK: - Izin sekali jalan

enum Access {
    /// Full Disk Access terbukti bila database izin macOS bisa dibaca. Berkas ini hanya terbuka dengan izin itu.
    static var hasFullDisk: Bool {
        let p = ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString).expandingTildeInPath
        return FileManager.default.isReadableFile(atPath: p) && (try? FileHandle(forReadingFrom: URL(fileURLWithPath: p)))?.readData(ofLength: 1).isEmpty == false
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

/// Layar sambutan: satu izin untuk semua folder. Muncul sekali, lalu tidak lagi setelah diizinkan atau dilewati.
struct AccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("accessAsked") private var asked = false
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LegaMark(size: 30)
            Text(tr("Beri Lega satu izin, sekali saja", "Give Lega one permission, once")).font(.title2.weight(.semibold))
            Text(tr("Tanpa Full Disk Access, macOS akan menanyakan izin per folder, dan Trash serta data aplikasi yang sudah dihapus tidak bisa diukur. Dengan satu izin ini, Lega bisa melihat semuanya. Lega tetap tidak menghapus apa pun tanpa bertanya.",
                    "Without Full Disk Access, macOS asks for each folder separately, and Lega cannot measure the Trash or data left by removed apps. With this one permission Lega can see everything. Lega still never deletes anything without asking."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("1. Klik Buka Pengaturan.", "1. Click Open Settings."))
                Text(tr("2. Nyalakan Lega di daftar Full Disk Access.", "2. Turn on Lega in the Full Disk Access list."))
                Text(tr("3. Kembali ke sini. Lega mendeteksinya sendiri.", "3. Come back here. Lega notices on its own."))
            }
            .font(.callout)
            HStack {
                Button(tr("Nanti saja", "Not now")) { asked = true; dismiss() }
                Spacer()
                Button(tr("Buka Pengaturan", "Open Settings")) { Access.openSettings() }
                    .buttonStyle(.borderedProminent).tint(accent)
            }
        }
        .padding(28)
        .frame(width: 460)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if Access.hasFullDisk { asked = true; dismiss(); m.refresh() }
        }
    }
}

/// Kartu yang jelas terlihat saat Lega mengukur folder: ikon berdenyut, nama folder yang sedang diukur, dan bar kemajuan.
struct MeasuringCard: View {
    @EnvironmentObject var m: Model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 28)).foregroundStyle(accent)
                .symbolEffect(.pulse, options: .repeating, isActive: true)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tr("Mengukur folder Anda", "Measuring your folders")).font(.headline)
                    Spacer()
                    Text("\(Int(m.spaceProgress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                ProgressView(value: m.spaceProgress).tint(accent)
                    .animation(.easeOut(duration: 0.3), value: m.spaceProgress)
                Text(m.spaceCurrent.isEmpty
                     ? tr("Mencari sisa aplikasi dan pemakai ruang terbesar", "Looking for app leftovers and what uses the most space")
                     : tr("Sedang mengukur \(m.spaceCurrent)", "Now measuring \(m.spaceCurrent)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(14)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.25)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
extension Engine {
    /// Pindahkan ke Trash satu per satu, catat hasilnya. Bila Trash menolak (misalnya disk 0 byte
    /// atau folder dilindungi macOS), alasannya dikembalikan supaya bisa ditawarkan hapus permanen.
    static func moveToTrash(_ items: [SpaceItem]) -> (done: [SpaceItem], failed: [(SpaceItem, String)]) {
        var done: [SpaceItem] = [], failed: [(SpaceItem, String)] = []
        for it in items {
            do { try fm.trashItem(at: it.url, resultingItemURL: nil); done.append(it); log("sisa aplikasi: trash \(it.url.path)") }
            catch { failed.append((it, error.localizedDescription)); log("sisa aplikasi: gagal trash \(it.url.path): \(error.localizedDescription)") }
        }
        return (done, failed)
    }

    static func deleteForever(_ items: [SpaceItem]) -> (done: [SpaceItem], failed: [(SpaceItem, String)]) {
        var done: [SpaceItem] = [], failed: [(SpaceItem, String)] = []
        for it in items {
            do { try fm.removeItem(at: it.url); done.append(it); log("sisa aplikasi: hapus permanen \(it.url.path)") }
            catch { failed.append((it, error.localizedDescription)); log("sisa aplikasi: gagal hapus \(it.url.path): \(error.localizedDescription)") }
        }
        return (done, failed)
    }
}

extension Model {
    /// Jalur bersama untuk satu folder maupun banyak: Trash dulu, lalu tawarkan hapus permanen bila gagal.
    func removeLeftovers(_ items: [SpaceItem]) {
        busy = true
        Task.detached {
            let r = Engine.moveToTrash(items)
            await MainActor.run { self.finishLeftovers(r, permanent: false) }
        }
    }

    func finishLeftovers(_ r: (done: [SpaceItem], failed: [(SpaceItem, String)]), permanent: Bool) {
        let gone = Set(r.done.map(\.id))
        withAnimation(.snappy) {
            leftovers.removeAll { gone.contains($0.id) }
            space.removeAll { gone.contains($0.id) }
        }
        let freed = r.done.reduce(0) { $0 + $1.size }
        if !permanent, let t = adv["trash"], t >= 0 { adv["trash"] = t + freed }
        busy = false
        if r.failed.isEmpty {
            result = permanent
                ? tr("\(fmt(freed)) dihapus permanen.", "\(fmt(freed)) deleted permanently.")
                : tr("\(fmt(freed)) dipindah ke Trash. Kosongkan Trash supaya ruangnya kembali.", "\(fmt(freed)) moved to the Trash. Empty the Trash to get the space back.")
            Task { @MainActor in let (f, t) = Engine.disk(); withAnimation(.snappy) { self.free = f; self.total = t } }
            return
        }
        let bad = r.failed.map(\.0)
        let why = r.failed.first?.1 ?? ""
        if permanent {
            result = tr("\(bad.count) folder gagal dihapus: \(why)", "\(bad.count) folders could not be deleted: \(why)")
            return
        }
        let total = bad.reduce(0) { $0 + $1.size }
        ask(tr("Trash menolak \(bad.count) folder", "The Trash refused \(bad.count) folders"),
            tr("Alasan dari macOS: \(why)\n\nIni biasa terjadi saat disk benar-benar penuh. Hapus permanen \(fmt(total)) sekarang? Langkah ini tidak bisa dibatalkan.",
               "macOS said: \(why)\n\nThis often happens when the disk is completely full. Delete \(fmt(total)) permanently now? This cannot be undone."),
            confirm: tr("Hapus permanen", "Delete permanently")) { [self] in
            busy = true
            Task.detached {
                let r2 = Engine.deleteForever(bad)
                await MainActor.run { self.finishLeftovers(r2, permanent: true) }
            }
        }
        if !r.done.isEmpty && result == nil {
            result = tr("\(fmt(freed)) dipindah ke Trash.", "\(fmt(freed)) moved to the Trash.")
        }
    }
}

