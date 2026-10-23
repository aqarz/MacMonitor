import AppKit
import SwiftUI
import Combine

/// Borderless, non-activating panel that lives on the desktop layer behind normal windows.
final class DesktopPanel: NSPanel {
    private let dragView = DragOverlayView()
    private static let originKey = "panelOrigin"
    private var hosting: NSHostingView<MonitorView>?
    private var layoutSub: AnyCancellable?
    private let sampler: Sampler
    #if !APPSTORE
    private let remotes: RemoteManager
    #endif
    private var lastLayoutKey: [Int] = []

    #if APPSTORE
    init(sampler: Sampler) {
        self.sampler = sampler
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 260),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        setUp()
    }
    #else
    init(sampler: Sampler, remotes: RemoteManager) {
        self.sampler = sampler
        self.remotes = remotes
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 260),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        setUp()
    }
    #endif

    private func setUp() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = true
        isMovableByWindowBackground = false     // dragging handled by DragOverlayView
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // Rounded, light translucent material (the warm gradient is drawn by SwiftUI on top).
        let light = NSAppearance(named: .aqua)
        appearance = light
        let radius = Theme.cornerRadius
        let effect = NSVisualEffectView()
        effect.appearance = light
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active                   // stay vibrant even though the app is never active
        effect.maskImage = DesktopPanel.roundedMask(radius: radius)

        #if APPSTORE
        let hosting = NSHostingView(rootView: MonitorView(sampler: sampler))
        #else
        let hosting = NSHostingView(rootView: MonitorView(sampler: sampler, remotes: remotes))
        #endif
        self.hosting = hosting
        lastLayoutKey = currentLayoutKey()
        let size = Self.fittingSize(for: hosting, estimate: estimatedMinHeight())
        setContentSize(size)

        effect.frame = NSRect(origin: .zero, size: size)
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        dragView.frame = effect.bounds
        dragView.autoresizingMask = [.width, .height]
        dragView.cornerRadius = radius
        effect.addSubview(hosting)
        effect.addSubview(dragView)              // on top: receives mouse events when unlocked
        contentView = effect

        restoreOrigin()
        // Grow/shrink (keeping the top edge fixed) when local disks are plugged in or ejected,
        // servers are added/removed, or a server's status / filesystem count changes.
        // Every trigger just re-checks one combined layout key, so per-tick cost is nil.
        let localVolumes = sampler.$snapshot.map { $0.volumes.count }.removeDuplicates()
            .map { _ in () }.eraseToAnyPublisher()
        #if APPSTORE
        let layoutTriggers = localVolumes
        #else
        let serverList = remotes.$servers.map { _ in () }.eraseToAnyPublisher()
        let layoutTriggers = Publishers.Merge3(localVolumes, serverList, remotes.layoutChanged.eraseToAnyPublisher())
        #endif
        layoutSub = layoutTriggers
            .sink { [weak self] _ in
                // @Published fires in willSet: look at the new state on the next main-queue turn.
                DispatchQueue.main.async { self?.layoutMaybeChanged() }
            }
        NotificationCenter.default.addObserver(self, selector: #selector(didMove(_:)),
                                               name: NSWindow.didMoveNotification, object: self)
    }

    private static func fittingSize(for hosting: NSView, estimate minHeight: CGFloat) -> NSSize {
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        return NSSize(width: max(fit.width, Theme.panelWidth), height: max(fit.height, minHeight))
    }

    /// Never smaller than the full content: local CPU + Memory + Network + one row per disk,
    /// plus each server section. Deliberately a slight under-estimate so the real fitting
    /// height normally wins.
    private func estimatedMinHeight() -> CGFloat {
        var h = CGFloat(300 + 50 * max(sampler.snapshot.volumes.count, 1))
        #if !APPSTORE
        for server in remotes.servers {
            h += 45
            let showsMetrics: Bool
            if case .error = server.status { showsMetrics = false } else { showsMetrics = server.snapshot.hasData }
            h += showsMetrics ? CGFloat(80 + 26 * server.snapshot.disks.count) : 14
        }
        #endif
        return h
    }

    private func currentLayoutKey() -> [Int] {
        #if APPSTORE
        return [sampler.snapshot.volumes.count]
        #else
        return [sampler.snapshot.volumes.count] + remotes.layoutKey
        #endif
    }

    private func layoutMaybeChanged() {
        let key = currentLayoutKey()
        guard key != lastLayoutKey else { return }
        lastLayoutKey = key
        resize()
        // SwiftUI may apply the new content a runloop turn later; re-measure once shortly after.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.resize()
        }
    }

    private func resize() {
        guard let hosting else { return }
        let size = Self.fittingSize(for: hosting, estimate: estimatedMinHeight())
        guard size != frame.size else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height),
                 display: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var locked: Bool = true {
        didSet {
            ignoresMouseEvents = locked          // click-through when locked
            dragView.isHidden = locked
        }
    }

    // MARK: Position persistence

    @objc private func didMove(_ note: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }

    private func restoreOrigin() {
        if let str = UserDefaults.standard.string(forKey: Self.originKey) {
            let origin = NSPointFromString(str)
            let rect = NSRect(origin: origin, size: frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                setFrameOrigin(origin)
                return
            }
        }
        // Default: top-right corner of the main screen
        if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            setFrameOrigin(NSPoint(x: vf.maxX - frame.width - 20, y: vf.maxY - frame.height - 20))
        }
    }

    /// 9-slice mask matching SwiftUI's continuous ("squircle") rounded rectangle.
    /// A continuous corner extends ~1.53x the radius along each edge, so the cap insets are larger.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let inset = ceil(radius * 1.6)
        let edge = inset * 2 + 1
        let rect = CGRect(x: 0, y: 0, width: edge, height: edge)
        let continuous = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(continuous)
            ctx.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        image.resizingMode = .stretch
        return image
    }
}

