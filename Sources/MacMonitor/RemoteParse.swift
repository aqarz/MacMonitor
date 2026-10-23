import Foundation

// Pure Foundation code (no AppKit / SwiftUI) so it can be exercised on Linux as well.

// MARK: - Server configuration

struct ServerConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var user: String
    var port: Int
    var identityFile: String?

    init(id: UUID = UUID(), name: String, host: String, user: String, port: Int = 22,
         identityFile: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }

    // Tolerant decoding: missing id / port / identityFile get defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try c.decode(String.self, forKey: .host)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? host
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
    }

    /// "user@host:port" for menus.
    var displayAddress: String {
        let u = user.isEmpty ? "" : user + "@"
        return port == 22 ? u + host : "\(u)\(host):\(port)"
    }
}

// MARK: - Remote shell script

enum RemoteScript {
    /// POSIX sh loop run on the server. Deliberately a single line containing no single quotes
    /// and no backslashes, so wrapping it in '...' is safe under sh, bash, zsh, fish and csh
    /// login shells. Prints one ##BEGIN ... ##END block every 2 s.
    static let script: String = [
        "echo \"##HOST $(hostname 2>/dev/null || uname -n)\";",
        "T=; command -v timeout >/dev/null 2>&1 && T=\"timeout 5\";",
        "if df -P -B1 -x tmpfs / >/dev/null 2>&1; then M=1; else M=1024; fi;",
        "while :; do",
        "echo \"##BEGIN $M\";",
        "head -n 1 /proc/stat;",
        "grep -E \"^(MemTotal|MemFree|MemAvailable|Buffers|Cached):\" /proc/meminfo;",
        "echo \"##UP $(cat /proc/uptime)\";",
        "echo \"##LOAD $(cat /proc/loadavg)\";",
        "echo \"##DF\";",
        "if [ $M = 1 ]; then $T df -P -B1 -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null;",
        "else $T df -Pk 2>/dev/null; fi;",
        "echo \"##NET\";",
        "tail -n +3 /proc/net/dev;",
        "echo \"##END\";",
        "sleep 2 || exit;",
        "done",
    ].joined(separator: " ")

    /// The single remote command string handed to ssh (interpreted by the user's login shell).
    static var remoteCommand: String { "sh -c '" + script + "'" }

    /// Full argument list for /usr/bin/ssh.
    static func sshArguments(for s: ServerConfig) -> [String] {
        var args = ["-T",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=8",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=2",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "LogLevel=ERROR",            // hide "Permanently added ... to known hosts"
                    "-p", String(s.port)]
        if let id = s.identityFile?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
            args += ["-i", (id as NSString).expandingTildeInPath]
        }
        args += ["--", s.user.isEmpty ? s.host : "\(s.user)@\(s.host)", remoteCommand]
        return args
    }
}

// MARK: - Raw samples (one per ##BEGIN ... ##END block)

struct RemoteDisk: Identifiable, Equatable, Sendable {
    var id: String { mount }
    var mount: String
    var device: String
    var total: UInt64       // bytes
    var used: UInt64        // bytes
    var free: UInt64        // bytes available to non-root users
    /// Same definition as df's "Use%": used / (used + available).
    var usedFraction: Double {
        let denom = Double(used) + Double(free)
        return denom > 0 ? Double(used) / denom : 0
    }
}

struct RawSample: Sendable {
    var cpuTotal: UInt64?
    var cpuIdle: UInt64?
    var memTotal: UInt64?           // bytes
    var memAvailable: UInt64?       // bytes
    var uptime: Double?             // seconds, from /proc/uptime (sub-second resolution)
    var load: [Double] = []
    var disks: [RemoteDisk]?        // nil when the df section was empty (e.g. timed out)
    var netRx: UInt64?
    var netTx: UInt64?
    var arrival: TimeInterval = 0   // local monotonic time the block was completed
}

