// Views/StatusBar.swift (更新版 - 添加系统代理和 TUN 开关)
import SwiftUI

struct StatusBar: View {
    @ObservedObject var manager: ProxyManager
    let openWindow: (String) -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            // 第一行：基本信息和主开关
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(manager.activeConfig?.name ?? "未选择配置")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 6) {
                        Image(systemName: manager.status.icon)
                            .foregroundColor(manager.status.color)
                        Text(manager.status.text)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { manager.isRunning },
                        set: { isOn in
                            if isOn {
                                manager.start()
                            } else {
                                manager.stop()
                            }
                        }
                    ))
                    .toggleStyle(SwitchToggleStyle())
                    .scaleEffect(1.2)
                    
                    Button(action: {
                        openWindow("logs")
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                            Text("查看日志")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            
            // ✅ 新增：系统代理和 TUN 模式开关
            if manager.isRunning {
                Divider()
                
                HStack(spacing: 20) {
                    // 系统代理开关
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "network")
                                .foregroundColor(manager.systemProxyEnabled ? .green : .gray)
                                .font(.title3)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("全局代理")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Text(manager.systemProxyEnabled ? "已启用" : "未启用")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: Binding(
                                get: { manager.systemProxyEnabled },
                                set: { _ in
                                    manager.toggleSystemProxy()
                                }
                            ))
                            .toggleStyle(SwitchToggleStyle())
                            .labelsHidden()
                        }
                        
                        if manager.systemProxyEnabled {
                            Text("系统流量已通过代理")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(manager.systemProxyEnabled ? Color.green : Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    
                    // TUN 模式开关
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "network.badge.shield.half.filled")
                                .foregroundColor(manager.tunModeEnabled ? .blue : .gray)
                                .font(.title3)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("TUN 模式")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Text(manager.tunModeEnabled ? "已启用" : "未启用")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: Binding(
                                get: { manager.tunModeEnabled },
                                set: { _ in
                                    manager.toggleTUNMode()
                                }
                            ))
                            .toggleStyle(SwitchToggleStyle())
                            .labelsHidden()
                        }
                        
                        if manager.tunModeEnabled {
                            Text("虚拟网卡已激活")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(manager.tunModeEnabled ? Color.blue : Color.gray.opacity(0.3), lineWidth: 1)
                    )
                }
            }
            
            if manager.isRunning {
                Divider()
                
                VStack(spacing: 12) {
                    HStack(spacing: 30) {
                        TrafficLabel(
                            icon: "arrow.up.circle.fill",
                            title: "上传",
                            value: manager.trafficUp,
                            color: .blue
                        )
                        
                        TrafficLabel(
                            icon: "arrow.down.circle.fill",
                            title: "下载",
                            value: manager.trafficDown,
                            color: .green
                        )
                    }
                    
                    if let config = manager.activeConfig {
                        HStack(spacing: 20) {
                            PortInfoView(label: "SOCKS5", port: config.socksPort)
                            PortInfoView(label: "HTTP", port: config.httpPort)
                            PortInfoView(label: "服务器", port: config.serverPort)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct TrafficLabel: View {
    let icon: String
    let title: String
    let value: Double
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(formatSpeed(value))
                .font(.system(.body, design: .rounded))
                .fontWeight(.medium)
                .foregroundColor(.primary)
        }
    }
    
    private func formatSpeed(_ kbps: Double) -> String {
        if kbps < 1 {
            return String(format: "%.0f B/s", kbps * 1024)
        } else if kbps < 1024 {
            return String(format: "%.1f KB/s", kbps)
        } else {
            return String(format: "%.2f MB/s", kbps / 1024)
        }
    }
}

struct PortInfoView: View {
    let label: String
    let port: Int
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .fontWeight(.medium)
            Text(":")
            Text("\(port)")
                .fontWeight(.semibold)
        }
    }
}
