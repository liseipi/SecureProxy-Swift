// ViewModels/TUNManager.swift
import Foundation
import NetworkExtension
import Combine

class TUNManager: ObservableObject {
    @Published var isEnabled = false
    @Published var statusMessage = ""
    
    private var tunnelManager: NETunnelProviderManager?
    
    init() {
        loadTunnelConfiguration()
    }
    
    /// 加载 TUN 配置
    private func loadTunnelConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            if let error = error {
                print("❌ 加载 TUN 配置失败: \(error)")
                return
            }
            
            // 查找或创建我们的配置
            if let manager = managers?.first(where: { $0.localizedDescription == "SecureProxy TUN" }) {
                self?.tunnelManager = manager
                self?.isEnabled = manager.isEnabled
                self?.observeTunnelStatus()
            } else {
                self?.createTunnelConfiguration()
            }
        }
    }
    
    /// 创建新的 TUN 配置
    private func createTunnelConfiguration() {
        let manager = NETunnelProviderManager()
        manager.localizedDescription = "SecureProxy TUN"
        
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.secureproxy.tunnel" // 需要创建对应的 Network Extension
        proto.serverAddress = "SecureProxy"
        
        manager.protocolConfiguration = proto
        manager.isEnabled = false
        
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                print("❌ 保存 TUN 配置失败: \(error)")
                self?.statusMessage = "配置保存失败: \(error.localizedDescription)"
            } else {
                self?.tunnelManager = manager
                print("✅ TUN 配置已创建")
                self?.statusMessage = "TUN 配置已创建"
            }
        }
    }
    
    /// 启用 TUN 模式
    func enableTUN(socksPort: Int) {
        guard let manager = tunnelManager else {
            statusMessage = "TUN 未配置"
            createTunnelConfiguration()
            return
        }
        
        // 配置 TUN 参数
        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
            proto.providerConfiguration = [
                "socks_port": socksPort,
                "dns_server": "1.1.1.1",
                "tun_ip": "10.0.0.1",
                "tun_netmask": "255.255.255.0"
            ]
        }
        
        manager.isEnabled = true
        
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                print("❌ 启用 TUN 失败: \(error)")
                self?.statusMessage = "启用失败: \(error.localizedDescription)"
                self?.isEnabled = false
                return
            }
            
            // 加载并启动隧道
            manager.loadFromPreferences { error in
                if let error = error {
                    print("❌ 加载配置失败: \(error)")
                    return
                }
                
                do {
                    try manager.connection.startVPNTunnel()
                    self?.isEnabled = true
                    self?.statusMessage = "TUN 模式已启用"
                    print("✅ TUN 模式已启动")
                } catch {
                    print("❌ 启动 TUN 隧道失败: \(error)")
                    self?.statusMessage = "启动失败: \(error.localizedDescription)"
                    self?.isEnabled = false
                }
            }
        }
    }
    
    /// 禁用 TUN 模式
    func disableTUN() {
        guard let manager = tunnelManager else {
            return
        }
        
        manager.connection.stopVPNTunnel()
        manager.isEnabled = false
        
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                print("❌ 禁用 TUN 失败: \(error)")
                self?.statusMessage = "禁用失败: \(error.localizedDescription)"
            } else {
                self?.isEnabled = false
                self?.statusMessage = "TUN 模式已禁用"
                print("✅ TUN 模式已停止")
            }
        }
    }
    
    /// 监听 TUN 状态变化
    private func observeTunnelStatus() {
        guard let manager = tunnelManager else { return }
        
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatus()
        }
        
        updateStatus()
    }
    
    /// 更新状态信息
    private func updateStatus() {
        guard let manager = tunnelManager else { return }
        
        switch manager.connection.status {
        case .connected:
            statusMessage = "已连接"
            isEnabled = true
        case .connecting:
            statusMessage = "连接中..."
        case .disconnected:
            statusMessage = "未连接"
            isEnabled = false
        case .disconnecting:
            statusMessage = "断开中..."
        case .reasserting:
            statusMessage = "重新连接..."
        case .invalid:
            statusMessage = "配置无效"
            isEnabled = false
        @unknown default:
            statusMessage = "未知状态"
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
