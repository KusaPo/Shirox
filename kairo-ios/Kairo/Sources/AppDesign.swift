import SwiftUI

enum AppDesign: String, CaseIterable, Identifiable {
    case cinema, split, editorial
    var id: String { rawValue }
    var title: String {
        switch self { case .cinema: "Glass Cinema"; case .split: "Split Island"; case .editorial: "Editorial" }
    }
    var subtitle: String {
        switch self {
        case .cinema: "Immersive artwork and a floating glass dock"
        case .split: "Compact spotlight and a smaller navigation island"
        case .editorial: "Quiet typography and a single navigation pill"
        }
    }
}

extension View {
    @ViewBuilder func kairoGlass<S: Shape>(in shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.16), lineWidth: 0.6).allowsHitTesting(false))
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(.white.opacity(0.16), lineWidth: 0.6).allowsHitTesting(false))
        #endif
    }
}

struct GlassNavigationDock: View {
    @Binding var selection: KairoTab
    let design: AppDesign
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tabs: [KairoTab] {
        switch design {
        case .cinema: [.home, .library, .downloads, .settings]
        case .split: [.home, .library, .downloads]
        case .editorial: [.home, .discover, .library, .downloads, .settings]
        }
    }
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.self) { tab in item(tab, compact: design == .split) }
            }.padding(6).kairoGlass(in: Capsule())
            if design != .editorial {
                item(.discover, compact: true).frame(width: 44).padding(6).kairoGlass(in: Circle())
            }
        }
        .frame(maxWidth: design == .split ? 286 : 600)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
    private func item(_ tab: KairoTab, compact: Bool) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) { selection = tab }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.icon).font(.system(size: 21, weight: .semibold))
                if !compact { Text(tab.title).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75) }
            }
            .frame(maxWidth: .infinity).frame(minWidth: 35, minHeight: 44)
            .padding(.horizontal, 3)
            .foregroundStyle(selection == tab ? Theme.purple : Color.secondary)
            .background {
                if selection == tab {
                    Capsule().fill(Theme.purple.opacity(0.18)).matchedGeometryEffect(id: "selected", in: highlight)
                }
            }
        }.buttonStyle(.plain).accessibilityLabel(tab.title)
            .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}

extension KairoTab {
    var title: String {
        switch self { case .home: "Home"; case .discover: "Discover"; case .library: "Library"; case .downloads: "Downloads"; case .settings: "Settings" }
    }
    var icon: String {
        switch self { case .home: "house.fill"; case .discover: "magnifyingglass"; case .library: "books.vertical.fill"; case .downloads: "arrow.down.circle.fill"; case .settings: "gearshape.fill" }
    }
}
