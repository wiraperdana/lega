// Tampilan utama Lega: satu tombol Scan, hasil per kategori, satu tombol Clean.
// Rincian tiap kategori ada di halamannya sendiri, supaya Beranda tetap ringkas.
// Lisensi MIT. Lihat LICENSE.

import SwiftUI
import AppKit

enum Pane: Hashable { case home, cache, leftovers, trash, large, apps, appdata, map, history, settings }
enum Phase { case idle, scanning, results, done }

/// Tingkat risiko yang selalu terlihat pada kategori dan item.
enum Risk {
    case safe, review, inApp
    var label: String {
        switch self {
        case .safe: tr("Aman", "Safe")
        case .review: tr("Periksa dulu", "Review")
        case .inApp: tr("Lewat aplikasinya", "In the app")
        }
    }
    var color: Color {
        switch self {
        case .safe: accent
        case .review: .orange
        case .inApp: .secondary
        }
    }
}

struct Category: Identifiable {
    let id: Pane
    let title: String
    let symbol: String
    let risk: Risk
    let size: Int64
    let count: Int
    let checkable: Bool
    let detail: String
}

// MARK: - Data uninstall bersih

extension Engine {
    /// Folder data milik satu aplikasi di Library, dicari lewat bundle ID dan namanya.
    static func appData(for app: URL) -> [URL] {
        guard let b = Bundle(url: app) else { return [] }
        let bid = b.bundleIdentifier ?? ""
        let name = app.deletingPathExtension().lastPathComponent
        let lib = url("~/Library")
        var paths: [String] = []
        for key in [bid, name] where !key.isEmpty {
            paths += ["Application Support/\(key)", "Caches/\(key)", "Containers/\(key)", "HTTPStorages/\(key)",
                      "WebKit/\(key)", "Logs/\(key)", "Saved Application State/\(key).savedState"]
        }
        if !bid.isEmpty { paths.append("Preferences/\(bid).plist") }
        var seen = Set<String>()
        return paths.map { lib.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
    }
}

// MARK: - Model: kategori, scan, dan clean gabungan

extension Model {
    var trashSize: Int64 { max(0, adv["trash"] ?? 0) }
    var largeChosenItems: [FileItem] { downloads.filter { largeChosen.contains($0.url.path) } }
    var appDataItems: [AdvItem] { advItems.filter { $0.id != "trash" } }

    var categories: [Category] {
        [
            Category(id: .cache, title: "Cache", symbol: "sparkles", risk: .safe, size: quickTotal, count: visibleQuick.count, checkable: true,
                     detail: tr("Dibuat ulang sendiri oleh aplikasinya", "Rebuilt by their apps on their own")),
            Category(id: .leftovers, title: tr("Sisa aplikasi", "App leftovers"), symbol: "shippingbox", risk: .review,
                     size: leftoverChosen.reduce(0) { $0 + $1.size }, count: leftovers.count, checkable: true,
                     detail: tr("Data aplikasi yang sudah Anda hapus", "Data from apps you removed")),
            Category(id: .large, title: tr("File besar", "Large files"), symbol: "doc.on.doc", risk: .review,
                     size: largeChosenItems.reduce(0) { $0 + $1.size }, count: downloads.count, checkable: !largeChosen.isEmpty,
                     detail: largeChosen.isEmpty ? tr("Pilih sendiri dari Downloads", "Pick your own from Downloads")
                                                 : tr("\(largeChosen.count) dipilih dari Downloads", "\(largeChosen.count) picked from Downloads")),
            Category(id: .trash, title: "Trash", symbol: "trash", risk: .safe, size: trashSize, count: 0, checkable: true,
                     detail: tr("Dikosongkan permanen di akhir", "Emptied permanently at the end")),
            Category(id: .appdata, title: tr("Data aplikasi", "App data"), symbol: "externaldrive", risk: .inApp,
                     size: appDataItems.compactMap(\.size).reduce(0, +), count: appDataItems.count, checkable: false,
                     detail: tr("WhatsApp, VM Claude, dan lainnya", "WhatsApp, Claude VM and more")),
        ]
    }