/// Transparent view covering the panel while unlocked: drags the window and shows a hint border.
final class DragOverlayView: NSView {
    var cornerRadius: CGFloat = Theme.cornerRadius

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: cornerRadius - 1, yRadius: cornerRadius - 1)
        path.lineWidth = 2
        let dash: [CGFloat] = [6, 4]
        path.setLineDash(dash, count: dash.count, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        path.stroke()
    }
}

// MARK: - Theme (Tangerine-style: light, glassy, warm)

enum Theme {
    static let panelWidth: CGFloat = 250
    static let cornerRadius: CGFloat = 20
    static let hPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 12

    static let ink = Color(hex: 0x271C0B)            // primary text
    static let label = Color(hex: 0x5D0000)          // section labels + icons
    static let accent = Color(hex: 0xFF5200)         // fills
    static let accentDeep = Color(hex: 0xEB4500)     // fills above 85%
    static let spark = Color(hex: 0xFE6E21)          // CPU history bars
    static let track = Color(hex: 0xCB8979, opacity: 0.45)
    static let divider = Color(hex: 0xD78522, opacity: 0.4)
    static let sliceStroke = Color(hex: 0x5D6666, opacity: 0.22)

    static let statusOnline = Color(hex: 0x2FB344)
    static let statusConnecting = Color(hex: 0xFF9500)
    static let statusError = Color(hex: 0xE5341D)

    static let gradientTop = Color(hex: 0xFFC24B, opacity: 0.85)
    static let gradientBottom = Color(hex: 0xFFBF8A, opacity: 0.75)

    static func labelFont() -> Font { .system(size: 11, weight: .semibold, design: .rounded) }
    static func valueFont() -> Font { .system(size: 12, weight: .semibold, design: .rounded).monospacedDigit() }
    static func detailFont() -> Font { .system(size: 10, weight: .regular, design: .rounded).monospacedDigit() }
}

