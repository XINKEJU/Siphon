import SwiftUI

/// 速度 tab（乌龟模式 / 全局限速 / 快速设置）。
struct SpeedSettingsView: View {
    @Environment(DownloadStore.self) private var store
    @State private var limitText = ""

    var body: some View {
        Form {
            Section("乌龟模式（三档限速）") {
                Picker("模式", selection: Binding(
                    get: { store.turtleConfig.mode },
                    set: { store.turtleConfig.mode = $0 })) {
                    ForEach(TurtleMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                if store.turtleConfig.mode != .off {
                    HStack {
                        Text("限速")
                        TextField("字节/秒", value: Binding(
                            get: { store.turtleConfig.limitBytesPerSec },
                            set: { store.turtleConfig.limitBytesPerSec = $0 }),
                            format: .number)
                            .textFieldStyle(.roundedBorder)
                        Text("B/s").foregroundStyle(.secondary)
                    }
                }
                if store.turtleConfig.mode == .auto {
                    HStack {
                        Text("时段")
                        TextField("开始(分)", value: Binding(
                            get: { store.turtleConfig.autoStartMinutes },
                            set: { store.turtleConfig.autoStartMinutes = $0 }),
                            format: .number)
                            .textFieldStyle(.roundedBorder)
                        Text("–").foregroundStyle(.secondary)
                        TextField("结束(分)", value: Binding(
                            get: { store.turtleConfig.autoEndMinutes },
                            set: { store.turtleConfig.autoEndMinutes = $0 }),
                            format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("开始/结束为当日分钟数（如 1320=22:00，420=07:00），支持跨零点。仅此时段内限速。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("乌龟模式与全局限速叠加，取二者较小值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("全局限速") {
                HStack {
                    TextField("字节/秒", text: $limitText, prompt: Text("留空为不限速"))
                        .textFieldStyle(.roundedBorder)
                    Button("应用") { store.applySpeedLimit(limitText) }
                }
                Text("同时作用于 aria2（--max-overall-download-limit）与原生 HLS/DASH 引擎（令牌桶）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("快速设置") {
                GlassGroup(spacing: 8) {
                    ForEach(["", "524288", "1048576", "5242880"], id: \.self) { v in
                        Button(v.isEmpty ? "不限速" : Formatting.speed(Int64(v) ?? 0)) {
                            limitText = v
                            store.applySpeedLimit(v)
                        }
                        .controlSize(.small)
                        .glassButton()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { limitText = store.speedLimitText }
    }
}
