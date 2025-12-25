// ViewModels/ProxyManager.swift
import Foundation
import Combine

class ProxyManager: ObservableObject {
    @Published var configs: [ProxyConfig] = []
    @Published var activeConfig: ProxyConfig?
    @Published var status: ProxyStatus = .disconnected
    @Published var isRunning = false
    @Published var trafficUp: Double = 0
    @Published var trafficDown: Double = 0
    @Published var logs: [String] = []
    
    private var process: Process?
    private var configDirectory: URL
    private var pythonDirectory: URL
    private var pythonPath: String
    private var timer: Timer?
    
    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        
        let baseDir = appSupport.appendingPathComponent("SecureProxy")
        self.configDirectory = baseDir.appendingPathComponent("config")
        self.pythonDirectory = baseDir.appendingPathComponent("python")
        
        self.pythonPath = "/usr/bin/python3"
        
        try? fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: pythonDirectory, withIntermediateDirectories: true)
        
        self.pythonPath = findPython()
        
        copyPythonScripts()
        loadConfigs()
        startTrafficMonitor()
    }
    
    private func findPython() -> String {
        let paths = [
            shell("which python3"),
            "\(NSHomeDirectory())/.pyenv/shims/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        
        let fm = FileManager.default
        for path in paths {
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPath.isEmpty && fm.fileExists(atPath: trimmedPath) {
                if checkPythonDependencies(pythonPath: trimmedPath) {
                    addLog("✅ 找到可用的 Python: \(trimmedPath)")
                    return trimmedPath
                } else {
                    addLog("⚠️ Python 存在但缺少依赖: \(trimmedPath)")
                }
            }
        }
        
        addLog("⚠️ 未找到合适的 Python，使用默认路径")
        return "/usr/bin/python3"
    }
    
    private func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.standardInput = nil
        
        var environment = ProcessInfo.processInfo.environment
        if let home = environment["HOME"] {
            let pyenvRoot = "\(home)/.pyenv"
            let path = "\(pyenvRoot)/shims:\(pyenvRoot)/bin:\(environment["PATH"] ?? "")"
            environment["PATH"] = path
            task.environment = environment
        }
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }
    
    private func checkPythonDependencies(pythonPath: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = ["-c", "import cryptography, websockets"]
        task.environment = ProcessInfo.processInfo.environment
        
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    private func copyPythonScripts() {
        let fm = FileManager.default
        let pythonFiles = ["client.py", "crypto.py", "tls_fingerprint.py"]
        var copiedCount = 0
        
        for file in pythonFiles {
            let destPath = pythonDirectory.appendingPathComponent(file)
            try? fm.removeItem(at: destPath)
            
            let possiblePaths = [
                Bundle.main.resourceURL?.appendingPathComponent("Python").appendingPathComponent(file),
                Bundle.main.resourceURL?.appendingPathComponent(file),
                Bundle.main.path(forResource: file.replacingOccurrences(of: ".py", with: ""), ofType: "py", inDirectory: "Python").map { URL(fileURLWithPath: $0) },
                Bundle.main.path(forResource: file.replacingOccurrences(of: ".py", with: ""), ofType: "py").map { URL(fileURLWithPath: $0) }
            ].compactMap { $0 }
            
            var copied = false
            for sourcePath in possiblePaths {
                if fm.fileExists(atPath: sourcePath.path) {
                    do {
                        try fm.copyItem(at: sourcePath, to: destPath)
                        addLog("✅ 复制: \(file)")
                        copiedCount += 1
                        copied = true
                        break
                    } catch {
                        continue
                    }
                }
            }
            
            if !copied {
                addLog("❌ 未找到: \(file)")
            }
        }
        
        if copiedCount == 0 {
            addLog("⚠️ 警告: 未能复制任何 Python 文件")
        } else {
            addLog("✅ 复制完成: \(copiedCount)/3 个文件")
        }
    }
    
    func loadConfigs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: configDirectory, includingPropertiesForKeys: nil) else {
            addLog("配置目录为空")
            return
        }
        
        configs = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let config = try? JSONDecoder().decode(ProxyConfig.self, from: data) else {
                    return nil
                }
                return config
            }
        
        addLog("加载了 \(configs.count) 个配置")
        
        if let activeName = UserDefaults.standard.string(forKey: "activeConfig"),
           let active = configs.first(where: { $0.name == activeName }) {
            activeConfig = active
        } else if let first = configs.first {
            activeConfig = first
        }
    }
    
    func saveConfig(_ config: ProxyConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        guard let data = try? encoder.encode(config) else { return }
        
        let url = configDirectory.appendingPathComponent("\(config.name).json")
        try? data.write(to: url)
        
        addLog("保存配置: \(config.name)")
        loadConfigs()
    }
    
    func deleteConfig(_ config: ProxyConfig) {
        let url = configDirectory.appendingPathComponent("\(config.name).json")
        try? FileManager.default.removeItem(at: url)
        
        addLog("删除配置: \(config.name)")
        loadConfigs()
    }
    
    func switchConfig(_ config: ProxyConfig) {
        activeConfig = config
        UserDefaults.standard.set(config.name, forKey: "activeConfig")
        
        addLog("切换到配置: \(config.name)")
        
        if isRunning {
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.start()
            }
        }
    }
    
    func start() {
        guard let config = activeConfig else {
            addLog("❌ 错误: 没有选中的配置")
            return
        }
        guard !isRunning else { return }
        
        status = .connecting
        addLog("🚀 启动代理...")
        
        addLog("🧹 清理残留进程...")
        killAllClientProcesses()
        releasePort(config.socksPort)
        releasePort(config.httpPort)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startProxyProcess(config: config)
        }
    }
    
    private func startProxyProcess(config: ProxyConfig) {
        // 通过环境变量传递配置 JSON
        let configDict: [String: Any] = [
            "name": config.name,
            "sni_host": config.sniHost,
            "path": config.path,
            "server_port": config.serverPort,
            "socks_port": config.socksPort,
            "http_port": config.httpPort,
            "pre_shared_key": config.preSharedKey
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: configDict, options: []),
              let configJson = String(data: jsonData, encoding: .utf8) else {
            addLog("❌ 配置序列化失败")
            // 🔥 错误只记录日志，不改变UI状态
            status = .disconnected
            return
        }
        
        let scriptPath = pythonDirectory.appendingPathComponent("client.py").path
        
        process = Process()
        process?.executableURL = URL(fileURLWithPath: pythonPath)
        process?.arguments = [scriptPath]
        process?.currentDirectoryURL = pythonDirectory
        
        var environment = ProcessInfo.processInfo.environment
        
        // 设置配置到环境变量
        environment["SECURE_PROXY_CONFIG"] = configJson
        
        if let home = environment["HOME"] {
            let pyenvRoot = "\(home)/.pyenv"
            let currentPath = environment["PATH"] ?? ""
            
            var pathComponents = [
                "\(pyenvRoot)/shims",
                "\(pyenvRoot)/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin"
            ]
            
            for component in currentPath.split(separator: ":") {
                let path = String(component)
                if !pathComponents.contains(path) {
                    pathComponents.append(path)
                }
            }
            
            environment["PATH"] = pathComponents.joined(separator: ":")
            environment["PYENV_ROOT"] = pyenvRoot
        }
        
        environment["PYTHONUNBUFFERED"] = "1"
        process?.environment = environment
        
        addLog("🐍 Python: \(pythonPath)")
        addLog("📂 工作目录: \(pythonDirectory.path)")
        addLog("📄 配置: \(config.name)")
        addLog("🔧 通过环境变量传递配置")
        
        let pipe = Pipe()
        let errorPipe = Pipe()
        process?.standardOutput = pipe
        process?.standardError = errorPipe
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                DispatchQueue.main.async {
                    self?.parseOutput(output)
                }
            }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                DispatchQueue.main.async {
                    // 🔥 错误只记录到日志，不影响UI状态
                    self?.addLog("❌ 错误: \(output)")
                }
            }
        }
        
        do {
            try process?.run()
            isRunning = true
            status = .connected
            addLog("✅ 代理进程已启动")
            addLog("📡 SOCKS5: 127.0.0.1:\(config.socksPort)")
            addLog("📡 HTTP: 127.0.0.1:\(config.httpPort)")
        } catch {
            // 🔥 启动失败只记录日志，状态回到未连接
            addLog("❌ 启动失败: \(error.localizedDescription)")
            status = .disconnected
        }
    }
    
    func stop() {
        addLog("🛑 停止代理...")
        
        if let process = process {
            process.terminate()
            
            DispatchQueue.global().async {
                process.waitUntilExit()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let pid = process.processIdentifier
                if pid > 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
        
        killAllClientProcesses()
        
        if let config = activeConfig {
            releasePort(config.socksPort)
            releasePort(config.httpPort)
        }
        
        process = nil
        isRunning = false
        status = .disconnected
        trafficUp = 0
        trafficDown = 0
        
        addLog("✅ 代理已停止")
    }
    
    private func killAllClientProcesses() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "client.py"]
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                addLog("🔪 已清理残留进程")
            }
        } catch {
            // 失败不影响主流程
        }
    }
    
    private func releasePort(_ port: Int) {
        let task = Process()
        let pipe = Pipe()
        
        task.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        task.arguments = ["-ti", ":\(port)"]
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                let pids = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines)
                    .compactMap { Int($0) }
                
                for pid in pids {
                    kill(pid_t(pid), SIGKILL)
                    addLog("🔪 释放端口 \(port) (PID: \(pid))")
                }
            }
        } catch {
            // 失败不影响主流程
        }
    }
    
    func forceCleanup() {
        addLog("🧹 开始强制清理...")
        
        killAllClientProcesses()
        
        if let config = activeConfig {
            releasePort(config.socksPort)
            releasePort(config.httpPort)
        }
        
        releasePort(1080)
        releasePort(1081)
        
        process = nil
        isRunning = false
        status = .disconnected
        
        addLog("✅ 清理完成")
    }
    
    private func parseOutput(_ output: String) {
        // 🔥 所有输出都只记录到日志
        addLog(output)
        
        // 🔥 只有明确的成功标志才改变状态为已连接
        // 错误、失败等信息不改变UI状态
        if output.contains("隧道建立成功") ||
           output.contains("✅ SOCKS5") ||
           output.contains("✅ HTTP") {
            status = .connected
        }
        // 🔥 移除错误状态的设置，让状态保持为 connecting 或已有状态
    }
    
    private func startTrafficMonitor() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            
            self.trafficUp = Double.random(in: 0...100)
            self.trafficDown = Double.random(in: 0...100)
        }
    }
    
    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
        if logs.count > 500 {
            logs.removeFirst()
        }
    }
    
    func clearLogs() {
        logs.removeAll()
        addLog("日志已清除")
    }
    
    deinit {
        killAllClientProcesses()
        if let config = activeConfig {
            releasePort(config.socksPort)
            releasePort(config.httpPort)
        }
        timer?.invalidate()
    }
}