    func isChecked(_ c: Category) -> Bool { c.checkable && checked.contains(c.id) }
    var selectedTotal: Int64 { categories.filter(isChecked).reduce(0) { $0 + $1.size } }
    var foundTotal: Int64 { categories.filter { $0.id != .appdata }.reduce(0) { $0 + $1.size } + leftoverSkipSize }
    private var leftoverSkipSize: Int64 { leftovers.filter { leftoverSkip.contains($0.id) }.reduce(0) { $0 + $1.size } }

    /// Kemajuan scan gabungan: cache dan data besar dulu, lalu pengukuran folder.
    var scanProgress: Double {
        if scanning || scanningAdv { return 0.08 }
        return 0.1 + 0.9 * spaceProgress
    }

    func startScan() {
        withAnimation(.spring(response: 0.5)) { phase = .scanning; pane = .home }
        if !scanning && !scanningAdv && !scanningSpace,
           let t = spaceScannedAt, Date().timeIntervalSince(t) < 600 {
            // Hasil peta ruang masih segar: cukup ukur ulang cache, lalu tampilkan hasil
            refreshQuick { withAnimation(.spring(response: 0.5)) { self.phase = .results } }
            return
        }
        spaceScannedAt = nil
        refresh()
        if !scanning && !scanningAdv { scanSpace() }
    }

    func refreshQuick(_ done: @escaping @MainActor () -> Void) {
        Task.detached {
            var s: [String: Int64] = [:]
            for t in quickTargets { s[t.id] = Engine.size(of: t) }
            let (f, tot) = Engine.disk()
            let sizes = s
            await MainActor.run { self.sizes = sizes; self.free = f; self.total = tot; done() }
        }
    }

    /// Satu konfirmasi, lalu semua kategori yang dicentang dibersihkan berurutan.
    func cleanSelected() {
        let cats = categories.filter(isChecked)
        guard !cats.isEmpty else { return }
        let lines = cats.map { "• \($0.title): \(fmt($0.size))" }.joined(separator: "\n")
        let emptiesTrash = cats.contains { $0.id == .trash }
        ask(tr("Bersihkan \(fmt(selectedTotal))?", "Clean \(fmt(selectedTotal))?"),
            lines + "\n\n" + (emptiesTrash
                ? tr("Cache dihapus karena dibuat ulang sendiri. File lain dipindah ke Trash, lalu Trash dikosongkan permanen.",
                     "Caches are deleted because they rebuild. Other files move to the Trash, then the Trash is emptied permanently.")
                : tr("Cache dihapus karena dibuat ulang sendiri. File lain dipindah ke Trash dan masih bisa dikembalikan.",
                     "Caches are deleted because they rebuild. Other files move to the Trash and can still be restored.")),
            confirm: tr("Bersihkan", "Clean")) { [self] in runClean(cats.map(\.id)) }
    }

    private func runClean(_ ids: [Pane]) {
        busy = true
        let before = free
        let running = Engine.runningAppNames()
        let lefts = ids.contains(.leftovers) ? leftoverChosen : []
        let larges = ids.contains(.large) ? largeChosenItems : []
        Task.detached {
            var st: [String: String] = [:]
            var reported: Int64 = 0
            if ids.contains(.cache) {
                for t in quickTargets {
                    if let b = t.blockers.first(where: running.contains) { st[t.id] = tr("Dilewati, \(b) sedang terbuka", "Skipped, \(b) is open"); continue }
                    reported += Engine.clean(t).freed
                }
            }
            let lr = Engine.moveToTrash(lefts)
            var movedLarge: [String] = []
            for f in larges where (try? FileManager.default.trashItem(at: f.url, resultingItemURL: nil)) != nil {
                movedLarge.append(f.url.path); Engine.log("clean: trash \(f.url.path)")
            }
            let statuses = st
            let gone = Set(lr.done.map(\.id)), moved = lr.done.reduce(0) { $0 + $1.size }
            let largeMoved = larges.filter { movedLarge.contains($0.url.path) }.reduce(0) { $0 + $1.size }
            await MainActor.run {
                if ids.contains(.trash) {
                    var err: NSDictionary?
                    NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&err)
                    if err == nil { self.adv["trash"] = 0 } else { self.adv["trash"] = self.trashSize + moved + largeMoved }
                } else if self.adv["trash"] != nil {
                    self.adv["trash"] = self.trashSize + moved + largeMoved
                }
                self.statuses = statuses
                self.leftovers.removeAll { gone.contains($0.id) }
                self.space.removeAll { gone.contains($0.id) }
                self.downloads.removeAll { movedLarge.contains($0.url.path) }
                self.largeChosen.subtract(movedLarge)
                let (f, t) = Engine.disk()
                withAnimation(.snappy) { self.free = f; self.total = t }
                // Ruang dari Trash baru kembali setelah Trash dikosongkan, jadi keduanya dicatat terpisah
                let emptied = ids.contains(.trash) && self.trashSize == 0
                self.lastMoved = emptied ? 0 : moved + largeMoved
                self.lastFreed = max(f - before, reported + (emptied ? moved + largeMoved : 0))
                Engine.log("clean: dibebaskan \(fmt(self.lastFreed)), ke Trash \(fmt(self.lastMoved))")
                UserDefaults.standard.set(Date(), forKey: "lastCleaned")
                UserDefaults.standard.set(Double(self.lastFreed + self.lastMoved), forKey: "lastFreed")
                self.busy = false
                withAnimation(.spring(response: 0.5)) { self.phase = .done }
                self.refreshQuick {}
            }
        }
    }
}