extension Color {
    /// `Color(hex: 0xFF5200)` / `Color(hex: 0xFF5200, opacity: 0.5)`; sRGB, 0xRRGGBB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - SwiftUI content

struct MonitorView: View {
    @ObservedObject var sampler: Sampler
    #if !APPSTORE
    @ObservedObject var remotes: RemoteManager
    #endif
    /// ImageRenderer can't draw NSVisualEffectView materials; use a flat translucent fill instead.
    var snapshotMode: Bool = false

    var body: some View {
        let s = sampler.snapshot
        VStack(spacing: 0) {
            PanelHeader(title: LocalHost.name)

            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                // CPU: ring + 60 s history
                VStack(spacing: 10) {
                    CPURing(load: s.cpu)
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 6) {
                        SectionRow(icon: "waveform.path.ecg", title: "Last 60 s",
                                   value: "peak " + Fmt.pct(s.cpuHistory.max() ?? 0))
                        HistoryBars(values: s.cpuHistory)
                            .frame(height: 40)
                    }
                }

                MeterSection(icon: "memorychip", title: "Memory",
                             value: Fmt.pct(s.memFraction),
                             detail: "\(Fmt.gb(s.memUsed)) of \(Fmt.gb(s.memTotal)) GB used",
                             fraction: s.memFraction)

                ForEach(s.volumes) { vol in
                    MeterSection(icon: vol.id == "/" ? "internaldrive" : "externaldrive",
                                 title: vol.name,
                                 value: "\(Fmt.diskGB(vol.free)) GB free",
                                 detail: "of \(Fmt.diskGB(vol.total)) GB",
                                 fraction: vol.usedFraction)
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionRow(icon: "network", title: "Network", value: nil)
                    HStack(spacing: 6) {
                        RateChip(arrow: "↓", rate: Fmt.rate(s.netIn))
                        RateChip(arrow: "↑", rate: Fmt.rate(s.netOut))
                    }
                }
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, 14)
            .padding(.bottom, 16)

            // One compact section per SSH server (each observes only its own sampler).
            #if !APPSTORE
            ForEach(remotes.servers) { server in
                RemoteSection(server: server)
            }
            #endif
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: Theme.panelWidth, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PanelBackground(flatFill: snapshotMode))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .environment(\.colorScheme, .light)
    }
}

/// Warm gradient wash over the (light) material, plus a hairline inner highlight.
struct PanelBackground: View {
    var flatFill: Bool = false

    var body: some View {
        ZStack {
            if flatFill {
                Color.white.opacity(0.35)
            }
            LinearGradient(colors: [Theme.gradientTop, Theme.gradientBottom],
                           startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
        }
    }
}

struct PanelHeader: View {
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 0.5)
        }
    }
}

/// Label (icon + title) on the left, monospaced value on the right.
struct SectionRow: View {
    let icon: String
    let title: String
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 15)
            Text(title)
                .font(Theme.labelFont())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let value = value {
                Text(value)
                    .font(Theme.valueFont())
                    .foregroundColor(Theme.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .foregroundColor(Theme.label)
    }
}

struct MeterSection: View {
    let icon: String
    let title: String
    let value: String
    let detail: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionRow(icon: icon, title: title, value: value)
            UsageBar(fraction: fraction)
            Text(detail)
                .font(Theme.detailFont())
                .foregroundColor(Theme.ink.opacity(0.6))
                .lineLimit(1)
        }
    }
}

struct UsageBar: View {
    let fraction: Double

    var body: some View {
        let f = CGFloat(min(max(fraction, 0), 1))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(fraction > 0.85 ? Theme.accentDeep : Theme.accent)
                    .frame(width: max(f > 0 ? CGFloat(6) : CGFloat(0), geo.size.width * f))
            }
        }
        .frame(height: 6)
    }
}

struct RateChip: View {
    let arrow: String
    let rate: String

    var body: some View {
        (Text(arrow).foregroundColor(Theme.accentDeep) + Text(" " + rate).foregroundColor(Theme.ink))
            .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Color.black.opacity(0.07)))
    }
}

