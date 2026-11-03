import Foundation

struct SourceCfg: Codable, Identifiable {
    enum Kind: String, Codable { case app, mic, system }
    var id = UUID()
    var kind: Kind
    var ref: String            // bundle id (app), device UID (mic), unused (system)
    var title: String
    var gain: Float = 1
    var muted = false
    var hearOriginal = false   // app only: keep playing on the normal output too
    var inCh = 2               // source channels: 2 for taps, the input device's channel count (max 8) for mics
    var routes: [UInt32] = [1, 2]   // per source channel: bitmask of the output channels it feeds

    // "hearOriginal" was renamed: configs from when the option was still in the UI could be stuck on "keep playing the app
    // on the speakers", which doubles every monitored sound (echo). The new key starts everyone muted, like Loopback.
    enum CodingKeys: String, CodingKey { case id, kind, ref, title, gain, muted, inCh, routes; case hearOriginal = "hearOriginalKeep" }

    init(kind: Kind, ref: String, title: String, inCh: Int = 2) {
        self.kind = kind; self.ref = ref; self.title = title
        self.inCh = Routing.clampIn(kind, inCh); routes = Routing.defaults(self.inCh)
    }
    init(from d: Decoder) throws {   // tolerant: older configs lack inCh / routes
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        ref = try c.decodeIfPresent(String.self, forKey: .ref) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ref
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        hearOriginal = try c.decodeIfPresent(Bool.self, forKey: .hearOriginal) ?? false
        inCh = Routing.clampIn(kind, try c.decodeIfPresent(Int.self, forKey: .inCh) ?? 2)
        routes = try c.decodeIfPresent([UInt32].self, forKey: .routes) ?? Routing.defaults(inCh)
    }
}

struct MonitorCfg: Codable, Identifiable {
    var id = UUID()
    var uid: String            // physical output device UID
    var name: String
    var gain: Float = 1
    var on = true
    var map = [0, 1]           // physical L / R <- device output channel index (-1 = nothing)

    init(uid: String, name: String, gain: Float = 1) { self.uid = uid; self.name = name; self.gain = gain }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        uid = try c.decode(String.self, forKey: .uid)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? uid
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
        map = try c.decodeIfPresent([Int].self, forKey: .map) ?? [0, 1]
    }
}

struct VDev: Codable, Identifiable {
    static let maxPairs = 8
    var id = UUID()
    var name: String
    var enabled = true
    var volume: Float = 1      // master volume of the device (0...1)
    var sources: [SourceCfg] = []
    var monitors: [MonitorCfg] = []
    var slot = -1              // driver slot -> UID "soundrouter.<slot>"; stable when other devices are deleted
    var pairs = 1              // output channels = 2 * pairs (published by the driver)

    var uid: String { "soundrouter.\(slot)" }
    var channels: Int { pairs * 2 }
    /// Name as published by the driver: never empty (an empty line means "unused slot"), short enough for its 127-byte buffer.
    var sysName: String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\t", with: " ")
        return t.isEmpty ? "SoundRouter \(slot + 1)" : String(t.prefix(30))
    }
    /// devices.txt line: "name", or "name<TAB>channels" when not stereo (old drivers keep reading plain names).
    var driverLine: String { channels == 2 ? sysName : "\(sysName)\t\(channels)" }

    init(name: String, slot: Int = 0) { self.name = name; self.slot = slot }
    init(from d: Decoder) throws {   // tolerant: older config files lack the newer keys
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        sources = try c.decodeIfPresent([SourceCfg].self, forKey: .sources) ?? []
        monitors = try c.decodeIfPresent([MonitorCfg].self, forKey: .monitors) ?? []
        slot = try c.decodeIfPresent(Int.self, forKey: .slot) ?? -1
        pairs = try c.decodeIfPresent(Int.self, forKey: .pairs) ?? 1
    }

    /// Repair anything a hand-edited or older config can get wrong.
    mutating func sanitize() {
        pairs = min(max(pairs, 1), Self.maxPairs)
        volume = min(max(volume, 0), 1)
        let all = UInt32((1 << channels) - 1)
        for i in sources.indices {
            sources[i].gain = min(max(sources[i].gain, 0), 1)   // volumes top out at 100% (older configs allowed up to 200%)
            sources[i].inCh = Routing.clampIn(sources[i].kind, sources[i].inCh)
            var r = Array(sources[i].routes.prefix(sources[i].inCh)).map { $0 & all }
            if r.count < sources[i].inCh { r += Routing.defaults(sources[i].inCh)[r.count...].map { $0 & all } }
            sources[i].routes = r
        }
        // feedback guard: a SoundRouter device is never a microphone source or a monitor of a device
        sources.removeAll { $0.kind == .mic && $0.ref.hasPrefix("soundrouter.") }
        monitors.removeAll { $0.uid.hasPrefix("soundrouter.") }
        for i in monitors.indices {
            monitors[i].gain = min(max(monitors[i].gain, 0), 1)
            var m = Array(monitors[i].map.prefix(2)); while m.count < 2 { m.append(m.count) }
            monitors[i].map = m.map { $0 >= 0 && $0 < channels ? $0 : -1 }
        }
    }
}