// MARK: - Komponen kecil

struct RiskBadge: View {
    let risk: Risk
    var body: some View {
        Text(risk.label).font(.caption.weight(.medium))
            .foregroundStyle(risk.color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(risk.color.opacity(0.12)))
    }
}

/// Tombol utama yang sama di seluruh aplikasi.
struct PrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small).tint(.white) }
                else if let symbol { Image(systemName: symbol) }
                Text(title).contentTransition(.numericText())
            }
            .font(.headline)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .fixedSize()
        }
        .buttonStyle(.borderedProminent).tint(accent).clipShape(Capsule())
    }
}

/// Lingkaran ruang besar dengan angka di tengah. Saat scan, lingkaran menjadi bar kemajuan.
struct SpaceDial: View {
    @EnvironmentObject var m: Model
    var scanning = false
    @State private var spin = false

    var body: some View {
        ZStack {
            if scanning {
                Circle().stroke(.quaternary, lineWidth: 14)
                Circle().trim(from: 0, to: m.scanProgress)
                    .stroke(accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: m.scanProgress)
                Circle().trim(from: 0, to: 0.08)
                    .stroke(accent.opacity(0.35), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            } else {
                Ring(fraction: m.usedFraction, low: m.isCritical, lineWidth: 14)
            }
            VStack(spacing: 2) {
                Text(scanning ? "\(Int(m.scanProgress * 100))%" : fmt(m.free))
                    .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(!scanning && m.isCritical ? Color.red : Color.primary)
                    .contentTransition(.numericText())
                Text(scanning ? tr("memindai", "scanning") : tr("kosong dari \(fmt(m.total))", "free of \(fmt(m.total))"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(width: 200, height: 200)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Jendela utama

struct MainView: View {
    @EnvironmentObject var m: Model
    @AppStorage("appearance") private var appearance = "sistem"

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { m.pane }, set: { if let v = $0 { m.pane = v } })) {
                LegaMark(size: 26).padding(.vertical, 6).selectionDisabled()
                Label(tr("Beranda", "Home"), systemImage: "house").tag(Pane.home)
                Section(tr("Bersihkan", "Clean")) {
                    row(.cache, "Cache", "sparkles", m.quickTotal)
                    row(.leftovers, tr("Sisa aplikasi", "App leftovers"), "shippingbox", m.leftoverTotal)
                    row(.trash, "Trash", "trash", m.trashSize)
                }
                Section(tr("Rapikan", "Tidy up")) {
                    row(.large, tr("File besar", "Large files"), "doc.on.doc", nil)
                    row(.apps, tr("Aplikasi", "Applications"), "square.grid.3x3", nil)
                    row(.appdata, tr("Data aplikasi", "App data"), "externaldrive", nil)
                }
                Section(tr("Pahami", "Understand")) {
                    Label(tr("Peta ruang", "Space map"), systemImage: "chart.bar.xaxis").tag(Pane.map)
                    Label(tr("Riwayat", "History"), systemImage: "clock").tag(Pane.history)
                }
                Section { Label(tr("Pengaturan", "Settings"), systemImage: "gearshape").tag(Pane.settings) }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                switch m.pane {
                case .home: HomeView()
                case .map: SpacePane()
                case .history: LogPane()
                case .settings: ScrollView { SettingsView(embedded: true).padding(8) }
                default: CategoryPage(id: m.pane)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SkinBackground())
        }
        .frame(minWidth: 860, minHeight: 600)
        .onChange(of: appearance) { _, a in applyAppearance(a) }
        .toolbar {
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
                Button { m.startScan() } label: { Label(tr("Scan ulang", "Scan again"), systemImage: "arrow.clockwise") }
                    .disabled(m.phase == .scanning || m.busy)
                    .help(tr("Scan ulang", "Scan again"))
            }
        }
    }

    @ViewBuilder func row(_ p: Pane, _ title: String, _ symbol: String, _ size: Int64?) -> some View {
        if let size, size > 0 {
            Label(title, systemImage: symbol).badge(Text(fmt(size)).monospacedDigit()).tag(p)
        } else {
            Label(title, systemImage: symbol).tag(p)
        }
    }
}

// MARK: - Beranda

struct HomeView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                switch m.phase {
                case .idle: idle
                case .scanning: scanning
                case .results: results
                case .done: done
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 32).padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
    }

    // 1. Sebelum scan: satu lingkaran, satu angka, satu tombol
    var idle: some View {
        VStack(spacing: 22) {
            ZStack { SkinArt(); SpaceDial() }
            if m.isCritical {
                Text(tr("Disk hampir penuh. Scan untuk menemukan ruang.", "Your disk is almost full. Scan to find space."))
                    .foregroundStyle(.red)
            }
            PrimaryButton(title: tr("Scan Mac", "Scan Mac"), symbol: "magnifyingglass") { m.startScan() }
                .keyboardShortcut(.defaultAction)
            if let d = UserDefaults.standard.object(forKey: "lastCleaned") as? Date {
                Text(tr("Terakhir dibersihkan \(d.formatted(.relative(presentation: .named))) · \(fmt(Int64(UserDefaults.standard.double(forKey: "lastFreed"))))",
                        "Last cleaned \(d.formatted(.relative(presentation: .named))) · \(fmt(Int64(UserDefaults.standard.double(forKey: "lastFreed"))))"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if m.suggestRestart { restartLine }
            if let r = m.result { ResultChip(text: r) }
            UpdateBanner()
            Text("Lega \(appVersion)").font(.caption).foregroundStyle(.tertiary)
        }
        .transition(.opacity)
    }

    // 2. Scan: lingkaran jadi kemajuan, kategori terisi satu per satu
    var scanning: some View {
        VStack(spacing: 22) {
            SpaceDial(scanning: true)
            Text(m.spaceCurrent.isEmpty ? tr("Mengukur cache dan data besar", "Measuring caches and large data")
                                        : tr("Mengukur \(m.spaceCurrent)", "Measuring \(m.spaceCurrent)"))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            VStack(spacing: 0) {
                ForEach(Array(m.categories.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { Divider().padding(.leading, 52) }
                    HStack(spacing: 14) {
                        IconTile(symbol: c.symbol)
                        Text(c.title)
                        Spacer()
                        if done(c) { Text(fmt(c.size)).monospacedDigit().foregroundStyle(.secondary).transition(.opacity) }
                        else { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            .animation(.easeOut, value: m.scanningSpace)
            .animation(.easeOut, value: m.scanningAdv)
        }
        .transition(.opacity)
    }

    func done(_ c: Category) -> Bool {
        switch c.id {
        case .cache: !m.scanning
        case .leftovers: !m.scanningSpace && !m.scanning && !m.scanningAdv
        default: !m.scanningAdv
        }
    }

    // 3. Hasil: kategori bercentang, satu tombol Clean
    var results: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Lega menemukan \(fmt(m.foundTotal))", "Lega found \(fmt(m.foundTotal))"))
                        .font(.system(size: 28, weight: .bold, design: .rounded)).contentTransition(.numericText())
                    Text(tr("\(fmt(m.free)) kosong sekarang. Centang yang ingin dibersihkan.", "\(fmt(m.free)) free now. Tick what you want to clean."))
                        .foregroundStyle(m.isCritical ? .red : .secondary)
                }
                Spacer()
            }
            VStack(spacing: 0) {
                ForEach(Array(m.categories.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { Divider().padding(.leading, 52) }
                    CategoryRow(cat: c)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            if m.suggestRestart { restartLine }
            if let r = m.result { ResultChip(text: r) }
            HStack {
                PrimaryButton(title: tr("Bersihkan \(fmt(m.selectedTotal))", "Clean \(fmt(m.selectedTotal))"), symbol: "sparkles", busy: m.busy) { m.cleanSelected() }
                    .disabled(m.busy || m.selectedTotal == 0)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button(tr("Peta ruang", "Space map")) { m.pane = .map }.buttonStyle(.link)
            }
        }
        .transition(.opacity)
    }

    // 4. Selesai
    var done: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(accent)
                .symbolEffect(.bounce, value: m.phase)
            Text(tr("\(fmt(m.lastFreed + m.lastMoved)) dibereskan", "\(fmt(m.lastFreed + m.lastMoved)) cleaned up"))
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(m.lastMoved > 0
                 ? tr("\(fmt(m.lastFreed)) langsung kembali, \(fmt(m.lastMoved)) dipindah ke Trash. Sekarang \(fmt(m.free)) kosong.",
                      "\(fmt(m.lastFreed)) back right away, \(fmt(m.lastMoved)) moved to the Trash. \(fmt(m.free)) free now.")
                 : tr("Sekarang \(fmt(m.free)) kosong", "\(fmt(m.free)) free now"))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if m.trashSize > 0 {
                HStack(spacing: 12) {
                    Image(systemName: "trash").foregroundStyle(accent)
                    Text(tr("Kosongkan Trash supaya \(fmt(m.trashSize)) kembali jadi ruang kosong. Setelah itu tidak bisa dikembalikan.",
                            "Empty the Trash to turn \(fmt(m.trashSize)) back into free space. It cannot be restored after that."))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    PrimaryButton(title: tr("Kosongkan Trash", "Empty Trash")) { m.emptyTrash() }
                }
                .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.08)))
            }
            let appData = m.appDataItems.compactMap(\.size).reduce(0, +)
            if appData > 0 {
                HStack {
                    Text(tr("\(fmt(appData)) di Data aplikasi hanya bisa dirapikan lewat aplikasinya.", "\(fmt(appData)) in App data can only be tidied in the apps themselves."))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(tr("Lihat", "View")) { m.pane = .appdata }.buttonStyle(.bordered)
                }
                .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            }
            PrimaryButton(title: tr("Selesai", "Done")) { withAnimation { m.phase = .idle; m.result = nil } }
        }
        .transition(.opacity)
    }

    var restartLine: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle").foregroundStyle(.orange)
            Text(tr("Mac menyala \(uptimeText(m.uptime)). Restart mengembalikan \(fmt(m.swapBytes)) swap.", "Mac on for \(uptimeText(m.uptime)). A restart frees \(fmt(m.swapBytes)) of swap."))
                .font(.callout)
            Spacer()
            Button("Restart") { m.restartMac() }.buttonStyle(.link)
        }
    }
}

struct CategoryRow: View {
    @EnvironmentObject var m: Model
    let cat: Category

