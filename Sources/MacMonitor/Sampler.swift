import Foundation
import Darwin

struct Volume: Identifiable, Equatable {
    var id: String          // mount path
    var name: String
    var free: Int64
    var total: Int64
    var usedFraction: Double { total > 0 ? 1 - Double(free) / Double(total) : 0 }
}

/// One immutable snapshot published per tick (single objectWillChange per second).
struct Snapshot {
    var cpu: Double = 0                 // 0...1
    var cpuHistory: [Double] = Array(repeating: 0, count: 60)
    var memUsed: UInt64 = 0             // bytes
    var memTotal: UInt64 = 0            // bytes
    var diskFree: Int64 = 0             // bytes
    var diskTotal: Int64 = 0            // bytes
    var volumes: [Volume] = []          // boot volume first, then other local disks
    var netIn: Double = 0               // bytes/s
    var netOut: Double = 0              // bytes/s

    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    var diskUsedFraction: Double {
        diskTotal > 0 ? 1 - Double(diskFree) / Double(diskTotal) : 0
    }
}

@MainActor
final class Sampler: NSObject, ObservableObject {
    @Published private(set) var snapshot = Snapshot()

    /// Called on the main thread after every tick (used for the status bar title).
    var onTick: ((Snapshot) -> Void)?

    private let host: host_t = mach_host_self()   // cached: mach_host_self() leaks a port ref per call
    private var timer: Timer?
    private var tickCount = 0

    // CPU state: previous per-core ticks, flattened [user, system, idle, nice] * cores
    private var prevCPUTicks: [UInt32] = []

    // Memory
    private let pageSize = UInt64(vm_kernel_page_size)
    private let memTotal: UInt64 = Sampler.physicalMemory()

    // Network
    private var netMIB: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    private var netBuf = [UInt8]()
    private var prevNetIn: UInt64 = 0
    private var prevNetOut: UInt64 = 0
    private var prevNetTime: TimeInterval = 0
    private var hasNetBaseline = false

