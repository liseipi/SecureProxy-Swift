// PacketTunnelProvider.swift (简化测试版 - 用于验证基本功能)
import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private var isRunning = false
    private var packetCount = 0
    
    // MARK: - 生命周期管理
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("🚀 [TUN] 开始启动 TUN 隧道")
        
        // 读取配置
        var socksPort = 1080
        if let config = protocolConfiguration as? NETunnelProviderProtocol,
           let providerConfig = config.providerConfiguration,
           let port = providerConfig["socks_port"] as? Int {
            socksPort = port
            NSLog("✅ [TUN] SOCKS5 端口: \(socksPort)")
        }
        
        // 创建隧道网络设置
        let settings = createSimpleTunnelSettings()
        
        // 应用设置
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                NSLog("❌ [TUN] 设置网络失败: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            
            NSLog("✅ [TUN] 网络设置已应用")
            NSLog("📍 [TUN] TUN IP: 10.0.0.2")
            NSLog("📍 [TUN] 网关: 10.0.0.1")
            NSLog("📍 [TUN] DNS: 1.1.1.1, 8.8.8.8")
            
            // 开始处理数据包
            self?.isRunning = true
            self?.startSimplePacketForwarding()
            
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("🛑 [TUN] 停止 TUN 隧道")
        NSLog("📊 [TUN] 总共处理了 \(packetCount) 个数据包")
        
        isRunning = false
        packetCount = 0
        
        completionHandler()
    }
    
    // MARK: - 网络配置
    
    private func createSimpleTunnelSettings() -> NEPacketTunnelNetworkSettings {
        // 创建基础设置
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.0.0.1")
        
        // IPv4 设置
        let ipv4Settings = NEIPv4Settings(
            addresses: ["10.0.0.2"],
            subnetMasks: ["255.255.255.0"]
        )
        
        // 设置路由 - 代理所有流量
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        
        // 排除本地和私有网络
        ipv4Settings.excludedRoutes = [
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),     // Localhost
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),      // TUN 网段
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"), // 私有网络
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0")   // 私有网络
        ]
        
        settings.ipv4Settings = ipv4Settings
        
        // DNS 设置
        let dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        
        // MTU
        settings.mtu = 1400
        
        return settings
    }
    
    // MARK: - 简化的数据包转发（仅记录）
    
    private func startSimplePacketForwarding() {
        NSLog("📡 [TUN] 开始监听数据包...")
        
        // 读取数据包
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRunning else { return }
            
            // 统计
            self.packetCount += packets.count
            
            // 每处理 100 个数据包打印一次
            if self.packetCount % 100 == 0 {
                NSLog("📊 [TUN] 已处理 \(self.packetCount) 个数据包")
            }
            
            // 处理每个数据包
            for (index, packet) in packets.enumerated() {
                let protocolNumber = protocols[index]
                self.logPacketInfo(packet, protocolNumber: protocolNumber.intValue)
            }
            
            // 继续读取
            self.startSimplePacketForwarding()
        }
    }
    
    // MARK: - 数据包分析（仅日志）
    
    private func logPacketInfo(_ packet: Data, protocolNumber: Int) {
        guard packet.count >= 20 else { return }
        
        // 解析 IP 版本
        let ipVersion = (packet[0] & 0xF0) >> 4
        guard ipVersion == 4 else {
            return  // 忽略非 IPv4
        }
        
        // 提取信息
        let ipProtocol = packet[9]
        let sourceIP = extractIP(from: packet, offset: 12)
        let destIP = extractIP(from: packet, offset: 16)
        
        // 协议类型
        let protocolName: String
        var portInfo = ""
        
        switch ipProtocol {
        case 6:  // TCP
            protocolName = "TCP"
            if let ports = extractTCPPorts(from: packet) {
                portInfo = " [\(ports.source) → \(ports.dest)]"
            }
            
        case 17:  // UDP
            protocolName = "UDP"
            if let ports = extractUDPPorts(from: packet) {
                portInfo = " [\(ports.source) → \(ports.dest)]"
            }
            
        case 1:  // ICMP
            protocolName = "ICMP"
            
        default:
            protocolName = "Proto-\(ipProtocol)"
        }
        
        // 仅对关键连接打印日志（避免日志过多）
        if shouldLogPacket(destIP: destIP, protocol: ipProtocol) {
            NSLog("📦 [TUN] \(protocolName)\(portInfo): \(sourceIP) → \(destIP) (\(packet.count) bytes)")
        }
    }
    
    // MARK: - 工具方法
    
    private func extractIP(from packet: Data, offset: Int) -> String {
        guard packet.count >= offset + 4 else { return "0.0.0.0" }
        return "\(packet[offset]).\(packet[offset+1]).\(packet[offset+2]).\(packet[offset+3])"
    }
    
    private func extractTCPPorts(from packet: Data) -> (source: UInt16, dest: UInt16)? {
        let ipHeaderLength = Int((packet[0] & 0x0F) * 4)
        guard packet.count >= ipHeaderLength + 4 else { return nil }
        
        let sourcePort = UInt16(packet[ipHeaderLength]) << 8 | UInt16(packet[ipHeaderLength + 1])
        let destPort = UInt16(packet[ipHeaderLength + 2]) << 8 | UInt16(packet[ipHeaderLength + 3])
        
        return (sourcePort, destPort)
    }
    
    private func extractUDPPorts(from packet: Data) -> (source: UInt16, dest: UInt16)? {
        let ipHeaderLength = Int((packet[0] & 0x0F) * 4)
        guard packet.count >= ipHeaderLength + 4 else { return nil }
        
        let sourcePort = UInt16(packet[ipHeaderLength]) << 8 | UInt16(packet[ipHeaderLength + 1])
        let destPort = UInt16(packet[ipHeaderLength + 2]) << 8 | UInt16(packet[ipHeaderLength + 3])
        
        return (sourcePort, destPort)
    }
    
    private func shouldLogPacket(destIP: String, protocol: UInt8) -> Bool {
        // 仅记录 TCP/UDP 到公网的连接
        if `protocol` != 6 && `protocol` != 17 {
            return false
        }
        
        // 忽略本地和私有网络
        if destIP.hasPrefix("127.") ||
           destIP.hasPrefix("192.168.") ||
           destIP.hasPrefix("10.") ||
           destIP.hasPrefix("172.") {
            return false
        }
        
        return true
    }
    
    // MARK: - 消息处理
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let message = String(data: messageData, encoding: .utf8) {
            NSLog("💬 [TUN] 收到主应用消息: \(message)")
            
            // 返回统计信息
            let stats = "packets: \(packetCount), running: \(isRunning)"
            completionHandler?(stats.data(using: .utf8))
        } else {
            completionHandler?(nil)
        }
    }
}