    var body: some View {
        HStack(spacing: 12) {
            if cat.id == .appdata || cat.id == .large && !cat.checkable {
                Image(systemName: "circle").foregroundStyle(.clear).frame(width: 16)
            } else {
                Toggle("", isOn: Binding(get: { m.checked.contains(cat.id) },
                                         set: { on in if on { m.checked.insert(cat.id) } else { m.checked.remove(cat.id) } }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(cat.size == 0)
            }
            IconTile(symbol: cat.symbol)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(cat.title).font(.body.weight(.medium))
                    RiskBadge(risk: cat.risk)
                }
                Text(cat.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text(fmt(cat.size)).monospacedDigit().foregroundStyle(.secondary)
            Button { m.pane = cat.id } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).help(tr("Lihat rinciannya", "See the details"))
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// MARK: - Halaman kategori, satu pola

struct CategoryPage: View {
    @EnvironmentObject var m: Model
    let id: Pane
    @AppStorage("downloadsLayout") private var layout = "list"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
                            RiskBadge(risk: risk)
                        }
                        Text(explain).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if id == .large {
                        Picker(tr("Susunan", "Arrangement"), selection: $layout) {
                            Image(systemName: "list.bullet").tag("list").help("List")
                            Image(systemName: "square.grid.2x2").tag("grid").help("Grid")
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                }
                if let r = m.result { ResultChip(text: r) }
                if m.scanningSpace && id == .leftovers { MeasuringCard() }
                content
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(.spring(response: 0.4), value: m.result)
        }
    }

    var title: String { m.categories.first { $0.id == id }?.title ?? tr("Aplikasi", "Applications") }
    var risk: Risk {
        switch id {
        case .cache, .trash: .safe
        case .appdata: .inApp
        default: .review
        }
    }
    var explain: String {
        switch id {
        case .cache: tr("Berkas sementara yang dibuat ulang sendiri. Cache aplikasi yang sedang terbuka dilewati.", "Temporary files that rebuild on their own. Caches of apps that are open are skipped.")
        case .leftovers: tr("Menghapus aplikasi hanya membuang berkas .app. Data, cache, dan model miliknya tertinggal. Lega menampilkan folder di atas 100 MB yang tidak dipakai aplikasi terpasang mana pun dan tidak berubah selama 14 hari.",
                            "Removing an app only throws away the .app file. Its data, caches and models stay behind. Lega lists folders over 100 MB that no installed app uses and that have not changed for 14 days.")
        case .trash: tr("File di Trash baru membebaskan ruang setelah dikosongkan.", "Files in the Trash only free space once it is emptied.")
        case .large: tr("Item terbesar di Downloads. Centang yang ingin ikut dibersihkan saat Clean.", "The largest items in Downloads. Tick the ones to include when you clean.")
        case .apps: tr("Aplikasi terbesar. Uninstall ikut membuang data, cache, dan pengaturannya.", "Your largest apps. Uninstalling also removes their data, caches and settings.")
        default: tr("Data besar yang aman dirapikan hanya dengan cara tertentu. Setiap tindakan meminta konfirmasi.", "Large data that is only safe to tidy in a specific way. Every action asks you first.")
        }
    }

    @ViewBuilder var content: some View {
        switch id {
        case .cache: cacheList
        case .leftovers: leftoverList
        case .trash: trashBox
        case .large: largeList
        case .apps: appList
        default: appDataList
        }
    }

    func box<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 0, content: c)
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
    }

