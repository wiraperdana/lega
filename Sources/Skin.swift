// Skin: tema warna Lega. Satu skin mengganti token warna (accent, gradien latar, gradien lingkaran)
// untuk mode terang dan gelap sekaligus. Merah, oranye, dan abu-abu untuk peringatan tidak ikut skin,
// supaya peringatan tetap terbaca sama di skin apa pun.
// Lisensi MIT. Lihat LICENSE.

import SwiftUI
import AppKit

enum Skin: String, CaseIterable, Identifiable {
    case sage, ocean, sunrise, forest, graphite
    var id: String { rawValue }

    static var current: Skin { Skin(rawValue: UserDefaults.standard.string(forKey: "skin") ?? "sage") ?? .sage }

    var name: String {
        switch self {
        case .sage: "Sage"
        case .ocean: tr("Samudra", "Ocean")
        case .sunrise: tr("Fajar", "Sunrise")
        case .forest: tr("Hutan", "Forest")
        case .graphite: tr("Grafit", "Graphite")
        }
    }

    /// Warna utama: tombol, centang, lingkaran. Versi gelap sedikit lebih terang supaya kontrasnya cukup.
    var accent: Color {
        switch self {
        case .sage: dyn(0x0E8F80, 0x34B3A2)
        case .ocean: dyn(0x1F6FB2, 0x4A9BE0)
        case .sunrise: dyn(0xC2620F, 0xF0A04B)
        case .forest: dyn(0x2F6B3A, 0x7DB56A)
        case .graphite: dyn(0x3C4148, 0xC9CDD3)
        }
    }

    /// Gradien untuk lingkaran ruang dan tombol Scan.
    var ring: [Color] {
        switch self {
        case .sage: [hex(0x0E8F80), hex(0x6CCB9F)]
        case .ocean: [hex(0x1F6FB2), hex(0x5CC6E0)]
        case .sunrise: [hex(0xE0702A), hex(0xF4C25B)]
        case .forest: [hex(0x2F6B3A), hex(0xC9A94A)]
        case .graphite: [hex(0x5B616A), hex(0xB4BAC2)]
        }
    }

    /// Sembilan warna MeshGradient 3x3 untuk latar jendela.
    func mesh(dark: Bool) -> [Color] {
        let (a, b, c): (UInt32, UInt32, UInt32) = switch (self, dark) {
        case (.sage, false): (0xEEF6F2, 0xD9EFE6, 0xF7FAF8)
        case (.sage, true): (0x0F1A18, 0x12302B, 0x0B1211)
        case (.ocean, false): (0xEDF4FA, 0xD6E8F6, 0xF6FAFD)
        case (.ocean, true): (0x0D1622, 0x0F2A44, 0x0A0F17)
        case (.sunrise, false): (0xFBF3EA, 0xF8E2CB, 0xFDF9F4)
        case (.sunrise, true): (0x1C140E, 0x3A2412, 0x120D09)
        case (.forest, false): (0xF0F4EC, 0xDFE9D6, 0xF8F8F1)
        case (.forest, true): (0x0E150F, 0x1D2E19, 0x0A0E09)
        case (.graphite, false): (0xF4F5F6, 0xE6E8EB, 0xFAFAFB)
        case (.graphite, true): (0x141517, 0x22252A, 0x0E0F10)
        }
        return [a, c, b, c, a, c, b, c, a].map(hex)
    }

    /// Ilustrasi khas skin, hanya untuk Beranda saat idle.
    var art: NSImage? {
        Bundle.main.url(forResource: rawValue, withExtension: "jpg", subdirectory: "Skins").flatMap(NSImage.init(contentsOf:))
    }
}

private func hex(_ v: UInt32) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

private func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    func ns(_ v: UInt32) -> NSColor {
        NSColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    return Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
    })
}

/// Latar jendela: MeshGradient yang bergerak pelan, seperti bernapas.
struct SkinBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        let s = Skin.current
        let d: Float = breathe ? 0.08 : -0.06
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.5 + d, 0.5 - d], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: s.mesh(dark: scheme == .dark))
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// Ilustrasi skin di belakang lingkaran Beranda, samar dan memudar ke tepi.
struct SkinArt: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if let img = Skin.current.art {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 560, height: 360)
                .blur(radius: 2)
                .opacity(scheme == .dark ? 0.22 : 0.6)
                .mask(EllipticalGradient(colors: [.black, .clear], center: .center, startRadiusFraction: 0.05, endRadiusFraction: 0.5))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Pemilih skin: lingkaran warna yang bisa diklik, dengan nama saat kursor di atasnya.
struct SkinPicker: View {
    @AppStorage("skin") private var skin = "sage"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ForEach(Skin.allCases) { s in
                    Button { skin = s.rawValue } label: {
                        Circle()
                            .fill(LinearGradient(colors: s.ring, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.primary.opacity(skin == s.rawValue ? 0.9 : 0.12), lineWidth: skin == s.rawValue ? 2.5 : 1).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(s.name)
                    .accessibilityLabel(s.name)
                    .accessibilityAddTraits(skin == s.rawValue ? .isSelected : [])
                }
                Text(Skin(rawValue: skin)?.name ?? "").foregroundStyle(.secondary)
            }
            Text(tr("Mengubah warna Lega. Warna peringatan tetap sama supaya mudah dikenali.",
                    "Changes the colors of Lega. Warnings keep their own colors so they stay easy to spot."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
