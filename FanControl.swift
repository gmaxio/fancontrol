//
//  FanControl.swift
//  FanControl - MacBook 菜单栏风扇曲线控制
//
//  对标 Macs Fan Control Pro: 温度->转速曲线 + 预设保存/切换 + GUI 设置
//  后端读取 App 内置 smc；写操作使用安装到系统受保护目录的 setuid root 副本。
//  配置与 fancontrol CLI 互通。
//

import Cocoa
import Foundation

// MARK: - 路径

let homeDir = FileManager.default.homeDirectoryForCurrentUser
// 测试/诊断时可用 FANCONTROL_CONFIG_DIR 覆盖；正常用户始终用 ~/.config/fancontrol。
let configDir: URL = {
    if let override = ProcessInfo.processInfo.environment["FANCONTROL_CONFIG_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return homeDir.appendingPathComponent(".config/fancontrol")
}()
let configFile = configDir.appendingPathComponent("config.json")
let presetsFile = configDir.appendingPathComponent("presets.json")
let pidFile = configDir.appendingPathComponent("fancontrol.pid")
let logFile = configDir.appendingPathComponent("app.log")
let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "开发版"

let privilegedSMCPath = "/Library/PrivilegedHelperTools/io.github.gmaxio.fancontrol.smc"

/// 读取不需要 root：优先用已安装助手，缺失时回退到 App 自带的 smc。
var readableSMCPath: String? {
    let env = ProcessInfo.processInfo.environment["FANCONTROL_SMC"]
    let bundled = Bundle.main.url(forResource: "smc", withExtension: nil)?.path
    let candidates: [String?] = [
        env,
        privilegedSMCPath,
        homeDir.appendingPathComponent(".fancontrol/bin/smc").path,
        "/usr/local/bin/smc",
        bundled,
    ]
    return candidates.compactMap { $0 }.first {
        FileManager.default.isExecutableFile(atPath: $0)
    }
}

func isSetuidRoot(_ path: String) -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let owner = attrs[.ownerAccountID] as? NSNumber,
          let permissions = attrs[.posixPermissions] as? NSNumber else { return false }
    return owner.intValue == 0 && (permissions.intValue & 0o4000) != 0
}

/// SMC 写入只能走 root 拥有且带 setuid 位的受信任副本。
var writableSMCPath: String? {
    let env = ProcessInfo.processInfo.environment["FANCONTROL_SMC"]
    if ProcessInfo.processInfo.environment["FANCONTROL_ALLOW_UNPRIVILEGED_WRITES"] == "1",
       let env, FileManager.default.isExecutableFile(atPath: env) {
        return env
    }
    let candidates = [
        privilegedSMCPath,
        homeDir.appendingPathComponent(".fancontrol/bin/smc").path,
        "/usr/local/bin/smc",
    ]
    return candidates.first { isSetuidRoot($0) }
}

// MARK: - 架构检测