// MARK: - Remote server section

enum LocalHost {
    /// Friendly computer name (System Settings → General → Sharing), resolved once.
    static let name: String = Host.current().localizedName ?? "This Mac"
}

#if !APPSTORE
struct RemoteSection: View {
    @ObservedObject var server: RemoteSampler

    private var errorText: String? {
        if case .error(let msg) = server.status { return msg }
        return nil
    }

    var body: some View {
        let s = server.snapshot
        VStack(spacing: 0) {
            ServerHeader(name: server.config.name, status: server.status, load: s.load)

            VStack(alignment: .leading, spacing: 9) {
                if let errorText = errorText {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(Theme.statusError)
                        Text(errorText)
                            .font(Theme.detailFont())
                            .foregroundColor(Theme.ink.opacity(0.75))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if !s.hasData {
                    Text("Connecting to \(server.config.displayAddress)…")
                        .font(Theme.detailFont())
                        .foregroundColor(Theme.ink.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    RemoteMetricsView(s: s)
                        .opacity(server.status == .online ? 1 : 0.55)   // stale while reconnecting
                }
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
    }
}

struct RemoteMetricsView: View {
    let s: RemoteSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CompactMeter(icon: "cpu", title: "CPU", detail: nil,
                         value: Fmt.pct(s.cpu), fraction: s.cpu)
            CompactMeter(icon: "memorychip", title: "Memory",
                         detail: "\(Fmt.gb(s.memUsed))/\(Fmt.gb(s.memTotal)) GB",
                         value: Fmt.pct(s.memFraction), fraction: s.memFraction)
            ForEach(s.disks) { d in
                CompactMeter(icon: d.mount == "/" ? "internaldrive" : "externaldrive",
                             title: d.mount,
                             detail: "\(Fmt.diskGB(Int64(clamping: d.free))) GB free",
                             value: Fmt.pct(d.usedFraction), fraction: d.usedFraction)
            }
            HStack(spacing: 6) {
                RateChip(arrow: "↓", rate: Fmt.rate(s.netIn))
                RateChip(arrow: "↑", rate: Fmt.rate(s.netOut))
            }
        }
    }
}

struct ServerHeader: View {
    let name: String
    let status: RemoteStatus
    let load: [Double]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 0.5)
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if load.count == 3 {
                    Text(String(format: "load %.2f %.2f %.2f", load[0], load[1], load[2]))
                        .font(Theme.detailFont())
                        .foregroundColor(Theme.ink.opacity(0.6))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, Theme.hPadding)
            .frame(height: 30)
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 0.5)
        }
    }

    private var dotColor: Color {
        switch status {
        case .online: return Theme.statusOnline
        case .connecting: return Theme.statusConnecting
        case .error: return Theme.statusError
        }
    }
}
#endif

/// One-line meter: icon + title, optional faded detail, value, then a thin bar.
struct CompactMeter: View {
    let icon: String
    let title: String
    let detail: String?
    let value: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 15)
                Text(title)
                    .font(Theme.labelFont())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let detail = detail {
                    Text(detail)
                        .font(Theme.detailFont())
                        .foregroundColor(Theme.ink.opacity(0.6))
                        .lineLimit(1)
                        .layoutPriority(0.5)
                }
                Text(value)
                    .font(Theme.valueFont())
                    .foregroundColor(Theme.ink)
                    .lineLimit(1)
                    .frame(minWidth: 30, alignment: .trailing)
                    .layoutPriority(1)
            }
            .foregroundColor(Theme.label)
            UsageBar(fraction: fraction)
        }
    }
}

// MARK: CPU ring (Tangerine-style wheel of rounded slices)

struct CPURing: View {
    let load: Double
    var slices: Int = 8
    var diameter: CGFloat = 110
    var innerDiameter: CGFloat = 46