/// Incremental parser for the ssh stdout stream. Fed from a background readabilityHandler;
/// all state is behind a lock so it is safe whichever thread calls it.
final class RemoteStreamParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var inBlock = false
    private var multiplier: UInt64 = 1
    private var section = ""
    private var current = RawSample()
    private var dfLines: [String] = []
    private var netRx: UInt64 = 0
    private var netTx: UInt64 = 0
    private var sawNet = false

    struct Output: Sendable {
        var hostname: String?
        var samples: [RawSample] = []
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
        inBlock = false
    }

    func feed(_ data: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Output {
        lock.lock(); defer { lock.unlock() }
        var out = Output()
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            handle(line: line, now: now, out: &out)
        }
        if buffer.count > 1_000_000 { buffer.removeAll() }   // garbage without newlines: drop it
        // Data.removeSubrange keeps a sliced start index; re-base occasionally.
        if buffer.startIndex != 0 { buffer = Data(buffer) }
        return out
    }

    private func handle(line: String, now: TimeInterval, out: inout Output) {
        if line.hasPrefix("##") {
            if line.hasPrefix("##HOST ") {
                let h = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                if !h.isEmpty { out.hostname = h }
            } else if line.hasPrefix("##BEGIN") {
                inBlock = true
                multiplier = UInt64(line.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 1
                if multiplier == 0 { multiplier = 1 }
                current = RawSample()
                section = ""
                dfLines.removeAll(keepingCapacity: true)
                netRx = 0; netTx = 0; sawNet = false
                memFallback.removeAll(keepingCapacity: true)
            } else if !inBlock {
                return
            } else if line.hasPrefix("##UP ") {
                current.uptime = line.dropFirst(5).split(separator: " ").first.flatMap { Double($0) }
            } else if line.hasPrefix("##LOAD ") {
                current.load = line.dropFirst(7).split(separator: " ").prefix(3).compactMap { Double($0) }
            } else if line == "##DF" {
                section = "df"
            } else if line == "##NET" {
                section = "net"
            } else if line == "##END" {
                if !dfLines.isEmpty {
                    let disks = RemoteParse.disks(fromDF: dfLines, multiplier: multiplier)
                    if !disks.isEmpty { current.disks = disks }
                }
                if sawNet { current.netRx = netRx; current.netTx = netTx }
                if current.memAvailable == nil, memFallback.count == 3 {
                    current.memAvailable = memFallback.values.reduce(0, +)
                }
                current.arrival = now
                out.samples.append(current)
                inBlock = false
            }
            return
        }
        guard inBlock else { return }   // login banners, .bashrc noise, etc.

        switch section {
        case "df":
            dfLines.append(line)
        case "net":
            if let n = RemoteParse.netDevLine(line), RemoteParse.countsInterface(n.name) {
                netRx &+= n.rx; netTx &+= n.tx; sawNet = true
            }
        default:
            if line.hasPrefix("cpu ") {
                if let c = RemoteParse.cpuLine(line) {
                    current.cpuTotal = c.total; current.cpuIdle = c.idle
                }
            } else if let m = RemoteParse.meminfoLine(line) {
                let key = m.key, kb = m.kb
                switch key {
                case "MemTotal": current.memTotal = kb * 1024
                case "MemAvailable": current.memAvailable = kb * 1024
                case "MemFree", "Buffers", "Cached":
                    memFallback[key] = kb * 1024    // for kernels < 3.14 without MemAvailable
                default: break
                }
            }
        }
    }

    private var memFallback: [String: UInt64] = [:]
}

enum RemoteParse {
    /// "cpu  user nice system idle iowait irq softirq steal guest guest_nice"
    /// total = first 8 fields (guest time is already included in user/nice); idle = idle + iowait.
    static func cpuLine(_ line: String) -> (total: UInt64, idle: UInt64)? {
        let f = line.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        guard f.count >= 4 else { return nil }
        let total = f.prefix(8).reduce(0, &+)
        let idle = f[3] &+ (f.count > 4 ? f[4] : 0)
        return (total, idle)
    }

