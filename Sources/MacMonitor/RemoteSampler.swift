import Foundation
import Combine

enum RemoteStatus: Equatable {
    case connecting
    case online
    case error(String)
}

/// Monitors one Linux server through a single long-lived `ssh` process running a sh loop.
/// Nothing is installed on the server. Stdout is parsed off the main thread; results are
/// published on the main thread at most once per remote block (every 2 s).
@MainActor
final class RemoteSampler: ObservableObject, Identifiable {
    nonisolated let id: UUID
    let config: ServerConfig

    @Published private(set) var snapshot = RemoteSnapshot()
    @Published private(set) var status: RemoteStatus = .connecting

    /// Called after a change that can alter the section's height (status, disk count, error text).
    var onLayoutChange: (() -> Void)?

    private var process: Process?
    private var parser = RemoteStreamParser()
    private var metrics = RemoteMetrics()
    private var stderrTail = StderrTail()
    private var generation = 0            // invalidates callbacks from older processes
    private var attempt = 0               // index into retryDelays
    private var stopped = false
    private var onlineThisRun = false
    private var retryTask: Task<Void, Never>?
    private static let retryDelays: [TimeInterval] = [5, 10, 30, 60]

    init(config: ServerConfig) {
        self.id = config.id
        self.config = config
    }

    /// Demo instance for MM_SNAPSHOT previews: never launches ssh.
    init(demo config: ServerConfig, snapshot: RemoteSnapshot) {
        self.id = config.id
        self.config = config
        self.snapshot = snapshot
        self.status = .online
        self.stopped = true
    }

    /// Key that changes whenever this server's section changes height.
    var layoutKey: [Int] {
        let s: Int
        var errHash = 0
        switch status {
        case .connecting: s = 0
        case .online: s = 1
        case .error(let msg): s = 2; errHash = msg.count / 30   // ~ line-wrap bucket
        }
        return [s, errHash, snapshot.hasData ? 1 : 0, snapshot.disks.count]
    }

    // MARK: Lifecycle

    func start() {
        guard process == nil else { return }
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        retryTask?.cancel()
        retryTask = nil
        generation &+= 1
        teardown(terminate: true)
    }

    /// Reconnect immediately (menu item), resetting the backoff.
    func reconnect() {
        stop()
        attempt = 0
        stopped = false
        setStatus(.connecting)
        launch()
    }

    private func launch() {
        guard !stopped else { return }
        generation &+= 1
        let gen = generation
        onlineThisRun = false
        metrics.resetBaselines()
        let parser = RemoteStreamParser()
        self.parser = parser
        let tail = StderrTail()
        self.stderrTail = tail
        setStatus(.connecting)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = RemoteScript.sshArguments(for: config)
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        // readabilityHandler runs on a private background queue. At EOF it is called with
        // empty data repeatedly unless cleared, so always clear it on empty reads.
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let result = parser.feed(data)
            guard result.hostname != nil || !result.samples.isEmpty else { return }
            Task { @MainActor in self?.receive(result, generation: gen) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            tail.append(data)
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in
                // Give the stderr handler a moment to drain the final message.
                try? await Task.sleep(nanoseconds: 200_000_000)
                self?.processExited(code: code, generation: gen)
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            setStatus(.error("Couldn't start ssh: \(error.localizedDescription)"))
            scheduleRetry()
        }
    }

    private func teardown(terminate: Bool) {
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if terminate && p.isRunning { p.terminate() }   // SIGTERM: ssh closes the session
    }

    // MARK: Callbacks (main thread)

    private func receive(_ result: RemoteStreamParser.Output, generation gen: Int) {
        guard gen == generation, !stopped else { return }
        var s = snapshot
        if let h = result.hostname { s.hostname = h }
        for raw in result.samples { metrics.apply(raw, to: &s) }
        let oldDiskCount = snapshot.disks.count
        let oldHasData = snapshot.hasData
        if s != snapshot { snapshot = s }
        if !result.samples.isEmpty {
            onlineThisRun = true
            attempt = 0
            setStatus(.online)
        }
        if oldDiskCount != s.disks.count || oldHasData != s.hasData { onLayoutChange?() }
    }