    var body: some View {
        let lit = min(max(load, 0), 1) * Double(slices)
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: diameter + 8, height: diameter + 8)
            ForEach(0..<slices, id: \.self) { i in
                let shape = RingSlice(index: i, count: slices, innerRatio: innerDiameter / diameter)
                let f = min(max(lit - Double(i), 0), 1)          // 0 = unlit, 1 = fully lit
                ZStack {
                    shape.fill(Color.white.opacity(0.6))
                    shape.fill(Theme.accent).opacity(f > 0 ? 0.3 + 0.7 * f : 0)
                    shape.stroke(Theme.sliceStroke, lineWidth: 0.75).opacity(1 - f)
                }
            }
            .frame(width: diameter, height: diameter)

            VStack(spacing: 0) {
                Text(Fmt.pct(load))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(Theme.ink)
                Text("CPU")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.label.opacity(0.75))
            }
            .frame(width: 58, height: 34)
            .background(Capsule().fill(Color.white.opacity(0.72)))
        }
        .frame(width: diameter + 8, height: diameter + 8)
    }
}

/// One annular sector of a ring with all four corners rounded.
/// Gaps between neighbours have constant width (`gap` points), like Tangerine's wheel.
struct RingSlice: Shape {
    var index: Int
    var count: Int
    var innerRatio: CGFloat          // inner radius / outer radius
    var gap: CGFloat = 3
    var corner: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard count > 0 else { return p }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rOut = min(rect.width, rect.height) / 2
        let rIn = rOut * innerRatio
        let h = gap / 2
        let k = min(corner, (rOut - rIn) / 2 - 0.5)
        guard rOut > rIn, k > 0 else { return p }

        let span = 2 * CGFloat.pi / CGFloat(count)
        // Slice 0 is centred at 12 o'clock; slices advance clockwise on screen (y-down).
        let a0 = -CGFloat.pi / 2 - span / 2 + CGFloat(index) * span
        let a1 = a0 + span

        // Fillet for the corner where the edge line at angle `a` meets a circle.
        // side = +1 for the start edge (slice lies toward increasing angle), -1 for the end edge.
        // outer = true: fillet inside the outer circle; false: fillet outside the inner circle.
        func fillet(_ a: CGFloat, side: CGFloat, outer: Bool) -> (center: CGPoint, onLine: CGPoint, onCircle: CGPoint) {
            let u = CGPoint(x: cos(a), y: sin(a))
            let n = CGPoint(x: -sin(a) * side, y: cos(a) * side)
            let d = h + k
            let dist = outer ? rOut - k : rIn + k
            let t = (max(dist * dist - d * d, 0)).squareRoot()
            let center = CGPoint(x: c.x + t * u.x + d * n.x, y: c.y + t * u.y + d * n.y)
            let onLine = CGPoint(x: c.x + t * u.x + h * n.x, y: c.y + t * u.y + h * n.y)
            let r = outer ? rOut : rIn
            let onCircle = CGPoint(x: c.x + (center.x - c.x) * r / dist,
                                   y: c.y + (center.y - c.y) * r / dist)
            return (center, onLine, onCircle)
        }
        func angle(_ pt: CGPoint, from o: CGPoint) -> CGFloat { atan2(pt.y - o.y, pt.x - o.x) }
        /// Signed sweep from a to b, normalised to (-pi, pi] (shortest way round).
        func shortest(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            var d = b - a
            while d > .pi { d -= 2 * .pi }
            while d <= -.pi { d += 2 * .pi }
            return d
        }
        func arc(_ center: CGPoint, _ radius: CGFloat, from: CGFloat, sweep: CGFloat) {
            p.addRelativeArc(center: center, radius: radius,
                             startAngle: .radians(Double(from)), delta: .radians(Double(sweep)))
        }

        let os = fillet(a0, side: 1, outer: true)
        let oe = fillet(a1, side: -1, outer: true)
        let ins = fillet(a0, side: 1, outer: false)
        let ine = fillet(a1, side: -1, outer: false)