    /// "MemTotal:       16314564 kB" -> ("MemTotal", 16314564)
    static func meminfoLine(_ line: String) -> (key: String, kb: UInt64)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon])
        let rest = line[line.index(after: colon)...].split(separator: " ")
        guard let v = rest.first.flatMap({ UInt64($0) }) else { return nil }
        return (key, v)
    }

    /// "  eth0: 123 456 ... (8 rx fields) 789 ..." -> ("eth0", rxBytes, txBytes)
    static func netDevLine(_ line: String) -> (name: String, rx: UInt64, tx: UInt64)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
        let f = line[line.index(after: colon)...].split(separator: " ")
        guard f.count >= 9, let rx = UInt64(f[0]), let tx = UInt64(f[8]) else { return nil }
        return (name, rx, tx)
    }

    /// Exclude loopback and per-container virtual links whose traffic is also counted on the
    /// physical NIC / bridge (otherwise container traffic would be counted two or three times).
    static func countsInterface(_ name: String) -> Bool {
        if name == "lo" { return false }
        for p in ["veth", "docker", "br-", "virbr", "cni", "flannel", "cali", "vxlan"] where name.hasPrefix(p) {
            return false
        }
        return true
    }

    private static let pseudoFS: Set<String> = ["tmpfs", "devtmpfs", "overlay", "squashfs", "efivarfs",
                                                 "udev", "none", "shm", "cgroup", "cgroup2", "proc",
                                                 "sysfs", "devpts", "run", "rootfs"]

    static func skipMount(_ m: String) -> Bool {
        if m.hasPrefix("/boot") || m.hasPrefix("/snap") || m.hasPrefix("/run") { return true }
        for p in ["/dev", "/sys", "/proc"] where m == p || m.hasPrefix(p + "/") { return true }
        return m.hasPrefix("/var/lib/docker/") || m.hasPrefix("/var/snap/")
    }

    /// `df -P` lines: "Filesystem 1-blocks Used Available Capacity Mounted on" + one row per fs.
    /// Skips /boot*, /snap*, /run* (+ /dev, /sys, /proc for the df -Pk fallback), pseudo
    /// filesystems, zero-sized ones, and duplicate mounts of the same device (shortest mount wins).
    static func disks(fromDF lines: [String], multiplier: UInt64) -> [RemoteDisk] {
        var byDevice: [String: RemoteDisk] = [:]
        var order: [String] = []
        for line in lines {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 6, f[0] != "Filesystem",
                  let blocks = UInt64(f[1]), let used = UInt64(f[2]), let avail = UInt64(f[3]) else { continue }
            let device = String(f[0])
            let mount = f[5...].joined(separator: " ")   // mount points may contain spaces
            guard mount.hasPrefix("/"), blocks > 0, !pseudoFS.contains(device) else { continue }
            if mount != "/" && skipMount(mount) { continue }
            let disk = RemoteDisk(mount: mount, device: device,
                                  total: blocks &* multiplier, used: used &* multiplier,
                                  free: avail &* multiplier)
            if let existing = byDevice[device] {
                if mount.count < existing.mount.count { byDevice[device] = disk }
            } else {
                byDevice[device] = disk
                order.append(device)
            }
        }
        var result = order.compactMap { byDevice[$0] }
        if let i = result.firstIndex(where: { $0.mount == "/" }), i > 0 {
            result.insert(result.remove(at: i), at: 0)
        }
        return result
    }
}

// MARK: - Derived metrics (deltas between consecutive samples)

struct RemoteSnapshot: Equatable {
    var hostname: String?
    var hasData = false
    var cpu: Double = 0                 // 0...1
    var memUsed: UInt64 = 0             // bytes
    var memTotal: UInt64 = 0            // bytes
    var disks: [RemoteDisk] = []
    var netIn: Double = 0               // bytes/s
    var netOut: Double = 0              // bytes/s
    var load: [Double] = []             // 1, 5, 15 min

    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
}

struct RemoteMetrics {
    private var prevCPU: (total: UInt64, idle: UInt64)?
    private var prevNet: (rx: UInt64, tx: UInt64, time: Double)?

    /// Forget baselines (call when a new ssh connection starts).
    mutating func resetBaselines() { prevCPU = nil; prevNet = nil }

    mutating func apply(_ r: RawSample, to s: inout RemoteSnapshot) {
        if let total = r.cpuTotal, let idle = r.cpuIdle {
            if let p = prevCPU, total > p.total {
                let dt = total - p.total
                let di = idle >= p.idle ? idle - p.idle : 0
                s.cpu = min(1, max(0, 1 - Double(di) / Double(dt)))
            }
            prevCPU = (total, idle)
        }
        if let total = r.memTotal, total > 0 {
            s.memTotal = total
            if let avail = r.memAvailable { s.memUsed = avail < total ? total - avail : 0 }
        }
        if let disks = r.disks { s.disks = disks }
        if r.load.count == 3 { s.load = r.load }
        if let rx = r.netRx, let tx = r.netTx {
            let t = r.uptime ?? r.arrival
            if let p = prevNet, t > p.time {
                let dt = t - p.time
                s.netIn = Double(rx >= p.rx ? rx - p.rx : 0) / dt     // clamp counter resets
                s.netOut = Double(tx >= p.tx ? tx - p.tx : 0) / dt
            }
            prevNet = (rx, tx, t)
        }
        s.hasData = true
    }
}
