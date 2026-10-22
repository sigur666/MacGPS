import AppKit
import SwiftUI

/// The app icons bundled in Contents/Resources (rendered from Icons/svg by Icons/render.swift).
enum AppIcon: String, CaseIterable, Identifiable {
    case skyplot = "1-skyplot"
    case satellite = "2-satellite"
    case pin = "3-pin"
    case radar = "4-radar"
    case globe = "5-globe"
    case crosshair = "6-crosshair"

    static let `default` = AppIcon.skyplot
    var id: String { rawValue }

    var title: String {
        switch self {
        case .skyplot: return "Sky View"
        case .satellite: return "Satellite"
        case .pin: return "Location Pin"
        case .radar: return "Radar"
        case .globe: return "Globe"
        case .crosshair: return "Crosshair"
        }
    }

    var image: NSImage? {
        if let url = Bundle.main.url(forResource: "icon-\(rawValue)", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        // `swift run` without an app bundle: use the repository's rendered PNGs
        return NSImage(contentsOfFile: "Icons/png/\(rawValue).png")
    }

    /// Sets the Dock icon of the running app.
    func apply() {
        NSApp.applicationIconImage = image
    }
}

struct IconSettingsView: View {
    @AppStorage("appIcon") private var selected = AppIcon.default.rawValue
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("App Icon").font(.title2.weight(.semibold))
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(AppIcon.allCases) { icon in
                    Button {
                        selected = icon.rawValue
                        icon.apply()
                    } label: {
                        VStack(spacing: 6) {
                            if let img = icon.image {
                                Image(nsImage: img).resizable().frame(width: 96, height: 96)
                            }
                            Text(icon.title).font(.callout)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .fill(selected == icon.rawValue ? Color.accentColor.opacity(0.18) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(selected == icon.rawValue ? Color.accentColor : .clear, lineWidth: 2))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("App icon \(icon.title)")
                    .accessibilityAddTraits(selected == icon.rawValue ? .isSelected : [])
                }
            }
            Text("Applies to the Dock immediately. The Finder icon is set by build-app.sh: ICON=\(selected) ./build-app.sh")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(20)
        .frame(width: 480)
    }
}
