import SwiftUI

// THROWAWAY DESIGN PROTOTYPE. Three layouts on the existing app entry surface.
// In-memory fixtures only. Choose a direction before promoting any of this to production.
// Launch: --glass-style A|B|C [--glass-page home|discover|library|downloads|settings] [--capture]
#if DEBUG
private enum GlassDirection: String, CaseIterable, Identifiable {
    case cinema = "A", split = "B", editorial = "C"
    var id: String { rawValue }
    var title: String {
        switch self { case .cinema: "Glass Cinema"; case .split: "Split Island"; case .editorial: "Editorial" }
    }
    var subtitle: String {
        switch self { case .cinema: "Immersive artwork · Shirox-inspired dock"; case .split: "Compact navigation · Separate search"; case .editorial: "Airy shelves · A quieter glass pill" }
    }
    func next(_ step: Int) -> Self {
        let all = Self.allCases, index = Self.allCases.firstIndex(of: self)!
        return all[(index + step + all.count) % all.count]
    }
}
private enum GlassPage: String, CaseIterable, Identifiable {
    case home, discover, library, downloads, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self { case .home: "house.fill"; case .discover: "magnifyingglass"; case .library: "books.vertical.fill"; case .downloads: "arrow.down.circle.fill"; case .settings: "gearshape.fill" }
    }
}
private struct PreviewTitle: Identifiable, Hashable {
    let id: Int, name: String, image: String, genre: String, caption: String
    static let samples = [
        Self(id: 0, name: "Frieren", image: "PreviewFrieren", genre: "Fantasy", caption: "Beyond Journey’s End"),
        Self(id: 1, name: "Solo Leveling", image: "PreviewSolo", genre: "Action", caption: "Arise from the Shadow"),
        Self(id: 2, name: "DAN DA DAN", image: "PreviewDandadan", genre: "Supernatural", caption: "A little strange. A lot of heart."),
        Self(id: 3, name: "Demon Slayer", image: "PreviewDemon", genre: "Action", caption: "Infinity Castle")
    ]
}
private extension View {
    @ViewBuilder func previewGlass<S: Shape>(in shape: S) -> some View {
        // Compiles on Xcode 16 as a frosted fallback. Xcode 26+ uses native Liquid Glass
        // on iOS 26+. The earlier-OS preview is deliberately not labelled native glass.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.16), lineWidth: 0.6))
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(.white.opacity(0.16), lineWidth: 0.6))
        #endif
    }
}

