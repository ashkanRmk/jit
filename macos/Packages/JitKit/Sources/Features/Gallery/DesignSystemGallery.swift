#if DEBUG
    import AppKit
    import DesignSystem
    import SwiftUI

    /// Debug-only design review surface: every token and the glass usage rules, in the window's
    /// current appearance. Not compiled into release builds.
    public struct DesignSystemGallery: View {
        enum Section: String, CaseIterable, Identifiable {
            case surfaces = "Surfaces & Text"
            case accent = "Accent & Status"
            case diff = "Diff"
            case lanes = "Lanes"
            case typography = "Typography"
            case metrics = "Spacing & Radii"
            case states = "Interactive States"
            case glass = "Glass Rules"
            case motion = "Motion"

            var id: String { rawValue }

            var symbol: String {
                switch self {
                case .surfaces: "square.stack.3d.up"
                case .accent: "paintpalette"
                case .diff: "plus.forwardslash.minus"
                case .lanes: "point.3.connected.trianglepath.dotted"
                case .typography: "textformat"
                case .metrics: "ruler"
                case .states: "cursorarrow.click.2"
                case .glass: "square.on.square.intersection.dashed"
                case .motion: "wind"
                }
            }
        }

        enum AppearanceChoice: String, CaseIterable, Identifiable {
            case system = "System", light = "Light", dark = "Dark"
            var id: String { rawValue }
            var scheme: ColorScheme? {
                switch self {
                case .system: nil
                case .light: .light
                case .dark: .dark
                }
            }
        }

        @State private var selection: Section? =
            UserDefaults.standard.string(forKey: "JitGallerySection").flatMap { name in
                Section.allCases.first { "\($0)" == name }
            } ?? .surfaces
        @State private var appearance: AppearanceChoice = .system
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        public init() {}

        public var body: some View {
            NavigationSplitView {
                List(Section.allCases, selection: $selection) { section in
                    Label(section.rawValue, systemImage: section.symbol).tag(section)
                }
                .navigationSplitViewColumnWidth(
                    min: PanelMetrics.sidebarMin, ideal: PanelMetrics.sidebarDefault, max: PanelMetrics.sidebarMax)
            } detail: {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s9) {
                        settingsNote
                        detail(for: selection ?? .surfaces)
                    }
                    .padding(Space.s9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .background(ColorToken.surfaceCanvas.color)
                .navigationTitle(selection?.rawValue ?? "Design System")
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Force the gallery window's appearance")
                }
            }
            .preferredColorScheme(appearance.scheme)
        }

        private var settingsNote: some View {
            HStack(spacing: Space.s6) {
                SettingBadge(name: "Reduce Transparency", isOn: reduceTransparency)
                SettingBadge(name: "Increase Contrast", isOn: contrast == .increased)
                SettingBadge(name: "Reduce Motion", isOn: reduceMotion)
            }
        }

        @ViewBuilder private func detail(for section: Section) -> some View {
            switch section {
            case .surfaces: SurfacesSection()
            case .accent: AccentSection()
            case .diff: DiffSection()
            case .lanes: LanesSection()
            case .typography: TypographySection()
            case .metrics: MetricsSection()
            case .states: StatesSection()
            case .glass: GlassRulesSection()
            case .motion: MotionSection()
            }
        }
    }

    // MARK: - Building blocks

    private struct SettingBadge: View {
        let name: String
        let isOn: Bool

        var body: some View {
            HStack(spacing: Space.s2) {
                Circle().fill(isOn ? ColorToken.statusSuccess.color : ColorToken.borderStrong.color)
                    .frame(width: 6, height: 6)
                Text("\(name): \(isOn ? "On" : "Off")")
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textSecondary))
            }
            .accessibilityElement(children: .combine)
        }
    }

    struct GallerySection<Content: View>: View {
        let title: String
        let note: String?
        let content: Content

        init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
            self.title = title
            self.note = note
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: Space.s5) {
                Text(title).typeStyle(.micro).foregroundStyle(.token(.textTertiary))
                if let note {
                    Text(note).typeStyle(.callout).foregroundStyle(.token(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
        }
    }

    private struct Swatch: View {
        let token: ColorToken

        var body: some View {
            VStack(alignment: .leading, spacing: Space.s3) {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(token.color)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .strokeBorder(ColorToken.borderSubtle.color, lineWidth: Border.hairline)
                    )
                    .frame(height: 44)
                Text(token.rawValue).typeStyle(.monoCaption).foregroundStyle(.token(.textSecondary))
            }
        }
    }

    // MARK: - Sections

    private struct SurfacesSection: View {
        let surfaces: [ColorToken] = [.surfaceSunken, .surfaceCanvas, .surfacePanel, .surfaceRaised]
        let texts: [ColorToken] = [.textPrimary, .textSecondary, .textTertiary, .textDisabled]

        var body: some View {
            GallerySection(
                "Content surfaces",
                note: "Hierarchy by luminance (2–4 %), hairlines only where equal surfaces meet. Opaque — never glass."
            ) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Space.s6)], spacing: Space.s6) {
                    ForEach(surfaces + [.surfaceChromeOpaque, .borderSubtle, .borderStrong], id: \.self) {
                        Swatch(token: $0)
                    }
                }
            }
            GallerySection("Text on each surface") {
                VStack(spacing: Space.s4) {
                    ForEach(surfaces, id: \.self) { surface in
                        HStack(spacing: Space.s7) {
                            Text(surface.rawValue).typeStyle(.monoCaption).foregroundStyle(.token(.textTertiary))
                                .frame(width: 130, alignment: .leading)
                            ForEach(texts, id: \.self) { text in
                                Text(text.rawValue.replacingOccurrences(of: "text.", with: "").capitalized)
                                    .typeStyle(.body)
                                    .foregroundStyle(text.color)
                            }
                            Spacer()
                        }
                        .padding(Space.s5)
                        .background(surface.color, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    }
                }
            }
        }
    }

    private struct AccentSection: View {
        var body: some View {
            GallerySection("Accent") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Space.s6)], spacing: Space.s6) {
                    ForEach([ColorToken.accentBase, .accentTint, .accentMuted, .accentOnAccent], id: \.self) {
                        Swatch(token: $0)
                    }
                }
            }
            GallerySection(
                "Selection: Tidewater vs system accent",
                note: "Change the system accent in System Settings ▸ Appearance to compare."
            ) {
                HStack(alignment: .top, spacing: Space.s8) {
                    SelectionSample(
                        title: "Tidewater 12 % — rejected", fill: ColorToken.accentMuted.color,
                        edge: ColorToken.accentBase.color)
                    SelectionSample(
                        title: "System accent (Selection) — chosen", fill: Selection.fill,
                        edge: Selection.edge)
                }
                HStack(spacing: Space.s6) {
                    Button("Tidewater primary") {}.primaryGlassButton().controlSize(.large)
                    Button("System prominent") {}.untintedProminentGlassButton().controlSize(.large)
                    Button("Secondary") {}.secondaryGlassButton().controlSize(.large)
                }
            }
            GallerySection("Status") {
                HStack(spacing: Space.s8) {
                    ForEach(
                        [
                            (ColorToken.statusSuccess, "checkmark.circle.fill", "Success"),
                            (.statusWarning, "exclamationmark.triangle.fill", "Warning"),
                            (.statusDanger, "xmark.octagon.fill", "Danger"),
                            (.statusInfo, "info.circle.fill", "Info"),
                        ], id: \.0
                    ) { token, symbol, name in
                        Label {
                            Text(name).typeStyle(.body).foregroundStyle(.token(.textPrimary))
                        } icon: {
                            Image(systemName: symbol).foregroundStyle(token.color)
                        }
                    }
                }
            }
        }
    }

    private struct SelectionSample: View {
        let title: String
        let fill: Color
        let edge: Color

        var body: some View {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(title).typeStyle(.caption).foregroundStyle(.token(.textTertiary))
                VStack(spacing: 0) {
                    ForEach(0..<4) { index in
                        HStack {
                            Text(["main", "feature/graph", "release/1.0", "fix/crash"][index]).typeStyle(.body)
                                .foregroundStyle(.token(.textPrimary))
                            Spacer()
                        }
                        .padding(.horizontal, Space.s5)
                        .frame(height: Density.comfortable.rowHeight)
                        .background {
                            if index == 1 {
                                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(fill)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(edge).frame(width: 2).padding(.vertical, Space.s2)
                                    }
                            }
                        }
                    }
                }
                .padding(Space.s3)
                .frame(width: 240)
                .background(
                    ColorToken.surfacePanel.color, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
        }
    }

    private struct DiffSection: View {
        let lines: [(String, String, ColorToken?, ColorToken?)] = [
            (" ", "func discover(at path: String) async throws {", nil, nil),
            ("-", "    let output = try run(arguments)", .diffDeleteBackground, .diffDeleteMark),
            ("+", "    let output = try await run(arguments, timeout: .seconds(15))", .diffAddBackground, .diffAddMark),
            (" ", "    return parse(output)", nil, nil),
        ]

        var body: some View {
            GallerySection("Diff colors (sample lines)") {
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: Space.s4) {
                            Text(line.0).typeStyle(.monoBody)
                                .foregroundStyle(line.3?.color ?? ColorToken.textTertiary.color)
                                .frame(width: 14)
                            Text(line.1).typeStyle(.monoBody).foregroundStyle(.token(.textPrimary))
                            Spacer()
                        }
                        .padding(.horizontal, Space.s5)
                        .frame(height: 20)
                        .background(line.2?.color ?? ColorToken.surfaceRaised.color)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(ColorToken.borderSubtle.color, lineWidth: Border.hairline))
            }
        }
    }

    private struct LanesSection: View {
        var body: some View {
            GallerySection(
                "Lane palette",
                note: "Equal perceived lightness per theme; ≥ 3:1 on surface.canvas (tested). Content layer only."
            ) {
                HStack(spacing: Space.s5) {
                    ForEach(LaneColor.allCases, id: \.self) { lane in
                        VStack(spacing: Space.s3) {
                            Circle().fill(lane.color).frame(width: 22, height: 22)
                            Text(lane.name).typeStyle(.caption).foregroundStyle(.token(.textSecondary))
                        }
                    }
                }
            }
            GallerySection("Mini graph") {
                MiniGraph()
                    .frame(height: 180)
                    .background(ColorToken.surfaceCanvas.color)
            }
        }
    }

    struct MiniGraph: View {
        var body: some View {
            Canvas { context, size in
                let rowHeight: CGFloat = 22
                let laneWidth: CGFloat = 16
                let rows = Int(size.height / rowHeight)
                for lane in 0..<4 {
                    let x = Space.s6 + CGFloat(lane) * laneWidth
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: rowHeight * CGFloat(lane)))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(LaneColor.allCases[lane].color), lineWidth: 2)
                }
                for row in 0..<rows {
                    let lane = (row * 3) % 4
                    let center = CGPoint(
                        x: Space.s6 + CGFloat(lane) * laneWidth, y: rowHeight * CGFloat(row) + rowHeight / 2)
                    let dot = Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
                    context.fill(dot, with: .color(ColorToken.surfaceCanvas.color))
                    context.stroke(dot, with: .color(LaneColor.allCases[lane].color), lineWidth: 2)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private struct TypographySection: View {
        var body: some View {
            GallerySection("Type scale") {
                VStack(alignment: .leading, spacing: Space.s5) {
                    ForEach(TypeToken.allCases, id: \.self) { token in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s7) {
                            Text("\(token.rawValue)  \(Int(token.size))/\(Int(token.lineHeight))")
                                .typeStyle(.monoCaption).foregroundStyle(.token(.textTertiary))
                                .frame(width: 200, alignment: .leading)
                            Text(
                                token.isMonospaced
                                    ? "9fceb02d0ae598e95dc970b74767f19372d61af8" : "Refine the commit graph"
                            )
                            .typeStyle(token)
                            .foregroundStyle(.token(.textPrimary))
                        }
                    }
                    Text("Counts use monospaced digits: 1,204 commits · 38 files")
                        .typeStyle(.body).monospacedDigit().foregroundStyle(.token(.textSecondary))
                }
            }
        }
    }

    private struct MetricsSection: View {
        var body: some View {
            GallerySection("Spacing (4 pt grid)") {
                VStack(alignment: .leading, spacing: Space.s3) {
                    ForEach(Space.all, id: \.0) { name, value in
                        HStack(spacing: Space.s5) {
                            Text("\(name) = \(Int(value))").typeStyle(.monoCaption).foregroundStyle(
                                .token(.textTertiary)
                            )
                            .frame(width: 120, alignment: .leading)
                            Rectangle().fill(ColorToken.accentBase.color).frame(width: value, height: 10)
                        }
                    }
                }
            }
            GallerySection(
                "Radii, nested concentrically",
                note: "Each inner shape uses Radius.concentric(outer:inset:)."
            ) {
                HStack(spacing: Space.s8) {
                    ForEach(Radius.all, id: \.0) { name, value in
                        VStack(spacing: Space.s3) {
                            RoundedRectangle(cornerRadius: value, style: .continuous)
                                .fill(ColorToken.surfaceRaised.color)
                                .overlay(
                                    RoundedRectangle(cornerRadius: value, style: .continuous)
                                        .strokeBorder(ColorToken.borderStrong.color, lineWidth: Border.hairline)
                                )
                                .overlay(
                                    RoundedRectangle(
                                        cornerRadius: Radius.concentric(outer: value, inset: Space.s3),
                                        style: .continuous
                                    )
                                    .fill(ColorToken.accentMuted.color)
                                    .padding(Space.s3)
                                )
                                .frame(width: 72, height: 52)
                            Text("\(name) \(Int(value))").typeStyle(.monoCaption).foregroundStyle(.token(.textTertiary))
                        }
                    }
                }
            }
            GallerySection("Card (border + shadow.1 in light, luminance in dark)") {
                Text("Opaque content card").typeStyle(.body).foregroundStyle(.token(.textPrimary))
                    .frame(width: 260, alignment: .leading)
                    .contentCard()
            }
        }
    }

    private struct StatesSection: View {
        @FocusState private var focusedRow: Int?

        var body: some View {
            GallerySection("List row states") {
                VStack(spacing: Space.s2) {
                    ForEach(Array(RowState.allCases.enumerated()), id: \.offset) { index, state in
                        HStack {
                            Text(state.rawValue.capitalized).typeStyle(.body)
                                .foregroundStyle(
                                    state == .disabled ? ColorToken.textDisabled.color : ColorToken.textPrimary.color)
                            Spacer()
                        }
                        .padding(.horizontal, Space.s5)
                        .frame(height: Density.comfortable.rowHeight)
                        .background(RowBackground(state))
                    }
                    HStack {
                        Text("Focused (click, then Tab)").typeStyle(.body).foregroundStyle(.token(.textPrimary))
                        Spacer()
                    }
                    .padding(.horizontal, Space.s5)
                    .frame(height: Density.comfortable.rowHeight)
                    .focusable()
                    .focused($focusedRow, equals: 0)
                    .focusRing(focusedRow == 0)
                }
                .frame(width: 320)
                .padding(Space.s3)
                .background(
                    ColorToken.surfacePanel.color, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            GallerySection("Buttons (system glass styles handle hover/press)") {
                HStack(spacing: Space.s6) {
                    Button("Primary") {}.primaryGlassButton()
                    Button("Secondary") {}.secondaryGlassButton()
                    Button("Disabled") {}.primaryGlassButton().disabled(true)
                    Button("Bordered") {}.buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
        }
    }

    private struct GlassRulesSection: View {
        @State private var showsPopover = false
        @State private var showsSheet = false

        var body: some View {
            GallerySection(
                "Allowed: grouped controls floating over content",
                note:
                    "One GlassEffectContainer per group; content stays opaque underneath and scrolls under the toolbar."
            ) {
                ZStack(alignment: .top) {
                    MiniGraph().frame(height: 200).background(ColorToken.surfaceCanvas.color)
                    GlassControlGroup {
                        Button("Fetch", systemImage: "arrow.down") {}.labelStyle(.iconOnly).buttonStyle(.plain)
                            .padding(Space.s4).jitGlass(in: Circle())
                        Button("Pull", systemImage: "arrow.down.to.line") {}.labelStyle(.iconOnly).buttonStyle(.plain)
                            .padding(Space.s4).jitGlass(in: Circle())
                        Button("Push", systemImage: "arrow.up") {}.labelStyle(.iconOnly).buttonStyle(.plain)
                            .padding(Space.s4).jitGlass(in: Circle())
                    }
                    .padding(.top, Space.s5)
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            GallerySection("Allowed: floating capsule, popover, sheet") {
                HStack(spacing: Space.s6) {
                    FloatingGlassCapsule {
                        Label("Sample capsule", systemImage: "arrow.triangle.2.circlepath")
                            .typeStyle(.callout)
                    }
                    Button("Show Popover") { showsPopover = true }
                        .secondaryGlassButton()
                        .popover(isPresented: $showsPopover) {
                            Text("Popovers get system glass.").typeStyle(.body).padding(Space.s7)
                        }
                    Button("Show Sheet") { showsSheet = true }
                        .secondaryGlassButton()
                        .sheet(isPresented: $showsSheet) {
                            VStack(alignment: .leading, spacing: Space.s6) {
                                Text("Sheet").typeStyle(.title)
                                Text("Sheets get system glass; their content is opaque.").typeStyle(.body)
                                    .foregroundStyle(.token(.textSecondary))
                                Button("Done") { showsSheet = false }.primaryGlassButton()
                                    .keyboardShortcut(.defaultAction)
                            }
                            .padding(Space.s8)
                            .frame(width: 360)
                        }
                }
            }
            GallerySection(
                "Forbidden (schematic illustrations, not real glass)",
                note: "Reviewers: reject these patterns in code review."
            ) {
                HStack(alignment: .top, spacing: Space.s6) {
                    ForbiddenExample(title: "Glass on rows", caption: "Per-row glass costs GPU and destroys hierarchy.")
                    {
                        VStack(spacing: Space.s2) {
                            ForEach(0..<4) { _ in
                                Capsule().fill(ColorToken.textTertiary.color.opacity(0.25))
                                    .overlay(
                                        Capsule().strokeBorder(ColorToken.textTertiary.color.opacity(0.5), lineWidth: 1)
                                    )
                                    .frame(height: 14)
                            }
                        }
                    }
                    ForbiddenExample(
                        title: "Stacked blurs", caption: "Never layer visual-effect views or custom blurs."
                    ) {
                        ZStack {
                            ForEach(0..<3) { index in
                                RoundedRectangle(cornerRadius: Radius.sm)
                                    .fill(ColorToken.textTertiary.color.opacity(0.18))
                                    .offset(x: CGFloat(index) * 10, y: CGFloat(index) * 8)
                                    .frame(width: 90, height: 50)
                            }
                        }
                    }
                    ForbiddenExample(
                        title: "Text on glass over the graph", caption: "Text never sits on glass above busy content."
                    ) {
                        ZStack {
                            MiniGraph()
                            Text("a1b2c3 Fix graph").typeStyle(.caption).foregroundStyle(.token(.textTertiary))
                                .padding(Space.s2)
                                .background(ColorToken.textTertiary.color.opacity(0.18), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private struct ForbiddenExample<Illustration: View>: View {
        let title: String
        let caption: String
        let illustration: Illustration

        init(title: String, caption: String, @ViewBuilder illustration: () -> Illustration) {
            self.title = title
            self.caption = caption
            self.illustration = illustration()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: Space.s4) {
                illustration
                    .frame(width: 180, height: 90)
                    .clipped()
                    .padding(Space.s4)
                    .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: Radius.sm))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.token(.statusDanger))
                            .padding(Space.s3)
                            .accessibilityLabel("Forbidden")
                    }
                Text(title).typeStyle(.headline).foregroundStyle(.token(.textPrimary))
                Text(caption).typeStyle(.callout).foregroundStyle(.token(.textSecondary))
                    .frame(width: 196, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private struct MotionSection: View {
        @State private var expanded = false
        @State private var revealed = true
        @Namespace private var glassNamespace
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            GallerySection(
                "Tokens",
                note: "One-shot only. Reduce Motion: opacity-only at the same duration; no glass morphs."
            ) {
                Grid(alignment: .leading, horizontalSpacing: Space.s7, verticalSpacing: Space.s3) {
                    ForEach(MotionToken.allCases, id: \.self) { token in
                        GridRow {
                            Text(token.rawValue).typeStyle(.monoCaption).foregroundStyle(.token(.textSecondary))
                            Text("\(Int(token.duration * 1000)) ms").typeStyle(.monoCaption).monospacedDigit()
                                .foregroundStyle(.token(.textTertiary))
                        }
                    }
                }
            }
            GallerySection("Card reveal (motion.panel)") {
                Button(revealed ? "Hide Card" : "Reveal Card") {
                    withAnimation(MotionToken.panel.animation) { revealed.toggle() }
                }
                .secondaryGlassButton()
                ZStack {
                    if revealed {
                        Text("Revealed with a 4 pt rise").typeStyle(.body).foregroundStyle(.token(.textPrimary))
                            .contentCard()
                            .transition(RevealTransition.transition(reduceMotion: reduceMotion))
                    }
                }
                .frame(height: 80, alignment: .top)
            }
            GallerySection("Glass morph (motion.glassMorph)") {
                Button(expanded ? "Collapse" : "Expand") {
                    if reduceMotion {
                        withAnimation(.easeInOut(duration: MotionToken.glassMorph.duration)) { expanded.toggle() }
                    } else {
                        withAnimation(MotionToken.glassMorph.animation) { expanded.toggle() }
                    }
                }
                .secondaryGlassButton()
                GlassEffectContainer(spacing: Space.s4) {
                    HStack(spacing: Space.s4) {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                            .typeStyle(.callout)
                            .padding(.horizontal, Space.s6).padding(.vertical, Space.s4)
                            .jitGlass(in: Capsule())
                            .glassEffectID("sync", in: glassNamespace)
                        if expanded {
                            Label("Pause", systemImage: "pause.fill").labelStyle(.iconOnly)
                                .padding(Space.s4)
                                .jitGlass(in: Circle())
                                .glassEffectID("pause", in: glassNamespace)
                            Label("Cancel", systemImage: "xmark").labelStyle(.iconOnly)
                                .padding(Space.s4)
                                .jitGlass(in: Circle())
                                .glassEffectID("cancel", in: glassNamespace)
                        }
                    }
                }
                .frame(height: 60)
                .padding(Space.s6)
                .background(ColorToken.surfaceCanvas.color, in: RoundedRectangle(cornerRadius: Radius.md))
            }
        }
    }
#endif