let IS_ARM: Bool = {
    var u = utsname()
    uname(&u)
    let machine = withUnsafePointer(to: &u.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
    return machine == "arm64"
}()

let SENSOR_CHOICES_INTEL: [(String, String)] = [
    ("TC0P", "CPU Proximity"),
    ("TC0E", "CPU 核心 E"),
    ("TC0F", "CPU 核心 F"),
    ("TG0P", "GPU Proximity"),
    ("TB0T", "电池"),
]
let SENSOR_CHOICES_ARM: [(String, String)] = [
    ("Tp0P", "CPU/SoC Proximity"),
    ("Tp01", "传感器 Tp01"),
    ("Tp05", "传感器 Tp05"),
    ("Tp09", "传感器 Tp09"),
    ("Tp0D", "传感器 Tp0D"),
    ("TB0T", "电池"),
]
let SENSOR_CHOICES: [(String, String)] = IS_ARM ? SENSOR_CHOICES_ARM : SENSOR_CHOICES_INTEL

/// 传感器回退探测列表 (参考 smcFanControl/stats)
let SENSOR_FALLBACK_INTEL = ["TC0P", "TC0E", "TC0F", "TC0C", "TCAD", "TCAH", "TCBH"]
let SENSOR_FALLBACK_ARM = ["Tp0P", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H",
                           "Tp0L", "Tp0T", "Tp0X", "Tp0b"]
let SENSOR_FALLBACK = IS_ARM ? SENSOR_FALLBACK_ARM : SENSOR_FALLBACK_INTEL

let FAN_LABELS = ["Left side", "Right side"]

// MARK: - 配置模型

struct PerFan: Codable {
    var mode: String             // "auto" | "fixed" | "curve"
    var sensor: String?
    var rpm: Double?
    var curve: [[Double]]?
}

struct Preset: Codable {
    var description: String?
    var sensor: String?
    var fans: [Int]?
    var curve: [[Double]]
    var perFan: [String: PerFan]?
}

struct RunningConfig {
    var activePreset: String = "balanced"
    var sensor: String = "TC0P"
    var interval: Double = 2.0
    var hysteresis: Double = 80
    var criticalTemp: Double = 95.0
}

struct FanInfo {
    let id: Int
    let rpm: Double
    let min: Double
    let max: Double
    let target: Double
    let mode: Int?  // 0=自动 1=手动
}

// MARK: - SMC 调用

struct SMCExecution {
    let output: String
    let status: Int32
}

func executeSMC(_ args: [String]) -> SMCExecution? {
    let isWrite = args.first == "-w"
    guard let executable = isWrite ? writableSMCPath : readableSMCPath else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return SMCExecution(
        output: String(data: data, encoding: .utf8) ?? "",
        status: p.terminationStatus
    )
}

@discardableResult
func runSMC(_ args: [String]) -> String? {
    guard let result = executeSMC(args), result.status == 0 else { return nil }
    return result.output
}

func smcProblemDescription() -> String? {
    guard readableSMCPath != nil else {
        return "缺少 SMC 组件。请重新安装完整分发包，或点击“安装控制组件”。"
    }
    guard let result = executeSMC(["-f"]) else {
        return "SMC 组件无法启动。"
    }
    guard result.status == 0 else {
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "SMC 组件无法读取本机硬件。" : detail
    }
    if !result.output.contains("风扇 0:") && !result.output.contains("风扇 1:") {
        return "没有从 SMC 读取到风扇。本机可能没有风扇，或当前系统版本不支持该接口。"
    }
    return nil
}

/// 从 App Resources 安装经过约束的 SMC 写入助手。
/// 管理员授权由 macOS 标准密码框完成；密码不会传入本应用。
func installBundledSMCHelper() -> (success: Bool, message: String) {
    guard let source = Bundle.main.url(forResource: "smc", withExtension: nil) else {
        return (false, "当前 App 不包含 SMC 组件，请使用完整安装包重新安装。")
    }
    let script = """
    on run argv
        set sourcePath to item 1 of argv
        set targetPath to item 2 of argv
        set installCommand to "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools && " & ¬
            "/usr/bin/install -o root -g wheel -m 4755 " & quoted form of sourcePath & " " & quoted form of targetPath
        do shell script installCommand with administrator privileges
    end run
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script, source.path, privilegedSMCPath]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
    } catch {
        return (false, "无法打开系统授权窗口：\(error.localizedDescription)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0, isSetuidRoot(privilegedSMCPath) else {
        let detail = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (false, detail?.isEmpty == false ? detail! : "授权被取消，或组件安装失败。")
    }
    return (true, "控制组件已安装。")
}

func readNumber(_ key: String) -> Double? {
    guard let out = runSMC(["-r", key]) else { return nil }
    guard let m = out.range(of: #"^-?\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
    return Double(out[m])
}

// MARK: - 风扇模式键与 Apple Silicon 解锁 (参考 stats)

var modeKeyCache: [Int: String] = [:]

/// Intel 用 F{id}Md; Apple Silicon 探测小写 F{id}md
func modeKey(_ fid: Int) -> String {
    if let k = modeKeyCache[fid] { return k }
    var key = "F\(fid)Md"
    if IS_ARM, readNumber("F\(fid)md") != nil {
        key = "F\(fid)md"
    }
    modeKeyCache[fid] = key
    return key
}

@discardableResult
func smcWriteRetry(_ key: String, _ value: Int, attempts: Int = 10, delayMicros: UInt32 = 50_000) -> Bool {
    for i in 0..<attempts {
        if runSMC(["-w", key, "\(value)"]) != nil { return true }
        if i < attempts - 1 { usleep(delayMicros) }
    }
    return false
}

/// Apple Silicon 解锁风扇控制 (Ftst 握手)
func unlockFanControl(_ fid: Int) -> Bool {
    let key = modeKey(fid)
    if readNumber(key) == 1 { return true }
    // 先尝试直接写模式键 (部分新机型无需 Ftst)
    if smcWriteRetry(key, 1, attempts: 2) { return true }
    // Ftst 解锁流程 (M1-M4)
    guard let ftst = readNumber("Ftst") else { return false }
    if Int(ftst) == 1 {
        return smcWriteRetry(key, 1, attempts: 20, delayMicros: 100_000)
    }
    guard smcWriteRetry("Ftst", 1, attempts: 100) else { return false }
    usleep(3_000_000)  // 等 thermalmonitord 让出控制权
    return smcWriteRetry(key, 1, attempts: 300, delayMicros: 100_000)
}

func readFans() -> [FanInfo] {
    guard let out = runSMC(["-f"]) else { return [] }
    var fans: [FanInfo] = []
    let pattern = #"风扇 (\d+): 当前=([\d.]+) RPM 最小=([\d.]+) 最大=([\d.]+) 目标=([\d.]+)"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = out as NSString
    for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
        let fid = ns.substring(with: m.range(at: 1))
        let id = Int(fid) ?? 0
        fans.append(FanInfo(
            id: id,
            rpm: Double(ns.substring(with: m.range(at: 2))) ?? 0,
            min: Double(ns.substring(with: m.range(at: 3))) ?? 0,
            max: Double(ns.substring(with: m.range(at: 4))) ?? 0,
            target: Double(ns.substring(with: m.range(at: 5))) ?? 0,
            mode: readNumber(modeKey(id)).map { Int($0) }
        ))
    }
    return fans
}

/// 传感器回退: 配置的读不出时按架构探测
var sensorFallbackCache: [String: String] = [:]
func resolveSensor(_ preferred: String) -> (String, Double)? {
    if let v = readNumber(preferred) { return (preferred, v) }
    if let cached = sensorFallbackCache[preferred], let v = readNumber(cached) {
        return (cached, v)
    }
    for s in SENSOR_FALLBACK {
        if let v = readNumber(s) {
            sensorFallbackCache[preferred] = s
            return (s, v)
        }
    }
    return nil
}

// MARK: - 曲线插值

func curveToRPM(_ curve: [[Double]], _ temp: Double) -> Double {
    let pts = curve.sorted { $0[0] < $1[0] }
    guard let first = pts.first, let last = pts.last else { return 0 }
    if temp <= first[0] { return first[1] }
    if temp >= last[0] { return last[1] }
    for i in 0..<(pts.count - 1) {
        let (t0, r0) = (pts[i][0], pts[i][1])
        let (t1, r1) = (pts[i + 1][0], pts[i + 1][1])
        if temp >= t0 && temp <= t1 {
            if t1 == t0 { return r1 }
            return r0 + (temp - t0) / (t1 - t0) * (r1 - r0)
        }
    }
    return last[1]
}

// MARK: - 配置读写

/// App bundle 内置的 DefaultPresets.json（分发包中的第一优先级保底）。
func bundledDefaultPresets() -> [String: Preset]? {
    guard let url = Bundle.main.url(forResource: "DefaultPresets", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          var presets = try? JSONDecoder().decode([String: Preset].self, from: data),
          !presets.isEmpty else { return nil }
    // 内置文件以 TC0P 写入；Apple Silicon 改为其标准首选键，仍保留回退探测。
    if IS_ARM {
        for (name, var preset) in presets {
            preset.sensor = "Tp0P"
            presets[name] = preset
        }
    }
    return presets
}

/// 新机器的代码级第二保底。目标转速会自动钳制到每台机器实际的 min/max，
/// 所以同一组预设能安全用于 Intel 和 Apple Silicon、1/2/多风扇机型。
func defaultPresets() -> [String: Preset] {
    let sensor = IS_ARM ? "Tp0P" : "TC0P"
    return bundledDefaultPresets() ?? [
        "balanced": Preset(
            description: "均衡：低温安静，高温积极",
            sensor: sensor, fans: nil,
            curve: [[45, 2200], [60, 3000], [70, 4000], [80, 5000], [90, 10000]],
            perFan: nil),
        "silent": Preset(
            description: "静音优先：尽量低转",
            sensor: sensor, fans: nil,
            curve: [[55, 1800], [70, 2800], [80, 3600], [90, 10000]],
            perFan: nil),
        "performance": Preset(
            description: "性能优先：提前提高转速",
            sensor: sensor, fans: nil,
            curve: [[40, 2600], [55, 3600], [65, 4600], [75, 10000]],
            perFan: nil),
        "full-blast": Preset(
            description: "全速运转",
            sensor: sensor, fans: nil,
            curve: [[0, 10000]],
            perFan: nil),
    ]
}

func loadPresets() -> [String: Preset] {
    if let data = try? Data(contentsOf: presetsFile),
       let presets = try? JSONDecoder().decode([String: Preset].self, from: data),
       !presets.isEmpty {
        return presets
    }
    // 新安装直接打开 App 时并没有 CLI 替它创建 presets.json；在这里自举。
    let presets = defaultPresets()
    savePresets(presets)
    return presets
}

func savePresets(_ presets: [String: Preset]) {
    guard let data = try? JSONEncoder().encode(presets) else { return }
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try? data.write(to: presetsFile, options: .atomic)
}

func loadConfig() -> RunningConfig {
    var cfg = RunningConfig()
    guard let data = try? Data(contentsOf: configFile),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return cfg }
    if let v = obj["active_preset"] as? String { cfg.activePreset = v }
    if let v = obj["sensor"] as? String { cfg.sensor = v }
    if let v = obj["interval"] as? Double { cfg.interval = v }
    if let v = obj["hysteresis_rpm"] as? Double { cfg.hysteresis = v }
    if let v = obj["critical_temp"] as? Double { cfg.criticalTemp = v }
    return cfg
}

/// 首次启动自举默认配置文件；保留已有用户配置，不覆盖自定义预设。
func ensureInitialConfiguration() {
    _ = loadPresets()  // 缺失或空文件时会写入 4 个内置预设
    guard !FileManager.default.fileExists(atPath: configFile.path) else { return }
    let sensor = IS_ARM ? "Tp0P" : "TC0P"
    let config: [String: Any] = [
        "active_preset": "balanced",
        "sensor": sensor,
        "interval": 2.0,
        "hysteresis_rpm": 80,
        "critical_temp": 95.0,
        "restore_auto_on_exit": true,
    ]
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: configFile, options: .atomic)
    }
}

func saveActivePreset(_ name: String) {
    var obj: [String: Any] = [:]
    if let data = try? Data(contentsOf: configFile),
       let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        obj = o
    }
    obj["active_preset"] = name
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: configFile, options: .atomic)
    }
}

// MARK: - 温控器

class Controller {
    var enabled = true
    var lastTarget: [Int: Double] = [:]
    var touched = Set<Int>()
    var presetName = "-"
    var lastTemp: Double?
    var lastFans: [FanInfo] = []

    func log(_ msg: String) {
        let line = "\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) \(msg)\n"
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: logFile)
        }
    }

    /// 接管风扇到手动模式 (Apple Silicon 走 Ftst 解锁)
    func ensureManual(_ fid: Int, currentMode: Int?) -> Bool {
        if currentMode == 1 { return true }
        if IS_ARM { return unlockFanControl(fid) }
        return smcWriteRetry("F\(fid)Md", 1, attempts: 2)
    }

    /// 把风扇还给系统自动控制
    @discardableResult
    func releaseToAuto(_ fid: Int) -> Bool {
        if IS_ARM {
            let ok = smcWriteRetry(modeKey(fid), 0)
            smcWriteRetry("F\(fid)Tg", 0, attempts: 5)
            if readNumber("Ftst") == 1 { smcWriteRetry("Ftst", 0) }
            return ok
        }
        return smcWriteRetry("F\(fid)Md", 0, attempts: 2)
    }

    /// 每个 tick 重新加载配置(CLI 改动实时生效)
    func tick() {
        let cfg = loadConfig()
        let presets = loadPresets()
        lastFans = readFans()
        guard enabled, let preset = presets[cfg.activePreset] else {
            presetName = enabled ? "无有效预设" : "已暂停"
            return
        }
        presetName = cfg.activePreset
        let fmap = Dictionary(uniqueKeysWithValues: lastFans.map { ($0.id, $0) })
        let fanIDs = preset.fans ?? lastFans.map { $0.id }

        // 温度缓存: 同一 tick 内同传感器只读一次
        var tempCache: [String: Double] = [:]
        func tempOf(_ sensor: String) -> Double? {
            if let t = tempCache[sensor] { return t }
            let t = resolveSensor(sensor)?.1
            tempCache[sensor] = t
            return t
        }

        let sharedSensor = preset.sensor ?? cfg.sensor
        lastTemp = tempOf(sharedSensor)

        for fid in fanIDs {
            guard let f = fmap[fid] else { continue }
            // 确定该风扇的控制目标 (nil = 交给系统)
            var wantRPM: Double? = nil

            if let perFan = preset.perFan, let fc = perFan["\(fid)"] {
                switch fc.mode {
                case "fixed":
                    wantRPM = fc.rpm
                case "curve":
                    let sensor = fc.sensor ?? sharedSensor
                    if let curve = fc.curve, let t = tempOf(sensor) {
                        wantRPM = t >= cfg.criticalTemp ? f.max : curveToRPM(curve, t)
                    }
                default:  // "auto"
                    wantRPM = nil
                }
            } else if let t = lastTemp {
                wantRPM = t >= cfg.criticalTemp ? f.max : curveToRPM(preset.curve, t)
            }

            if let want = wantRPM {
                let tgt = Swift.max(f.min, Swift.min(f.max, want))
                if let last = lastTarget[fid], abs(tgt - last) < cfg.hysteresis { continue }
                guard ensureManual(fid, currentMode: f.mode) else {
                    log("风扇 \(fid) 无法进入手动模式")
                    continue
                }
                if IS_ARM {
                    guard smcWriteRetry("F\(fid)Tg", Int(tgt)) else { continue }
                } else {
                    runSMC(["-w", "F\(fid)Tg", "\(Int(tgt))"])
                }
                lastTarget[fid] = tgt
                touched.insert(fid)
            } else {
                // 该风扇设为自动: 若之前被我们接管过, 归还系统
                if touched.contains(fid) {
                    releaseToAuto(fid)
                    touched.remove(fid)
                    lastTarget.removeValue(forKey: fid)
                    log("风扇 \(fid) 切换为系统自动控制")
                }
            }
        }
    }

    func restoreAll() {
        for fid in touched.sorted() {
            releaseToAuto(fid)
            log("风扇 \(fid) 恢复系统自动控制")
        }
        touched.removeAll()
        lastTarget.removeAll()
    }

    /// 停掉可能在跑的 CLI 后台服务, 避免抢控制权
    func stopCLIService() {
        guard let data = try? Data(contentsOf: pidFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = obj["pid"] as? Int else { return }
        if kill(pid_t(pid), 0) == 0 {
            kill(pid_t(pid), SIGTERM)
            log("已停止 CLI 后台服务 (pid \(pid))")
        }
    }
}

// MARK: - 信号处理 (self-pipe 模式: 信号处理器只做 async-signal-safe 的 write)

private var gTermPipe: [Int32] = [0, 0]

func installTermHandler(onTerm: @escaping () -> Void) -> DispatchSourceRead {
    pipe(&gTermPipe)
    var sa = sigaction()
    sigemptyset(&sa.sa_mask)
    sa.__sigaction_u.__sa_handler = { _ in
        _ = Darwin.write(gTermPipe[1], "x", 1)
    }
    sigaction(SIGTERM, &sa, nil)
    sigaction(SIGINT, &sa, nil)
    let src = DispatchSource.makeReadSource(fileDescriptor: gTermPipe[0], queue: .main)
    src.setEventHandler {
        var buf = [UInt8](repeating: 0, count: 8)
        _ = Darwin.read(gTermPipe[0], &buf, buf.count)
        onTerm()
    }
    src.resume()
    return src
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let controller = Controller()
    var timer: Timer?
    let agentLabel = "io.github.gmaxio.fancontrol.app"
    var sigReadSource: DispatchSourceRead?  // 持有, 防止 ARC 释放

    // 动态菜单项
    let tempItem = NSMenuItem(title: "温度: -", action: nil, keyEquivalent: "")
    let fan0Item = NSMenuItem(title: "风扇 0: -", action: nil, keyEquivalent: "")
    let fan1Item = NSMenuItem(title: "风扇 1: -", action: nil, keyEquivalent: "")
    let presetMenu = NSMenu()
    let toggleItem = NSMenuItem(title: "温控: 开", action: #selector(toggleControl), keyEquivalent: "t")
    let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
    let installHelperItem = NSMenuItem(
        title: "安装控制组件…",
        action: #selector(installSMCFromMenu),
        keyEquivalent: ""
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        ensureInitialConfiguration()  // 新机器只打开 App 时也必须有内置预设
        checkConflicts()
        controller.stopCLIService()
        // 未安装特权助手时仍可用 App 内置 smc 读取硬件，但不能接管风扇。
        controller.enabled = writableSMCPath != nil

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 菜单栏只显示风扇图标 (bundle 资源, template 模式自动适配深浅菜单栏)
        if let icon = NSImage(named: "menubar_icon") {
            icon.isTemplate = true
            statusItem.button?.image = icon
        }
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(tempItem)
        menu.addItem(fan0Item)
        menu.addItem(fan1Item)
        menu.addItem(.separator())

        let presetItem = NSMenuItem(title: "预设", action: nil, keyEquivalent: "")
        presetMenu.delegate = self   // 关键: 子菜单也要设 delegate, 否则 menuWillOpen 不触发
        presetItem.submenu = presetMenu
        menu.addItem(presetItem)
        rebuildPresetMenu()          // 启动时先填一次, 保证子菜单不为空
        let restoreItem = NSMenuItem(title: "恢复内置预设…", action: #selector(restoreBuiltinPresets), keyEquivalent: "")
        restoreItem.target = self
        menu.addItem(restoreItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "风扇设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        installHelperItem.target = self
        menu.addItem(installHelperItem)
        toggleItem.target = self
        menu.addItem(toggleItem)
        loginItem.target = self
        loginItem.state = loginAgentExists() ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let versionItem = NSMenuItem(title: "FanControl v\(appVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let quitItem = NSMenuItem(title: "退出 FanControl", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        controller.tick()
        updateUI()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.controller.tick()
            self?.updateUI()
        }

        // 信号处理: 被 kill 时也恢复风扇自动 (self-pipe 模式)
        sigReadSource = installTermHandler { [weak self] in
            self?.cleanupAndExit()
        }

        repairLoginAgentIfNeeded()
        if writableSMCPath == nil &&
           ProcessInfo.processInfo.environment["FANCONTROL_SKIP_INSTALL_PROMPT"] != "1" {
            DispatchQueue.main.async { [weak self] in self?.promptToInstallSMC() }
        }
        handleDebugFlags()
    }

    // MARK: 调试入口

    /// --dump-menu: 打印预设子菜单内容后退出 (验证子菜单修复)
    /// --snapshot-settings <path>: 打开设置窗口并截图为 PNG 后退出 (验证 UI)
    func handleDebugFlags() {
        let args = CommandLine.arguments
        if args.contains("--dump-menu") {
            rebuildPresetMenu()
            print("预设子菜单项数: \(presetMenu.items.count)")
            for item in presetMenu.items {
                print(" - [\(item.state == .on ? "x" : " ")] \(item.title)")
            }
            exit(0)
        }
        if let idx = args.firstIndex(of: "--snapshot-settings"), idx + 1 < args.count {
            let path = args[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { exit(1) }
                SettingsWindowManager.shared.show(controller: self.controller)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    SettingsWindowManager.shared.snapshot(to: path)
                    exit(0)
                }
            }
        }
    }

    func checkConflicts() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "Macs Fan Control"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus == 0 {
            let a = NSAlert()
            a.messageText = "检测到 Macs Fan Control 正在运行"
            a.informativeText = "两者会争夺风扇控制权, 建议先退出 Macs Fan Control。"
            a.alertStyle = .warning
            a.addButton(withTitle: "知道了")
            a.runModal()
        }
    }

    // MARK: UI 刷新

    func updateUI() {
        let c = controller
        if let t = c.lastTemp {
            tempItem.title = String(format: "CPU: %.1f°C  (%@)", t, c.presetName)
        } else {
            tempItem.title = "CPU: 读取中…"
        }
        for (i, item) in [fan0Item, fan1Item].enumerated() {
            if i < c.lastFans.count {
                let f = c.lastFans[i]
                let mode = f.mode == 1 ? "手动" : "自动"
                item.title = String(format: "风扇 %d: %.0f RPM (%@)", f.id, f.rpm, mode)
                item.isHidden = false
            } else {
                item.isHidden = true
            }
        }
        toggleItem.title = c.enabled ? "温控: 开" : "温控: 关 (风扇自动)"
        installHelperItem.isHidden = writableSMCPath != nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === presetMenu { rebuildPresetMenu() }
        updateUI()
    }

    func rebuildPresetMenu() {
        presetMenu.removeAllItems()
        let cfg = loadConfig()
        for (name, _) in loadPresets().sorted(by: { $0.key < $1.key }) {
            let item = NSMenuItem(title: name,
                                  action: #selector(applyPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = (name == cfg.activePreset) ? .on : .off
            presetMenu.addItem(item)
        }
    }

    // MARK: 动作

    @objc func applyPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        guard ensureWritableSMC() else { return }
        saveActivePreset(name)
        controller.lastTarget.removeAll()  // 立即按新曲线调速
        controller.enabled = true
        controller.tick()
        updateUI()
    }

    @objc func restoreBuiltinPresets() {
        let alert = NSAlert()
        alert.messageText = "恢复内置预设？"
        alert.informativeText = "将恢复 balanced、silent、performance、full-blast，并移除自定义预设。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        savePresets(defaultPresets())
        saveActivePreset("balanced")
        controller.lastTarget.removeAll()
        controller.enabled = true
        controller.tick()
        rebuildPresetMenu()
        updateUI()
    }

    @objc func openSettings() {
        SettingsWindowManager.shared.show(controller: controller)
    }

    @objc func toggleControl() {
        if !controller.enabled, !ensureWritableSMC() { return }
        controller.enabled.toggle()
        if !controller.enabled {
            controller.restoreAll()
        } else {
            controller.lastTarget.removeAll()
            controller.tick()
        }
        updateUI()
    }

    @objc func installSMCFromMenu() {
        _ = ensureWritableSMC()
    }

    func promptToInstallSMC() {
        let alert = NSAlert()
        alert.messageText = "需要安装风扇控制组件"
        alert.informativeText = """
        FanControl 已能读取到本机风扇，但更改转速需要安装一个受保护的系统组件。
        macOS 将显示管理员授权窗口。取消后仍可查看风扇信息。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            _ = ensureWritableSMC(showIntro: false)
        }
    }

    @discardableResult
    func ensureWritableSMC(showIntro: Bool = true) -> Bool {
        if writableSMCPath != nil { return true }
        if showIntro {
            let alert = NSAlert()
            alert.messageText = "安装控制组件"
            alert.informativeText = "更改风扇转速需要管理员授权；组件只允许写入风扇相关的 SMC 键。"
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        let result = installBundledSMCHelper()
        if result.success {
            controller.enabled = true
            controller.lastTarget.removeAll()
            controller.tick()
            updateUI()
            return true
        }
        let alert = NSAlert()
        alert.messageText = "控制组件安装失败"
        alert.informativeText = result.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
        return false
    }

    @objc func toggleLogin() {
        let path = homeDir.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
        if loginItem.state == .on {
            launchctl(["unload", path.path])
            try? FileManager.default.removeItem(at: path)
            loginItem.state = .off
        } else {
            guard writeLoginAgent(to: path) else { return }
            launchctl(["load", path.path])
            loginItem.state = .on
        }
    }

    func preferredAppBundlePath() -> String {
        let installed = "/Applications/FanControl.app"
        if let bundle = Bundle(path: installed),
           bundle.bundleIdentifier == "io.github.gmaxio.fancontrol" {
            return installed
        }
        return Bundle.main.bundlePath
    }

    @discardableResult
    func writeLoginAgent(to path: URL) -> Bool {
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-g", preferredAppBundlePath()],
            "RunAtLoad": true,
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: path, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 旧版本可能把 App Translocation 临时路径写进 LaunchAgent；启动时自动纠正。
    func repairLoginAgentIfNeeded() {
        let path = homeDir.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
        guard let data = try? Data(contentsOf: path),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return }
        let expected = preferredAppBundlePath()
        guard args.count < 3 || args[2] != expected else { return }
        launchctl(["unload", path.path])
        if writeLoginAgent(to: path) {
            launchctl(["load", path.path])
        }
    }

    func loginAgentExists() -> Bool {
        FileManager.default.fileExists(
            atPath: homeDir.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist").path)
    }

    func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    @objc func quitApp() {
        cleanupAndExit()
    }

    func cleanupAndExit() {
        controller.log("退出: 恢复风扇系统自动控制")
        controller.restoreAll()
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.restoreAll()
    }
}

@main
final class FanControlApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // 无 Dock 图标的菜单栏应用
        app.run()
    }
}