struct GlassDesignPrototype: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var dockSelection
    @State private var direction: GlassDirection
    @State private var page: GlassPage
    @State private var dark = true
    @State private var chosenSource = "Animex"
    @State private var filter = "All"
    @State private var query = ""
    @State private var heroIndex = 0
    @State private var detail: PreviewTitle?
    @State private var showLiveApp = false
    @State private var showInfo = false
    private let capture = ProcessInfo.processInfo.arguments.contains("--capture")
    private let violet = Color(red: 0.73, green: 0.55, blue: 1)
    private var background: Color { dark ? Color(red: 0.035, green: 0.035, blue: 0.055) : Color(red: 0.96, green: 0.95, blue: 0.98) }
    private var ink: Color { dark ? .white : Color(red: 0.10, green: 0.08, blue: 0.16) }
    private var hero: PreviewTitle { PreviewTitle.samples[heroIndex % PreviewTitle.samples.count] }
    private var filtered: [PreviewTitle] {
        PreviewTitle.samples.filter { (filter == "All" || $0.genre == filter) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    init(style: String? = nil) {
        let args = ProcessInfo.processInfo.arguments
        func argument(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        _direction = State(initialValue: GlassDirection(rawValue: style ?? argument("--glass-style") ?? "A") ?? .cinema)
        _page = State(initialValue: GlassPage(rawValue: argument("--glass-page") ?? "home") ?? .home)
        _dark = State(initialValue: !args.contains("--light"))
    }
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                background.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 26) {
                        switch page {
                        case .home: home
                        case .discover: discovery
                        case .library: collection
                        case .downloads: downloads
                        case .settings: preferences
                        }
                    }
                    .padding(.top, page == .home && direction == .cinema ? 0 : 76)
                    .padding(.bottom, capture ? 122 : 174)
                }
                .ignoresSafeArea(edges: page == .home && direction == .cinema ? [.top, .bottom] : .bottom)
                .id("\(page.rawValue)-\(direction.rawValue)")
                VStack(spacing: 10) {
                    if !capture { prototypeSwitcher }
                    dock
                }
                .padding(.horizontal, 16).padding(.bottom, 9)
            }
            .overlay(alignment: .top) { header }
            .foregroundStyle(ink)
            .toolbar(.hidden, for: .navigationBar)
            .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.85), value: page)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: direction)
            .sheet(item: $detail) { title in detailSheet(title) }
            .sheet(isPresented: $showInfo) { designInfo }
            .fullScreenCover(isPresented: $showLiveApp) {
                RootView().overlay(alignment: .topTrailing) {
                    Button("Back to designs") { showLiveApp = false }.font(.caption.bold())
                        .padding(10).background(.regularMaterial, in: Capsule()).padding(.top, 44).padding(.trailing, 14)
                }
            }
        }
        .tint(violet)
        .preferredColorScheme(dark ? .dark : .light)
    }
    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(["Animex", "AniList", "ReAnime"], id: \.self) { source in
                    Button(source) { chosenSource = source }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("kairo").font(.system(size: 22, weight: .heavy, design: .rounded)).tracking(-0.8)
                    Text(chosenSource).font(.caption.weight(.medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 13).frame(height: 42)
                .previewGlass(in: Capsule())
            }.accessibilityLabel("Preview source: \(chosenSource)")
            Spacer(minLength: 0)
            Button { dark.toggle() } label: {
                Image(systemName: dark ? "sun.max" : "moon").frame(width: 44, height: 44)
                    .previewGlass(in: Circle())
            }.accessibilityLabel("Switch to \(dark ? "light" : "dark") mode")
            Button { page = .settings } label: {
                Image(systemName: "person.crop.circle").font(.system(size: 21)).frame(width: 44, height: 44)
                    .previewGlass(in: Circle())
            }.accessibilityLabel("Preview settings")
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 20).padding(.top, 6)
    }
    @ViewBuilder private var home: some View {
        switch direction {
        case .cinema:
            cinemaHero
            continueShelf
            posterShelf("Your next adventure", ranked: true)
            posterShelf("Made for a late night", ranked: false)
        case .split:
            VStack(alignment: .leading, spacing: 6) {
                Text("A little escape.").font(.system(size: 32, weight: .bold, design: .rounded)).tracking(-1)
                Text("Find your next favourite.").font(.subheadline).foregroundStyle(.secondary)
            }.padding(.horizontal, 22)
            splitHero
            continueShelf
            posterShelf("Popular on \(chosenSource)", ranked: false)
        case .editorial:
            VStack(alignment: .leading, spacing: 10) {
                Text("CURATED FOR YOU").font(.system(size: 10, weight: .bold)).tracking(2.8).foregroundStyle(violet)
                Text("Stories worth\nstaying up for.").font(.system(size: 39, weight: .bold, design: .serif)).tracking(-1.5)
            }.padding(.horizontal, 24)
            editorialHero
            VStack(alignment: .leading, spacing: 14) {
                sectionHeading("Pick up where you left off")
                progressRow(PreviewTitle.samples[1], episode: 7, fraction: 0.62)
                progressRow(PreviewTitle.samples[0], episode: 12, fraction: 0.35)
            }.padding(.horizontal, 22)
            posterShelf("The watchlist edit", ranked: false)
        }
    }
    private var cinemaHero: some View {
        ZStack(alignment: .bottomLeading) {
            Image(hero.image).resizable().scaledToFill().frame(height: 566).clipped()
            LinearGradient(stops: [.init(color: .black.opacity(0.36), location: 0), .init(color: .clear, location: 0.4), .init(color: .black.opacity(0.76), location: 0.76), .init(color: dark ? background : .black.opacity(0.88), location: 1)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("\(heroIndex + 1)").font(.caption.bold()).padding(5).background(violet, in: RoundedRectangle(cornerRadius: 5))
                    Text("YOUR NEXT ADVENTURE").font(.system(size: 9, weight: .bold)).tracking(2)
                }
                Text(hero.name).font(.system(size: 48, weight: .heavy, design: .rounded)).tracking(-2).lineLimit(1).minimumScaleFactor(0.65)
                Text(hero.caption).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                HStack { genreChip(hero.genre); Text("•  Sub & Dub").font(.caption).foregroundStyle(.white.opacity(0.72)) }
                HStack(spacing: 10) {
                    Button { detail = hero } label: { Label("Watch now", systemImage: "play.fill").font(.subheadline.bold()).frame(maxWidth: .infinity).frame(height: 46).background(.white, in: Capsule()).foregroundStyle(.black) }
                    Button { detail = hero } label: { Image(systemName: "plus").frame(width: 48, height: 46).previewGlass(in: Capsule()) }
                    Button { heroIndex = (heroIndex + 1) % PreviewTitle.samples.count } label: { Image(systemName: "chevron.right").frame(width: 48, height: 46).previewGlass(in: Capsule()) }.accessibilityLabel("Next featured title")
                }
                HStack(spacing: 5) {
                    ForEach(0..<PreviewTitle.samples.count, id: \.self) { index in Capsule().fill(index == heroIndex ? .white : .white.opacity(0.3)).frame(width: index == heroIndex ? 22 : 5, height: 4) }
                }.frame(maxWidth: .infinity).padding(.top, 4)
            }.padding(.horizontal, 24).padding(.bottom, 10).foregroundStyle(.white)
        }.frame(height: 566)
    }
    private var splitHero: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("IN THE SPOTLIGHT").font(.system(size: 9, weight: .heavy)).tracking(1.7).foregroundStyle(violet)
                Text("Solo\nLeveling").font(.system(size: 33, weight: .heavy, design: .rounded)).tracking(-1.3)
                Text("Arise from the Shadow").font(.caption).foregroundStyle(.secondary)
                Button { detail = PreviewTitle.samples[1] } label: {
                    Label("Explore", systemImage: "arrow.up.right").font(.subheadline.bold()).padding(.horizontal, 18).padding(.vertical, 12).background(violet, in: Capsule()).foregroundStyle(.black)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            Image("PreviewSolo").resizable().scaledToFill().frame(width: 150, height: 285).clipped()
                .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .leading, endPoint: .trailing))
        }
        .background(violet.opacity(dark ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(violet.opacity(0.16), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 28)).padding(.horizontal, 20)
    }
    private var editorialHero: some View {
        Button { detail = PreviewTitle.samples[2] } label: {
            ZStack(alignment: .bottomLeading) {
                Image("PreviewDandadan").resizable().scaledToFill().frame(height: 218).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("THE WEEKEND PICK").font(.system(size: 9, weight: .bold)).tracking(2)
                        Text("DAN DA DAN").font(.system(size: 27, weight: .heavy, design: .rounded))
                    }
                    Spacer()
                    Image(systemName: "play.fill").frame(width: 46, height: 46).previewGlass(in: Circle())
                }.foregroundStyle(.white).padding(20)
            }.frame(height: 218).clipShape(RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain).padding(.horizontal, 22)
    }
    private var continueShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Continue watching").padding(.horizontal, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach([PreviewTitle.samples[1], PreviewTitle.samples[0]]) { title in
                        Button { detail = title } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                ZStack(alignment: .bottom) {
                                    Image(title.image).resizable().scaledToFill().frame(width: 242, height: 126).clipped()
                                    LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                                    Image(systemName: "play.fill").font(.system(size: 18)).frame(width: 40, height: 40).previewGlass(in: Circle()).frame(maxHeight: .infinity)
                                    GeometryReader { geo in Rectangle().fill(violet).frame(width: geo.size.width * 0.62) }.frame(height: 3)
                                }.frame(width: 242, height: 126).clipShape(RoundedRectangle(cornerRadius: 17))
                                Text(title.name).font(.subheadline.weight(.semibold))
                                Text("Episode \(title.id == 1 ? 7 : 12) · 9 min left").font(.caption).foregroundStyle(.secondary)
                            }.frame(width: 242, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 22)
            }
        }
    }
    private func posterShelf(_ title: String, ranked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(title).padding(.horizontal, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: ranked ? 18 : 12) {
                    ForEach(Array(PreviewTitle.samples.enumerated()), id: \.element.id) { index, sample in
                        Button { detail = sample } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(sample.image).resizable().scaledToFill().frame(width: ranked ? 126 : 118, height: ranked ? 178 : 166).clipped().clipShape(RoundedRectangle(cornerRadius: 15))
                                    .overlay(alignment: .bottomLeading) {
                                        if ranked { Text("\(index + 1)").font(.system(size: 48, weight: .black, design: .rounded)).foregroundStyle(.white).shadow(color: .black.opacity(0.8), radius: 4).offset(x: -7, y: 7) }
                                    }
                                Text(sample.name).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(sample.genre).font(.system(size: 10)).foregroundStyle(.secondary)
                            }.frame(width: ranked ? 126 : 118, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 22)
            }
        }
    }
    private func sectionHeading(_ title: String) -> some View {
        HStack { Text(title).font(.system(size: 20, weight: .bold, design: .rounded)).tracking(-0.4); Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
    }
    private func genreChip(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 5).background(.white.opacity(0.14), in: Capsule())
    }
    private func progressRow(_ title: PreviewTitle, episode: Int, fraction: Double) -> some View {
        Button { detail = title } label: {
            HStack(spacing: 14) {
                Image(title.image).resizable().scaledToFill().frame(width: 68, height: 88).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 8) {
                    Text(title.name).font(.subheadline.bold())
                    Text("Episode \(episode) · Continue").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: fraction).tint(violet)
                }
                Image(systemName: "play.fill").font(.caption).frame(width: 42, height: 42).previewGlass(in: Circle())
            }
        }.buttonStyle(.plain)
    }
    private var discovery: some View {
        VStack(alignment: .leading, spacing: 24) {
            titleBlock("Discover", caption: "A new story is one search away.")
            HStack { Image(systemName: "magnifyingglass"); TextField("Search \(chosenSource)", text: $query) }.padding(16).previewGlass(in: RoundedRectangle(cornerRadius: 19)).padding(.horizontal, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["All", "Action", "Fantasy", "Supernatural"], id: \.self) { value in
                        Button { filter = value } label: {
                            Text(value).font(.caption.bold()).padding(.horizontal, 17).frame(height: 38)
                                .background(filter == value ? violet : violet.opacity(0.08), in: Capsule()).foregroundStyle(filter == value ? .black : ink)
                        }
                    }
                }.padding(.horizontal, 22)
            }
            if filtered.isEmpty { ContentUnavailableView.search(text: query).padding(.top, 30) }
            else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                    ForEach(filtered) { title in
                        Button { detail = title } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Image(title.image).resizable().scaledToFill().frame(height: 234).clipped().clipShape(RoundedRectangle(cornerRadius: 20))
                                Text(title.name).font(.subheadline.bold()).lineLimit(1)
                                Text("\(title.genre) · Sub & Dub").font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 22)
            }
        }
    }
    private var collection: some View {
        VStack(alignment: .leading, spacing: 26) {
            titleBlock("Your library", caption: "Every world you want to come back to.")
            HStack { Text("Watching").foregroundStyle(violet); Text("Watchlist"); Text("Finished") }.font(.subheadline.weight(.semibold)).padding(.horizontal, 22)
            VStack(spacing: 20) {
                ForEach(PreviewTitle.samples) { title in progressRow(title, episode: title.id + 3, fraction: 0.3 + Double(title.id) * 0.15) }
            }.padding(20).background(violet.opacity(0.055), in: RoundedRectangle(cornerRadius: 26)).padding(.horizontal, 20)
            posterShelf("Saved for later", ranked: false)
        }
    }
    private var downloads: some View {
        VStack(alignment: .leading, spacing: 24) {
            titleBlock("Take it with you.", caption: "Your downloads, beautifully in order.")
            HStack(spacing: 14) {
                Image(systemName: "internaldrive").font(.title2).foregroundStyle(violet)
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text("On this iPhone").font(.subheadline.bold()); Spacer(); Text("43.7 GB free").font(.caption).foregroundStyle(.secondary) }
                    ProgressView(value: 0.28).tint(violet)
                    Text("3 episodes · 1.2 GB").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18).previewGlass(in: RoundedRectangle(cornerRadius: 24)).padding(.horizontal, 22)
            VStack(alignment: .leading, spacing: 14) {
                sectionHeading("Ready for anywhere")
                ForEach(1..<4) { number in
                    HStack(spacing: 14) {
                        Image("PreviewSolo").resizable().scaledToFill().frame(width: 82, height: 62).clipped().clipShape(RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Episode \(number)").font(.subheadline.bold())
                            Text("Solo Leveling · Dub · 1080p").font(.caption).foregroundStyle(.secondary)
                            if number == 2 { ProgressView(value: 0.62).tint(violet) }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(violet)
                    }.padding(.vertical, 8)
                }
            }.padding(.horizontal, 22)
        }
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 24) {
            titleBlock("Make it yours.", caption: "Simple controls. A calmer experience.")
            VStack(spacing: 0) {
                HStack { Label("Dark appearance", systemImage: "moon"); Spacer(); Toggle("Dark appearance", isOn: $dark).labelsHidden() }.padding(20)
                Divider().padding(.horizontal, 20)
                HStack { Label("Source", systemImage: "square.stack.3d.up"); Spacer(); Text(chosenSource).foregroundStyle(.secondary) }.padding(20)
                Divider().padding(.horizontal, 20)
                HStack { Label("Preferred audio", systemImage: "waveform"); Spacer(); Text("English dub").foregroundStyle(.secondary) }.padding(20)
            }.font(.subheadline).previewGlass(in: RoundedRectangle(cornerRadius: 26)).padding(.horizontal, 22)
            VStack(alignment: .leading, spacing: 14) {
                Text("Design playground").font(.headline)
                ForEach(GlassDirection.allCases) { style in
                    Button { direction = style } label: {
                        HStack { VStack(alignment: .leading, spacing: 5) { Text("\(style.rawValue) · \(style.title)").font(.subheadline.bold()); Text(style.subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); if direction == style { Image(systemName: "checkmark.circle.fill").foregroundStyle(violet) } }
                    }.buttonStyle(.plain).padding(.vertical, 8)
                }
                Button("Open the real Kairo app") { showLiveApp = true }.buttonStyle(.bordered)
                Text("Sample titles and progress are for comparing layouts. These screens do not start streams or change your library.").font(.caption).foregroundStyle(.secondary)
            }.padding(20).background(violet.opacity(0.06), in: RoundedRectangle(cornerRadius: 26)).padding(.horizontal, 22)
        }
    }
    private func titleBlock(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: direction == .editorial ? 36 : 31, weight: .bold, design: direction == .editorial ? .serif : .rounded)).tracking(-1)
            Text(caption).font(.subheadline).foregroundStyle(.secondary)
        }.padding(.horizontal, 22)
    }
    private var prototypeSwitcher: some View {
        HStack(spacing: 10) {
            Button { direction = direction.next(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }.accessibilityLabel("Previous design")
            Button { showInfo = true } label: {
                VStack(spacing: 2) {
                    Text("DESIGN PREVIEW").font(.system(size: 7, weight: .heavy)).tracking(1.5).foregroundStyle(.secondary)
                    Text("\(direction.rawValue) · \(direction.title)").font(.system(size: 11, weight: .bold))
                }.frame(minWidth: 110)
            }
            Button { direction = direction.next(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }.accessibilityLabel("Next design")
        }.padding(.horizontal, 3).background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(violet.opacity(0.3), lineWidth: 0.7)).shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
    @ViewBuilder private var dock: some View {
        if direction == .cinema {
            HStack(spacing: 10) {
                HStack(spacing: 0) { ForEach([GlassPage.home, .library, .downloads, .settings]) { item in dockItem(item, labels: true) } }
                    .padding(6).previewGlass(in: Capsule())
                Button { page = .discover } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .medium)).foregroundStyle(page == .discover ? violet : ink)
                        .frame(width: 58, height: 58).previewGlass(in: Circle())
                }.accessibilityLabel("Discover")
            }.frame(maxWidth: 440).shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        } else if direction == .split {
            HStack(spacing: 12) {
                HStack(spacing: 2) { ForEach([GlassPage.home, .library, .downloads]) { item in dockItem(item, labels: false) } }
                    .padding(7).previewGlass(in: Capsule())
                Button { page = .discover } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 23, weight: .medium)).frame(width: 60, height: 60).background(violet.opacity(0.14), in: Circle()).previewGlass(in: Circle())
                }.accessibilityLabel("Discover")
            }.fixedSize(horizontal: true, vertical: false).shadow(color: .black.opacity(0.2), radius: 18, y: 8)
        } else {
            HStack(spacing: 0) { ForEach(GlassPage.allCases) { item in dockItem(item, labels: true) } }
                .padding(6).previewGlass(in: Capsule()).frame(maxWidth: 440).shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        }
    }
    private func dockItem(_ item: GlassPage, labels: Bool) -> some View {
        Button { page = item } label: {
            VStack(spacing: 4) {
                Image(systemName: item.icon).font(.system(size: labels ? 19 : 21, weight: .semibold))
                if labels { Text(item.title).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .foregroundStyle(page == item ? violet : ink.opacity(0.64))
            .frame(maxWidth: labels ? .infinity : nil).frame(width: labels ? nil : 58, height: 46)
            .background {
                if page == item { Capsule().fill(violet.opacity(dark ? 0.16 : 0.13)).matchedGeometryEffect(id: "selected", in: dockSelection) }
            }
            .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel(item.title).accessibilityAddTraits(page == item ? .isSelected : [])
    }
    private func detailSheet(_ title: PreviewTitle) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(title.image).resizable().scaledToFill().frame(height: 300).clipped().overlay(alignment: .bottom) { LinearGradient(colors: [.clear, background], startPoint: .top, endPoint: .bottom).frame(height: 140) }
                    VStack(alignment: .leading, spacing: 18) {
                        Text(title.name).font(.system(size: 34, weight: .heavy, design: .rounded))
                        Text(title.caption).foregroundStyle(.secondary)
                        HStack { genreChip(title.genre); genreChip("Sub & Dub"); genreChip("HD") }
                        Text("Episodes").font(.title2.bold())
                        ForEach(1..<5) { number in
                            HStack(spacing: 13) {
                                Image(title.image).resizable().scaledToFill().frame(width: 100, height: 64).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 6) { Text("Episode \(number)").font(.subheadline.bold()); Text(number == 2 ? "Continue · 9 min left" : "24 min · Preview").font(.caption).foregroundStyle(.secondary) }
                                Spacer(); Image(systemName: number == 1 ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(violet)
                            }.padding(.vertical, 5)
                        }
                        Text("Design sample: episode imagery, titles and progress are fixtures. Playback and downloading are available in the real Kairo app.").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 24).padding(.bottom, 30)
                }
            }.background(background).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { detail = nil } } }
        }.preferredColorScheme(dark ? .dark : .light)
    }
    private var designInfo: some View {
        NavigationStack {
            List {
                Section("Compare the options") {
                    ForEach(GlassDirection.allCases) { style in Button { direction = style; showInfo = false } label: { VStack(alignment: .leading, spacing: 6) { Text("\(style.rawValue) · \(style.title)").font(.headline); Text(style.subtitle).font(.caption).foregroundStyle(.secondary) } } }
                }
                Section("Try it") { Text("Tap the floating tabs, search and filter in Discover, open a title, change the source label, and use the sun/moon button to compare light and dark.") }
                Section("Glass appearance") { Text("Native Liquid Glass uses Xcode 26+ and iOS 26+. Earlier systems use a translucent material fallback with the same floating layout.") }
                Section { Button("Open real Kairo") { showInfo = false; showLiveApp = true } }
            }.navigationTitle("Design playground").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showInfo = false } } }
        }.preferredColorScheme(dark ? .dark : .light)
    }
}

#Preview("A · Glass Cinema") { GlassDesignPrototype(style: "A") }
#Preview("B · Split Island") { GlassDesignPrototype(style: "B") }
#Preview("C · Editorial") { GlassDesignPrototype(style: "C") }
#endif