        p.move(to: ins.onLine)
        p.addLine(to: os.onLine)
        // outer-start corner
        var from = angle(os.onLine, from: os.center)
        arc(os.center, k, from: from, sweep: shortest(from, angle(os.onCircle, from: os.center)))
        // outer edge (increasing angle)
        from = angle(os.onCircle, from: c)
        var sweep = angle(oe.onCircle, from: c) - from
        while sweep <= 0 { sweep += 2 * .pi }
        arc(c, rOut, from: from, sweep: sweep)
        // outer-end corner
        from = angle(oe.onCircle, from: oe.center)
        arc(oe.center, k, from: from, sweep: shortest(from, angle(oe.onLine, from: oe.center)))
        // end edge inward
        p.addLine(to: ine.onLine)
        // inner-end corner
        from = angle(ine.onLine, from: ine.center)
        arc(ine.center, k, from: from, sweep: shortest(from, angle(ine.onCircle, from: ine.center)))
        // inner edge (decreasing angle)
        from = angle(ine.onCircle, from: c)
        sweep = angle(ins.onCircle, from: c) - from
        while sweep >= 0 { sweep -= 2 * .pi }
        arc(c, rIn, from: from, sweep: sweep)
        // inner-start corner
        from = angle(ins.onCircle, from: ins.center)
        arc(ins.center, k, from: from, sweep: shortest(from, angle(ins.onLine, from: ins.center)))
        p.closeSubpath()
        return p
    }
}

/// 60 s CPU history as vertical bars in a recessed well.
struct HistoryBars: View {
    let values: [Double]

    var body: some View {
        BarsShape(values: values)
            .fill(Theme.spark)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.05)))
    }
}

struct BarsShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard !values.isEmpty, rect.width > 0, rect.height > 0 else { return p }
        let step = rect.width / CGFloat(values.count)
        let barW = max(1, step - 1.2)
        let r = min(barW / 2, 1.2)
        for (i, v) in values.enumerated() {
            let hgt = max(1.5, CGFloat(min(max(v, 0), 1)) * rect.height)
            let bar = CGRect(x: rect.minX + CGFloat(i) * step + (step - barW) / 2,
                             y: rect.maxY - hgt, width: barW, height: hgt)
            p.addRoundedRect(in: bar, cornerSize: CGSize(width: r, height: r))
        }
        return p
    }
}

// MARK: - Snapshot debug mode (MM_SNAPSHOT=/path/to/out.png)

@MainActor
enum SnapshotExporter {
    /// If MM_SNAPSHOT names a file, render the panel to a PNG there after ~3 s, then quit.
    #if APPSTORE
    static func scheduleIfRequested(sampler: Sampler) {
        guard let path = ProcessInfo.processInfo.environment["MM_SNAPSHOT"], !path.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // let CPU / network samples settle
            render(MonitorView(sampler: sampler, snapshotMode: true), to: path)
            NSApp.terminate(nil)
        }
    }
    #else
    static func scheduleIfRequested(sampler: Sampler, remotes: RemoteManager) {
        guard let path = ProcessInfo.processInfo.environment["MM_SNAPSHOT"], !path.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // let CPU / network samples settle
            render(MonitorView(sampler: sampler, remotes: remotes, snapshotMode: true), to: path)
            NSApp.terminate(nil)
        }
    }
    #endif

    private static func render(_ view: MonitorView, to path: String) {
        let preview = view
            .fixedSize()
            .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 6)
            .padding(32)
            .background(
                LinearGradient(colors: [Color(hex: 0xF78F41), Color(hex: 0xFF604F), Color(hex: 0xA191C5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: preview)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write(Data("MM_SNAPSHOT: render failed\n".utf8))
            return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("MM_SNAPSHOT: PNG encoding failed\n".utf8))
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } catch {
            FileHandle.standardError.write(Data("MM_SNAPSHOT: \(error.localizedDescription)\n".utf8))
        }
    }
}