    private func processExited(code: Int32, generation gen: Int) {
        guard gen == generation else { return }
        teardown(terminate: false)
        guard !stopped else { return }
        if onlineThisRun { attempt = 0 }
        var msg = stderrTail.lastMessage()
        if msg.isEmpty { msg = code == 255 ? "Connection failed" : "Connection closed (exit \(code))" }
        setStatus(.error(msg))
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard !stopped else { return }
        let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
        attempt += 1
        if case .error(let msg) = status {
            setStatus(.error("\(msg) · retry in \(Int(delay)) s"))
        }
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.retryTask = nil
            self.launch()
        }
    }

    private func setStatus(_ new: RemoteStatus) {
        guard new != status else { return }
        let oldKey = layoutKey
        status = new
        if layoutKey != oldKey { onLayoutChange?() }
    }
}

/// Keeps the last ~2 KB of ssh's stderr (written from a background queue).
final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        if data.count > 2048 { data = Data(data.suffix(2048)) }
    }

    /// Last meaningful stderr line, shortened for display.
    func lastMessage() -> String {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        guard var line = lines.last else { return "" }
        if line.hasPrefix("ssh: ") { line.removeFirst(5) }
        if line.count > 90 { line = String(line.prefix(89)) + "…" }
        return line
    }
}

// MARK: - Server list + persistence

@MainActor
final class RemoteManager: ObservableObject {
    private static let defaultsKey = "remoteServers"

    @Published private(set) var servers: [RemoteSampler] = []
    /// Fires (on the main thread) whenever any server section may have changed height.
    let layoutChanged = PassthroughSubject<Void, Never>()
    private let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            servers = [Self.demoServer()]
        } else {
            servers = Self.load().map { self.makeSampler($0) }
            servers.forEach { $0.start() }
        }
    }

    var configs: [ServerConfig] { servers.map(\.config) }

    /// Combined height key of all server sections.
    var layoutKey: [Int] { [servers.count] + servers.flatMap(\.layoutKey) }

    func add(_ config: ServerConfig) {
        let s = makeSampler(config)
        servers.append(s)
        save()
        s.start()
        notifyLayout()
    }

    func remove(id: UUID) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].stop()
        servers.remove(at: i)
        save()
        notifyLayout()
    }

    func reconnect(id: UUID) { servers.first(where: { $0.id == id })?.reconnect() }

    func stopAll() { servers.forEach { $0.stop() } }

    private func makeSampler(_ config: ServerConfig) -> RemoteSampler {
        let s = RemoteSampler(config: config)
        s.onLayoutChange = { [weak self] in self?.notifyLayout() }
        return s
    }

    private func notifyLayout() {
        // @Published emits in willSet; defer so observers read the updated state.
        Task { @MainActor [weak self] in self?.layoutChanged.send(()) }
    }

    private func save() {
        guard !demo, let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> [ServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([ServerConfig].self, from: data) else { return [] }
        return list
    }

    private static func demoServer() -> RemoteSampler {
        let gb: UInt64 = 1_000_000_000
        let cfg = ServerConfig(name: "linux-server", host: "linux-server.local", user: "admin")
        var s = RemoteSnapshot()
        s.hostname = "linux-server"
        s.hasData = true
        s.cpu = 0.23
        s.memTotal = 16 * 1_073_741_824
        s.memUsed = UInt64(6.4 * 1_073_741_824)
        s.disks = [
            RemoteDisk(mount: "/", device: "/dev/nvme0n1p2", total: 250 * gb, used: 92 * gb, free: 145 * gb),
            RemoteDisk(mount: "/home", device: "/dev/nvme0n1p3", total: 750 * gb, used: 410 * gb, free: 302 * gb),
            RemoteDisk(mount: "/mnt/backup", device: "/dev/sda1", total: 4000 * gb, used: 3550 * gb, free: 250 * gb),
        ]
        s.netIn = 1_240_000
        s.netOut = 86_000
        s.load = [0.42, 0.37, 0.31]
        return RemoteSampler(demo: cfg, snapshot: s)
    }
}