    override init() {
        super.init()
        snapshot.memTotal = memTotal
        _ = sampleCPU()          // establish CPU baseline
        sampleDisk(into: &snapshot)
        tick()
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)   // keep firing while the menu is open
        timer = t
    }

    @objc private func tick() {
        var s = snapshot                       // copy, mutate, publish once
        tickCount &+= 1

        if let c = sampleCPU() { s.cpu = c }
        s.cpuHistory.removeFirst()
        s.cpuHistory.append(s.cpu)

        sampleMemory(into: &s)
        sampleNetwork(into: &s)
        if tickCount % 10 == 0 { sampleDisk(into: &s) }

        snapshot = s
        onTick?(s)
    }

    // MARK: CPU

    /// Returns total CPU busy fraction since the previous call, or nil on first call / failure.
    private func sampleCPU() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info = info else { return nil }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        let states = Int(CPU_STATE_MAX)
        let n = Int(cpuCount) * states
        let hadBaseline = prevCPUTicks.count == n
        if !hadBaseline { prevCPUTicks = [UInt32](repeating: 0, count: n) }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        for core in 0..<Int(cpuCount) {
            let base = core * states
            for state in 0..<states {
                let now = UInt32(bitPattern: info[base + state])
                let delta = UInt64(now &- prevCPUTicks[base + state])   // wrap-safe
                prevCPUTicks[base + state] = now
                total &+= delta
                if state != Int(CPU_STATE_IDLE) { busy &+= delta }
            }
        }
        guard hadBaseline, total > 0 else { return nil }
        return min(1, Double(busy) / Double(total))
    }

    // MARK: Memory

    private func sampleMemory(into s: inout Snapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count)
                  + UInt64(stats.compressor_page_count)
        s.memUsed = min(pages * pageSize, memTotal)
        s.memTotal = memTotal
    }

    nonisolated private static func physicalMemory() -> UInt64 {
        var value: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &value, &len, nil, 0) != 0 || value == 0 {
            return ProcessInfo.processInfo.physicalMemory
        }
        return value
    }

    // MARK: Disk (boot volume, every 30 s)

    private func sampleDisk(into s: inout Snapshot) {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsBrowsableKey,
                                      .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var vols: [Volume] = []
        for url in urls {
            // Fresh URL so cached resource values are not reused.
            let fresh = URL(fileURLWithPath: url.path)
            guard let v = try? fresh.resourceValues(forKeys: Set(keys)) else { continue }
            let isRoot = v.volumeIsRootFileSystem ?? (url.path == "/")
            guard isRoot || ((v.volumeIsBrowsable ?? false) && (v.volumeIsLocal ?? false)) else { continue }
            guard let total = v.volumeTotalCapacity, total > 0 else { continue }
            var free: Int64 = v.volumeAvailableCapacityForImportantUsage ?? 0
            if free <= 0, let a = v.volumeAvailableCapacity { free = Int64(a) }
            let vol = Volume(id: url.path, name: v.volumeName ?? url.lastPathComponent,
                             free: free, total: Int64(total))
            if isRoot { vols.insert(vol, at: 0) } else { vols.append(vol) }
        }
        s.volumes = vols
        if let boot = vols.first { s.diskFree = boot.free; s.diskTotal = boot.total }
    }

    // MARK: Network (sum of non-loopback interfaces, 64-bit counters)

    private func sampleNetwork(into s: inout Snapshot) {
        guard let counters = readInterfaceCounters() else { return }
        let inBytes = counters.0, outBytes = counters.1
        let now = ProcessInfo.processInfo.systemUptime
        if hasNetBaseline {
            let dt = now - prevNetTime
            if dt > 0 {
                // Counters can go backwards when an interface disappears; clamp to 0.
                let dIn = inBytes >= prevNetIn ? inBytes - prevNetIn : 0
                let dOut = outBytes >= prevNetOut ? outBytes - prevNetOut : 0
                s.netIn = Double(dIn) / dt
                s.netOut = Double(dOut) / dt
            }
        }
        prevNetIn = inBytes
        prevNetOut = outBytes
        prevNetTime = now
        hasNetBaseline = true
    }

    private func readInterfaceCounters() -> (UInt64, UInt64)? {
        let mibCount = u_int(6)
        var len = 0
        guard sysctl(&netMIB, mibCount, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        if netBuf.count < len {
            netBuf = [UInt8](repeating: 0, count: len + len / 4)   // headroom; reused afterwards
        }
        len = netBuf.count

        let rtmIFInfo2: UInt8 = 0x12   // RTM_IFINFO2 from <net/route.h>
        let hdrSize = MemoryLayout<if_msghdr>.size
        let msg2Size = MemoryLayout<if_msghdr2>.size
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        let ok = netBuf.withUnsafeMutableBytes { raw -> Bool in
            guard sysctl(&netMIB, mibCount, raw.baseAddress, &len, nil, 0) == 0 else { return false }
            var offset = 0
            while offset + hdrSize <= len {
                // Messages are only 4-byte aligned; if_data64 has UInt64 fields -> unaligned loads.
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                if msgLen <= 0 { break }
                if hdr.ifm_type == rtmIFInfo2, offset + msg2Size <= len {
                    let m = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if (m.ifm_flags & IFF_LOOPBACK) == 0 {
                        totalIn &+= m.ifm_data.ifi_ibytes
                        totalOut &+= m.ifm_data.ifi_obytes
                    }
                }
                offset += msgLen
            }
            return true
        }
        return ok ? (totalIn, totalOut) : nil
    }
}

// MARK: Formatting helpers (no formatter objects, cheap)

enum Fmt {
    static func gb(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1_073_741_824) }
    static func diskGB(_ bytes: Int64) -> String { String(format: "%.0f", Double(bytes) / 1_000_000_000) }
    static func pct(_ f: Double) -> String { String(format: "%.0f%%", f * 100) }

    static func rate(_ bytesPerSec: Double) -> String {
        let b = max(0, bytesPerSec)
        switch b {
        case ..<1_000:          return String(format: "%.0f B/s", b)
        case ..<1_000_000:      return String(format: "%.1f KB/s", b / 1_000)
        case ..<1_000_000_000:  return String(format: "%.1f MB/s", b / 1_000_000)
        default:                return String(format: "%.2f GB/s", b / 1_000_000_000)
        }
    }
}
