// ViewModels/SystemProxyManager.swift
import Foundation
import SystemConfiguration

class SystemProxyManager {
    
    /// 设置系统全局代理
    static func setSystemProxy(socks5Port: Int, httpPort: Int) -> Bool {
        guard let prefRef = SCPreferencesCreate(nil, "SecureProxy" as CFString, nil) else {
            print("❌ 无法创建 SCPreferences")
            return false
        }
        
        guard SCPreferencesLock(prefRef, true) else {
            print("❌ 无法锁定 SCPreferences")
            return false
        }
        
        defer {
            SCPreferencesUnlock(prefRef)
        }
        
        // 获取网络服务列表
        guard let services = SCNetworkServiceCopyAll(prefRef) as? [SCNetworkService] else {
            print("❌ 无法获取网络服务")
            return false
        }
        
        var success = false
        
        for service in services {
            guard let serviceID = SCNetworkServiceGetServiceID(service) else {
                continue
            }
            
            let servicePath = "/NetworkServices/\(serviceID)/Proxies" as CFString
            
            guard let proxies = SCPreferencesPathGetValue(prefRef, servicePath) as? [String: Any] else {
                continue
            }
            
            var newProxies = proxies
            
            // 设置 SOCKS 代理
            newProxies["SOCKSEnable"] = 1
            newProxies["SOCKSProxy"] = "127.0.0.1"
            newProxies["SOCKSPort"] = socks5Port
            
            // 设置 HTTP 代理
            newProxies["HTTPEnable"] = 1
            newProxies["HTTPProxy"] = "127.0.0.1"
            newProxies["HTTPPort"] = httpPort
            
            // 设置 HTTPS 代理
            newProxies["HTTPSEnable"] = 1
            newProxies["HTTPSProxy"] = "127.0.0.1"
            newProxies["HTTPSPort"] = httpPort
            
            // 设置排除列表
            newProxies["ExceptionsList"] = [
                "127.0.0.1",
                "localhost",
                "*.local",
                "169.254.0.0/16",
                "192.168.0.0/16",
                "10.0.0.0/8"
            ]
            
            if SCPreferencesPathSetValue(prefRef, servicePath, newProxies as CFDictionary) {
                success = true
            }
        }
        
        if success {
            if SCPreferencesCommitChanges(prefRef) {
                SCPreferencesApplyChanges(prefRef)
                print("✅ 系统代理已启用")
                return true
            }
        }
        
        return false
    }
    
    /// 清除系统全局代理
    static func clearSystemProxy() -> Bool {
        guard let prefRef = SCPreferencesCreate(nil, "SecureProxy" as CFString, nil) else {
            print("❌ 无法创建 SCPreferences")
            return false
        }
        
        guard SCPreferencesLock(prefRef, true) else {
            print("❌ 无法锁定 SCPreferences")
            return false
        }
        
        defer {
            SCPreferencesUnlock(prefRef)
        }
        
        guard let services = SCNetworkServiceCopyAll(prefRef) as? [SCNetworkService] else {
            print("❌ 无法获取网络服务")
            return false
        }
        
        var success = false
        
        for service in services {
            guard let serviceID = SCNetworkServiceGetServiceID(service) else {
                continue
            }
            
            let servicePath = "/NetworkServices/\(serviceID)/Proxies" as CFString
            
            guard let proxies = SCPreferencesPathGetValue(prefRef, servicePath) as? [String: Any] else {
                continue
            }
            
            var newProxies = proxies
            
            // 禁用所有代理
            newProxies["SOCKSEnable"] = 0
            newProxies["HTTPEnable"] = 0
            newProxies["HTTPSEnable"] = 0
            
            if SCPreferencesPathSetValue(prefRef, servicePath, newProxies as CFDictionary) {
                success = true
            }
        }
        
        if success {
            if SCPreferencesCommitChanges(prefRef) {
                SCPreferencesApplyChanges(prefRef)
                print("✅ 系统代理已清除")
                return true
            }
        }
        
        return false
    }
    
    /// 检查系统代理状态
    static func getSystemProxyStatus() -> (enabled: Bool, socks5: String?, http: String?) {
        guard let prefRef = SCPreferencesCreate(nil, "SecureProxy" as CFString, nil) else {
            return (false, nil, nil)
        }
        
        guard let services = SCNetworkServiceCopyAll(prefRef) as? [SCNetworkService],
              let service = services.first else {
            return (false, nil, nil)
        }
        
        guard let serviceID = SCNetworkServiceGetServiceID(service) else {
            return (false, nil, nil)
        }
        
        let servicePath = "/NetworkServices/\(serviceID)/Proxies" as CFString
        
        guard let proxies = SCPreferencesPathGetValue(prefRef, servicePath) as? [String: Any] else {
            return (false, nil, nil)
        }
        
        let socksEnabled = (proxies["SOCKSEnable"] as? Int) == 1
        let httpEnabled = (proxies["HTTPEnable"] as? Int) == 1
        
        var socksInfo: String?
        var httpInfo: String?
        
        if socksEnabled,
           let proxy = proxies["SOCKSProxy"] as? String,
           let port = proxies["SOCKSPort"] as? Int {
            socksInfo = "\(proxy):\(port)"
        }
        
        if httpEnabled,
           let proxy = proxies["HTTPProxy"] as? String,
           let port = proxies["HTTPPort"] as? Int {
            httpInfo = "\(proxy):\(port)"
        }
        
        return (socksEnabled || httpEnabled, socksInfo, httpInfo)
    }
}