    func empty(_ t: String) -> some View {
        Text(t).foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    var cacheList: some View {
        VStack(alignment: .leading, spacing: 16) {
            box {
                if m.visibleQuick.isEmpty { empty(tr("Semua cache sudah bersih.", "All caches are clean.")) }
                ForEach(Array(m.visibleQuick.enumerated()), id: \.element.id) { i, t in
                    if i > 0 { Divider().padding(.leading, 56) }
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
                    .padding(.horizontal, 16).padding(.vertical, 11)
                }
            }
            PrimaryButton(title: tr("Bersihkan cache \(fmt(m.quickTotal))", "Clean caches \(fmt(m.quickTotal))"), symbol: "sparkles", busy: m.busy) { m.cleanQuick() }
                .disabled(m.busy || m.quickTotal == 0)
        }
    }

    var leftoverList: some View {
        VStack(alignment: .leading, spacing: 16) {
            box {
                if m.leftovers.isEmpty && !m.scanningSpace { empty(tr("Tidak ada sisa aplikasi yang ditemukan.", "No leftovers from removed apps found.")) }
                ForEach(Array(m.leftovers.enumerated()), id: \.element.id) { i, it in
                    if i > 0 { Divider().padding(.leading, 76) }
                    CheckRow(icon: it.url.path, title: it.name, subtitle: "\(it.place)/\(it.url.lastPathComponent)", size: it.size, url: it.url,
                             on: Binding(get: { !m.leftoverSkip.contains(it.id) },
                                         set: { v in if v { m.leftoverSkip.remove(it.id) } else { m.leftoverSkip.insert(it.id) } }))
                }
            }
            HStack {
                PrimaryButton(title: tr("Pindahkan \(fmt(m.leftoverChosen.reduce(0) { $0 + $1.size })) ke Trash", "Move \(fmt(m.leftoverChosen.reduce(0) { $0 + $1.size })) to Trash"), symbol: "trash", busy: m.busy) { m.trashLeftovers() }
                    .disabled(m.busy || m.leftoverChosen.isEmpty)
                Spacer()
                Text(tr("Hilangkan centang pada data yang masih Anda butuhkan.", "Untick anything you still need.")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    var trashBox: some View {
        VStack(alignment: .leading, spacing: 16) {
            box {
                HStack(spacing: 14) {
                    IconTile(symbol: "trash")
                    Text(adv(m.adv["trash"]))
                    Spacer()
                    Text(fmt(m.trashSize)).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(16)
            }
            PrimaryButton(title: tr("Kosongkan Trash", "Empty Trash"), symbol: "trash") { m.emptyTrash() }
                .disabled(m.busy)
        }
    }
    func adv(_ v: Int64?) -> String {
        (v ?? -1) < 0 ? tr("Lega belum bisa membaca isi Trash.", "Lega cannot read the Trash yet.")
                      : tr("Isi Trash saat ini", "Currently in the Trash")
    }

    var largeList: some View {
        VStack(alignment: .leading, spacing: 16) {
            if m.downloads.isEmpty {
                box { empty(m.scanningAdv ? tr("Memindai Downloads", "Scanning Downloads") : tr("Kosong, atau Lega belum diizinkan membaca Downloads.", "Empty, or Lega has no access to Downloads yet.")) }
            } else if layout == "grid" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(m.downloads) { FileTile(item: $0) }
                }
            } else {
                box {
                    ForEach(Array(m.downloads.enumerated()), id: \.element.id) { i, f in
                        if i > 0 { Divider().padding(.leading, 76) }
                        CheckRow(icon: f.url.path, title: f.url.lastPathComponent,
                                 subtitle: f.modified.formatted(date: .abbreviated, time: .omitted), size: f.size, url: f.url,
                                 on: Binding(get: { m.largeChosen.contains(f.url.path) },
                                             set: { v in if v { m.largeChosen.insert(f.url.path); m.checked.insert(.large) } else { m.largeChosen.remove(f.url.path) } }))
                    }
                }
                Text(m.largeChosen.isEmpty ? tr("Yang dicentang ikut dibersihkan saat Anda menekan Clean di Beranda.", "Ticked items are included when you press Clean on Home.")
                                           : tr("\(m.largeChosen.count) item, \(fmt(m.largeChosenItems.reduce(0) { $0 + $1.size })), ikut dibersihkan di Beranda.", "\(m.largeChosen.count) items, \(fmt(m.largeChosenItems.reduce(0) { $0 + $1.size })), will be cleaned from Home."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    var appList: some View {
        box {
            if m.apps.isEmpty { empty(m.scanningAdv ? tr("Memindai Applications", "Scanning Applications") : tr("Belum ada aplikasi yang terbaca.", "No apps found yet.")) }
            ForEach(Array(m.apps.enumerated()), id: \.element.id) { i, f in
                if i > 0 { Divider().padding(.leading, 56) }
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable().frame(width: 30, height: 30)
                    Text(f.url.deletingPathExtension().lastPathComponent)
                    Spacer()
                    Text(fmt(f.size)).monospacedDigit().foregroundStyle(.secondary)
                    Button("Uninstall") { m.trashApp(f) }.buttonStyle(.bordered).disabled(m.busy)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
            }
        }
    }

    var appDataList: some View {
        box {
            ForEach(Array(m.appDataItems.enumerated()), id: \.element.id) { i, it in
                if i > 0 { Divider().padding(.leading, 56) }
                HStack(spacing: 14) {
                    IconTile(symbol: it.symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(it.title).font(.body.weight(.medium))
                            RiskBadge(risk: it.prominent ? .inApp : .review)
                        }
                        Text(it.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let s = it.size { Text(fmt(s)).monospacedDigit().foregroundStyle(.secondary) }
                    Button(it.button, action: it.action).buttonStyle(.bordered).disabled(!it.enabled || m.busy)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            if m.appDataItems.isEmpty { empty(tr("Tidak ada data aplikasi besar yang ditemukan.", "No large app data found.")) }
        }
    }
}

/// Baris item bercentang: ikon asli, nama, path, tombol Finder, ukuran.
struct CheckRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let size: Int64
    let url: URL
    @Binding var on: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $on).toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: icon)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass").frame(width: 24, height: 24) }
                .buttonStyle(.borderless).help(tr("Tampilkan di Finder", "Show in Finder"))
            Text(fmt(size)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}
