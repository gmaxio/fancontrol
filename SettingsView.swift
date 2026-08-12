//
//  SettingsView.swift
//  风扇设置窗口 (对标 Macs Fan Control 的交互)
//  每个风扇独立设置: 自动 / 固定转速 / 基于温度(传感器+温度区间+转速区间)
//

import Cocoa
import SwiftUI

// MARK: - 表单状态

final class FanFormState: ObservableObject {
    @Published var mode: Int = 2          // 0=自动 1=固定转速 2=基于温度
    @Published var fixedRPM: String = "3000"
    @Published var sensor: String = "TC0P"
    @Published var startTemp: String = "45"
    @Published var maxTemp: String = "90"
    @Published var startRPM: String = "2160"
    @Published var maxRPM: String = "5927"
}

final class SettingsModel: ObservableObject {
    @Published var fans: [FanFormState] = []
    @Published var hardwareError: String?
    @Published var needsHelper: Bool = false
    var fanIDs: [Int] = []
    var presetName: String = ""
}

// MARK: - SwiftUI 视图

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var fanLabels: [String]
    var onCancel: () -> Void
    var onInstall: () -> Void
    var onSaveAs: () -> Void
    var onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前预设: \(model.presetName)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let error = model.hardwareError {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("无法读取风扇", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                        Text(error)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("安装控制组件…", action: onInstall)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
            } else {
                if model.needsHelper {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                        Text("当前可查看风扇；更改转速前需要安装控制组件。")
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("安装…", action: onInstall)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(8)
                }

                ForEach(model.fans.indices, id: \.self) { i in
                    FanSection(state: model.fans[i],
                               label: i < fanLabels.count ? fanLabels[i] : "风扇 \(i)")
                }
            }

            Divider()
            HStack {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("另存为新预设…", action: onSaveAs)
                    .disabled(model.fans.isEmpty)
                Button("应用", action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.fans.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}

struct FanSection: View {
    @ObservedObject var state: FanFormState
    let label: String

    var body: some View {
        GroupBox(label: Text(label).font(.headline)) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $state.mode) {
                    Text("自动 (系统控制)").tag(0)
                    Text("固定转速").tag(1)
                    Text("基于温度").tag(2)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if state.mode == 1 {
                    HStack {
                        Text("转速")
                            .frame(width: 130, alignment: .trailing)
                        TextField("RPM", text: $state.fixedRPM)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("RPM")
                    }
                }

                if state.mode == 2 {
                    HStack {
                        Text("传感器")
                            .frame(width: 130, alignment: .trailing)
                        Picker("", selection: $state.sensor) {
                            ForEach(SENSOR_CHOICES, id: \.0) { s in
                                Text("\(s.1) (\(s.0))").tag(s.0)
                            }
                        }
                        .labelsHidden()
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Text("高于此温度则提速")
                                .frame(width: 130, alignment: .trailing)
                            TextField("", text: $state.startTemp)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("°C")
                        }
                        GridRow {
                            Text("最高温度")
                                .frame(width: 130, alignment: .trailing)
                            TextField("", text: $state.maxTemp)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("°C")
                        }
                        GridRow {
                            Text("起始转速")
                                .frame(width: 130, alignment: .trailing)
                            TextField("", text: $state.startRPM)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("RPM")
                        }
                        GridRow {
                            Text("最高转速")
                                .frame(width: 130, alignment: .trailing)
                            TextField("", text: $state.maxRPM)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("RPM")
                        }
                    }
                    .padding(.leading, 24)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - 窗口管理

final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    var window: NSWindow?

    func show(controller: Controller) {
        // 已有窗口则前置
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let cfg = loadConfig()
        let presets = loadPresets()
        let fans = readFans()
        let model = SettingsModel()
        model.presetName = cfg.activePreset
        model.fanIDs = fans.map { $0.id }
        model.hardwareError = fans.isEmpty ? smcProblemDescription() ?? "没有检测到可用风扇。" : nil
        model.needsHelper = writableSMCPath == nil

        // 从激活预设加载现有配置到表单
        let preset = presets[cfg.activePreset]
        for f in fans {
            let st = FanFormState()
            if let fc = preset?.perFan?["\(f.id)"] {
                switch fc.mode {
                case "fixed":
                    st.mode = 1
                    let rpm = Swift.max(f.min, Swift.min(f.max, fc.rpm ?? f.min))
                    st.fixedRPM = "\(Int(rpm))"
                case "curve":
                    st.mode = 2
                    fillCurve(st, fc.curve, sensor: fc.sensor ?? preset?.sensor ?? "TC0P", f: f)
                default:
                    st.mode = 0
                }
            } else if let p = preset {
                st.mode = 2
                fillCurve(st, p.curve, sensor: p.sensor ?? "TC0P", f: f)
            }
            if st.fixedRPM.isEmpty { st.fixedRPM = "\(Int(f.min))" }
            model.fans.append(st)
        }

        let labels = fans.enumerated().map { (i, f) in
            i < FAN_LABELS.count ? "\(FAN_LABELS[i]) (风扇 \(f.id))" : "风扇 \(f.id)"
        }

        let view = SettingsView(
            model: model,
            fanLabels: labels,
            onCancel: { [weak self] in self?.window?.close() },
            onInstall: { [weak self] in
                let result = installBundledSMCHelper()
                guard result.success else {
                    self?.alertError(result.message)
                    return
                }
                controller.enabled = true
                controller.lastTarget.removeAll()
                controller.tick()
                model.needsHelper = false
                model.hardwareError = readFans().isEmpty ? smcProblemDescription() : nil
            },
            onSaveAs: { [weak self] in self?.saveAsNewPreset(model: model, controller: controller) },
            onApply: { [weak self] in
                if self?.applyChanges(model: model, controller: controller) == true {
                    self?.window?.close()
                }
            }
        )

        let hosting = NSHostingController(rootView: view)
        hosting.view.wantsLayer = true   // 保证 snapshot 可经 layer 渲染
        let w = NSWindow(contentViewController: hosting)
        w.title = "风扇设置"
        w.styleMask = [.titled, .closable]
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = WindowCloseDelegate.shared
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    private func fillCurve(_ st: FanFormState, _ curve: [[Double]]?, sensor: String, f: FanInfo) {
        // FanFormState 为类实例, 直接修改属性
        st.sensor = sensor
        let pts = (curve ?? []).sorted { $0[0] < $1[0] }
        if let first = pts.first, let last = pts.last {
            st.startTemp = "\(Int(first[0]))"
            st.maxTemp = "\(Int(last[0]))"
            let startRPM = Swift.max(f.min, Swift.min(f.max, first[1]))
            let maxRPM = Swift.max(f.min, Swift.min(f.max, last[1]))
            st.startRPM = "\(Int(startRPM))"
            st.maxRPM = "\(Int(maxRPM))"
        } else {
            st.startRPM = "\(Int(f.min))"
            st.maxRPM = "\(Int(f.max))"
        }
    }

    /// 校验表单 -> perFan 配置; 失败弹错误提示返回 nil
    private func buildPerFan(model: SettingsModel) -> [String: PerFan]? {
        let fans = readFans()
        var perFan: [String: PerFan] = [:]
        for (i, st) in model.fans.enumerated() {
            guard i < model.fanIDs.count else { continue }
            let fid = model.fanIDs[i]
            let f = fans.first { $0.id == fid }

            switch st.mode {
            case 0:
                perFan["\(fid)"] = PerFan(mode: "auto", sensor: nil, rpm: nil, curve: nil)
            case 1:
                guard let rpm = Double(st.fixedRPM), rpm > 0 else {
                    alertError("风扇 \(fid) 的固定转速无效")
                    return nil
                }
                perFan["\(fid)"] = PerFan(mode: "fixed", sensor: nil, rpm: rpm, curve: nil)
            default:
                guard let t0 = Double(st.startTemp), let t1 = Double(st.maxTemp),
                      let r0 = Double(st.startRPM), let r1 = Double(st.maxRPM) else {
                    alertError("风扇 \(fid) 的温度/转速必须是数字")
                    return nil
                }
                guard t0 < t1 else {
                    alertError("风扇 \(fid): 起始温度必须小于最高温度")
                    return nil
                }
                guard r0 > 0, r1 > 0 else {
                    alertError("风扇 \(fid): 转速必须大于 0")
                    return nil
                }
                if let f = f, (r0 < f.min * 0.5 || r1 > f.max * 1.2) {
                    alertError("风扇 \(fid): 转速建议在 \(Int(f.min))~\(Int(f.max)) RPM 之间")
                    return nil
                }
                perFan["\(fid)"] = PerFan(mode: "curve", sensor: st.sensor, rpm: nil,
                                          curve: [[t0, r0], [t1, r1]])
            }
        }
        return perFan
    }

    @discardableResult
    func applyChanges(model: SettingsModel, controller: Controller) -> Bool {
        guard writableSMCPath != nil else {
            alertError("请先安装控制组件，再应用风扇设置。")
            return false
        }
        guard let perFan = buildPerFan(model: model) else { return false }
        let cfg = loadConfig()
        var presets = loadPresets()
        guard var preset = presets[cfg.activePreset] else {
            alertError("当前预设不存在")
            return false
        }
        preset.perFan = perFan
        presets[cfg.activePreset] = preset
        savePresets(presets)
        // 立即生效
        controller.lastTarget.removeAll()
        controller.enabled = true
        controller.tick()
        controller.log("风扇设置已更新 (预设: \(cfg.activePreset))")
        return true
    }

    func saveAsNewPreset(model: SettingsModel, controller: Controller) {
        guard let perFan = buildPerFan(model: model) else { return }

        let a = NSAlert()
        a.messageText = "另存为新预设"
        a.informativeText = "输入新预设名称:"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = "我的配置"
        a.accessoryView = input
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var name = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        var presets = loadPresets()
        if presets[name] != nil { name += "-2" }
        // 共享曲线取风扇 0 的曲线 (供 CLI 展示), perFan 存完整配置
        let firstCurve = perFan["\(model.fanIDs.first ?? 0)"]?.curve ?? [[45, 2160], [90, 5927]]
        presets[name] = Preset(description: "自定义预设",
                               sensor: perFan["\(model.fanIDs.first ?? 0)"]?.sensor ?? "TC0P",
                               fans: model.fanIDs,
                               curve: firstCurve,
                               perFan: perFan)
        savePresets(presets)
        saveActivePreset(name)
        controller.lastTarget.removeAll()
        controller.enabled = true
        controller.tick()
        controller.log("已保存并激活新预设: \(name)")
        window?.close()
    }

    func snapshot(to path: String) {
        guard let w = window, let view = w.contentView else { return }
        var wrote = false

        // 首选: 渲染 layer 树 (SwiftUI hosting view 为 layer-backed)
        if let layer = view.layer {
            let scale: CGFloat = 2.0
            let pw = Int(view.bounds.width * scale), ph = Int(view.bounds.height * scale)
            if let ctx = CGContext(data: nil, width: pw, height: ph,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                // CGContext 原点在左下, 需翻转 Y 轴
                ctx.translateBy(x: 0, y: CGFloat(ph))
                ctx.scaleBy(x: scale, y: -scale)
                ctx.saveGState()
                layer.render(in: ctx)
                ctx.restoreGState()
                if let cg = ctx.makeImage() {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                        wrote = true
                    }
                }
            }
        }

        // 回退: 视图位图
        if !wrote {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    private func alertError(_ msg: String) {
        let a = NSAlert()
        a.messageText = "无法应用"
        a.informativeText = msg
        a.alertStyle = .warning
        a.addButton(withTitle: "好")
        a.runModal()
    }
}

/// 窗口关闭时清空引用
final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowCloseDelegate()
    func windowWillClose(_ notification: Notification) {
        SettingsWindowManager.shared.window = nil
    }
}