/// Source-channel -> output-channel routing as bitmasks (bit o = output channel o).
enum Routing {
    static let maxIn = 8
    static func clampIn(_ k: SourceCfg.Kind, _ n: Int) -> Int { k == .mic ? min(max(n, 1), maxIn) : 2 }
    /// 1 -> 1, 2 -> 2; a mono source feeds both channels of the first pair.
    static func defaults(_ inCh: Int) -> [UInt32] { inCh == 1 ? [3] : (0..<inCh).map { $0 < 2 ? 1 << UInt32($0) : 0 } }
    static func toggle(_ mask: UInt32, _ o: Int) -> UInt32 { mask ^ (1 << UInt32(o)) }
    static func has(_ mask: UInt32, _ o: Int) -> Bool { mask & (1 << UInt32(o)) != 0 }
    /// Remove output pair `p`: its routes vanish, higher channels move down by two.
    static func dropPair(_ mask: UInt32, _ p: Int) -> UInt32 {
        let lo = mask & ((1 << UInt32(2 * p)) - 1)
        return lo | ((mask >> UInt32(2 * p + 2)) << UInt32(2 * p))
    }
    static func dropPair(map: Int, _ p: Int) -> Int { map < 2 * p ? map : map < 2 * p + 2 ? -1 : map - 2 }
}

extension VDev {
    mutating func removePair(_ p: Int) {
        guard pairs > 1, p >= 0, p < pairs else { return }
        for i in sources.indices { sources[i].routes = sources[i].routes.map { Routing.dropPair($0, p) } }
        for i in monitors.indices { monitors[i].map = monitors[i].map.map { Routing.dropPair(map: $0, p) } }
        pairs -= 1
    }
}

/// First of `base`, "base 2", "base 3"... not in `taken`.
func uniqueName(_ base: String, taken: Set<String>) -> String {
    if !taken.contains(base) { return base }
    var n = 2; while taken.contains("\(base) \(n)") { n += 1 }
    return "\(base) \(n)"
}

/// config.json: {"version": 2, "devices": [...]}; version 1 was a bare array of devices.
enum ConfigFile {
    static let version = 2
    struct File: Codable { var version: Int; var devices: [VDev] }

    /// Never throws away a file it can't read: it is renamed to config.json.bak-<timestamp> first.
    static func load(_ url: URL, now: Date = Date()) -> [VDev] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        var devs: [VDev]
        if let f = try? dec.decode(File.self, from: data) { devs = f.devices }
        else if let old = try? dec.decode([VDev].self, from: data) { devs = old }
        else {
            let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
            try? FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".bak-" + fmt.string(from: now)))
            return []
        }
        if devs.contains(where: { $0.slot < 0 }) { for i in devs.indices { devs[i].slot = i } }   // config from before slots existed
        var seen = Set<Int>(), names = Set<String>()
        devs = devs.filter { $0.slot >= 0 && $0.slot < 8 && seen.insert($0.slot).inserted }
        for i in devs.indices {
            devs[i].sanitize()
            devs[i].name = uniqueName(devs[i].sysName, taken: names); names.insert(devs[i].name)
        }
        return devs
    }

    static func save(_ devs: [VDev], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(File(version: version, devices: devs)).write(to: url, options: .atomic)
    }
}
