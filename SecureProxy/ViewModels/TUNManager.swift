// ViewModels/TUNManager.swift (改进版 - 支持系统扩展)
import Foundation
import NetworkExtension
import SystemExtensions

class TUNManager: NSObject, ObservableObject {
    @Published var isEnabled = false
    @Published var statusMessage = ""
    @Published var connectionStatus: NEVPNStatus = .disconnected
    
    private var tunnelManager: NETunnelProviderManager?
    private var extensionInstalled = false
    
    override init() {
        super.init()
        checkSystemExtension()
        loadTunnelConfiguration()
    }
    
    // MARK: - 系统扩展管理
    
    /// 检查系统扩展是否已安装
    private func checkSystemExtension() {
        // 在 macOS 11+ 上需要先安装系统扩展
        if #available(macOS 11.0, *) {
            // 检查扩展状态
            // 注意: 实际检查需要使用 SystemExtensions framework
            extensionInstalled = false
        } else {
            extensionInstalled = true
        }
    }
    
    /// 安装系统扩展
    func installSystemExtension(completion: @escaping (Bool, String) -> Void) {
        if #available(macOS 11.0, *) {
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: "com.secureproxy.tunnel",
                queue: .main
            )
            request.delegate = self
            
            OSSystemExtensionManager.shared.submitRequest(request)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.extensionInstalled == true {
                    completion(true, "系统扩展已安装")
                } else {
                    completion(false, "系统扩展安装失败，请检查系统设置")
                }
            }
        } else {
            extensionInstalled = true
            completion(true, "不需要安装系统扩展")
        }
    }
    
    // MARK: - TUN 配置管理
    
    /// 加载 TUN 配置
    private func loadTunnelConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ 加载 TUN 配置失败: \(error)")
                self.statusMessage = "加载配置失败: \(error.localizedDescription)"
                return
            }
            
            // 查找我们的配置
            if let manager = managers?.first(where: {
                $0.localizedDescription == "SecureProxy TUN"
            }) {
                self.tunnelManager = manager
                self.isEnabled = manager.isEnabled
                self.updateConnectionStatus(manager.connection.status)
                self.observeTunnelStatus()
                print("✅ 找到现有 TUN 配置")
            } else {
                print("📝 创建新的 TUN 配置")
                self.createTunnelConfiguration()
            }
        }
    }
    
    /// 创建新的 TUN 配置
    private func createTunnelConfiguration() {
        let manager = NETunnelProviderManager()
        manager.localizedDescription = "SecureProxy TUN"
        
        let proto = NETunnelProviderProtocol()
        
        // ⚠️ 重要: Bundle Identifier 必须与 Network Extension Target 一致
        proto.providerBundleIdentifier = "com.secureproxy.tunnel"
        proto.serverAddress = "SecureProxy Local"
        
        // 初始配置（稍后会更新）
        proto.providerConfiguration = [
            "socks_port": 1080,
            "dns_server": "1.1.1.1",
            "version": "1.0.0"
        ]
        
        manager.protocolConfiguration = proto
        manager.isEnabled = false
        manager.isOnDemandEnabled = false
        
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                print("❌ 保存 TUN 配置失败: \(error)")
                self?.statusMessage = "配置保存失败: \(error.localizedDescription)"
            } else {
                self?.tunnelManager = manager
                self?.observeTunnelStatus()
                print("✅ TUN 配置已创建并保存")
                self?.statusMessage = "TUN 配置已创建"
            }
        }
    }
    
    // MARK: - TUN 控制
    
    /// 启用 TUN 模式
    func enableTUN(socksPort: Int, dnsServer: String = "1.1.1.1") {
        guard let manager = tunnelManager else {
            statusMessage = "TUN 配置未就绪，正在创建..."
            createTunnelConfiguration()
            
            // 延迟重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.enableTUN(socksPort: socksPort, dnsServer: dnsServer)
            }
            return
        }
        
        // 如果需要系统扩展但未安装
        if !extensionInstalled {
            installSystemExtension { [weak self] success, message in
                if success {
                    self?.enableTUN(socksPort: socksPort, dnsServer: dnsServer)
                } else {
                    self?.statusMessage = message
                }
            }
            return
        }
        
        // 更新配置
        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
            proto.providerConfiguration = [
                "socks_port": socksPort,
                "dns_server": dnsServer,
                "tun_ip": "10.0.0.2",
                "tun_netmask": "255.255.255.0",
                "tun_gateway": "10.0.0.1",
                "version": "1.0.0"
            ]
        }
        
        manager.isEnabled = true
        
        // 保存配置
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                print("❌ 保存配置失败: \(error)")
                self?.statusMessage = "启用失败: \(error.localizedDescription)"
                self?.isEnabled = false
                return
            }
            
            // 重新加载配置
            manager.loadFromPreferences { [weak self] error in
                if let error = error {
                    print("❌ 加载配置失败: \(error)")
                    self?.statusMessage = "加载失败: \(error.localizedDescription)"
                    return
                }
                
                // 启动隧道
                do {
                    try manager.connection.startVPNTunnel()
                    print("✅ TUN 隧道启动命令已发送")
                    self?.statusMessage = "正在启动..."
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
            print("⚠️ TUN 管理器不存在")
            return
        }
        
        // 停止隧道
        manager.connection.stopVPNTunnel()
        
        // 禁用配置
        manager.isEnabled = false
        
        manager.saveToPreferences { [weak self] error in
            if let error = error {
                print("❌ 禁用 TUN 失败: \(error)")
                self?.statusMessage = "禁用失败: \(error.localizedDescription)"
            } else {
                self?.isEnabled = false
                self?.statusMessage = "TUN 已停止"
                print("✅ TUN 模式已禁用")
            }
        }
    }
    
    /// 重启 TUN
    func restartTUN(socksPort: Int) {
        disableTUN()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.enableTUN(socksPort: socksPort)
        }
    }
    
    // MARK: - 状态监听
    
    /// 监听 TUN 状态变化
    private func observeTunnelStatus() {
        guard let manager = tunnelManager else { return }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange),
            name: .NEVPNStatusDidChange,
            object: manager.connection
        )
        
        updateConnectionStatus(manager.connection.status)
    }
    
    @objc private func vpnStatusDidChange(_ notification: Notification) {
        guard let connection = notification.object as? NETunnelProviderSession else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.updateConnectionStatus(connection.status)
        }
    }
    
    /// 更新连接状态
    private func updateConnectionStatus(_ status: NEVPNStatus) {
        connectionStatus = status
        
        switch status {
        case .connected:
            statusMessage = "已连接"
            isEnabled = true
            print("✅ TUN 状态: 已连接")
            
        case .connecting:
            statusMessage = "连接中..."
            print("🔄 TUN 状态: 连接中")
            
        case .disconnected:
            statusMessage = "未连接"
            isEnabled = false
            print("⚪️ TUN 状态: 未连接")
            
        case .disconnecting:
            statusMessage = "断开中..."
            print("🔄 TUN 状态: 断开中")
            
        case .reasserting:
            statusMessage = "重新连接中..."
            print("🔄 TUN 状态: 重新连接")
            
        case .invalid:
            statusMessage = "配置无效"
            isEnabled = false
            print("❌ TUN 状态: 配置无效")
            
        @unknown default:
            statusMessage = "未知状态"
            print("⚠️ TUN 状态: 未知")
        }
    }
    
    // MARK: - 诊断工具
    
    /// 获取详细状态信息
    func getDetailedStatus() -> String {
        var info = "TUN 状态信息:\n"
        
        if let manager = tunnelManager {
            info += "配置名称: \(manager.localizedDescription ?? "未知")\n"
            info += "是否启用: \(manager.isEnabled ? "是" : "否")\n"
            info += "连接状态: \(statusDescription(connectionStatus))\n"
            
            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                info += "服务器: \(proto.serverAddress ?? "未设置")\n"
                info += "Bundle ID: \(proto.providerBundleIdentifier ?? "未设置")\n"
                
                if let config = proto.providerConfiguration {
                    info += "SOCKS 端口: \(config["socks_port"] ?? "未设置")\n"
                    info += "DNS: \(config["dns_server"] ?? "未设置")\n"
                }
            }
        } else {
            info += "TUN 管理器未初始化\n"
        }
        
        info += "系统扩展: \(extensionInstalled ? "已安装" : "未安装")\n"
        
        return info
    }
    
    private func statusDescription(_ status: NEVPNStatus) -> String {
        switch status {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .disconnected: return "未连接"
        case .disconnecting: return "断开中"
        case .reasserting: return "重新连接"
        case .invalid: return "无效"
        @unknown default: return "未知"
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - 系统扩展委托

@available(macOS 11.0, *)
extension TUNManager: OSSystemExtensionRequestDelegate {
    
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        print("🔄 替换系统扩展")
        return .replace
    }
    
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("⚠️ 需要用户批准系统扩展")
        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = "需要用户批准系统扩展，请在系统设置中允许"
        }
    }
    
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        print("✅ 系统扩展安装成功")
        extensionInstalled = true
        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = "系统扩展已激活"
        }
    }
    
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        print("❌ 系统扩展安装失败: \(error.localizedDescription)")
        extensionInstalled = false
        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = "系统扩展安装失败: \(error.localizedDescription)"
        }
    }
}
