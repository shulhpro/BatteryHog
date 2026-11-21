import Foundation
import Darwin
import SQLite3
#if canImport(AppKit)
import AppKit
#endif

public final class MemoryGuardBridge {
    public static let shared = MemoryGuardBridge()
    
    private var lastSwapIns: UInt64 = 0
    private var lastSwapOuts: UInt64 = 0
    private var isFirstCall: Bool = true
    
    private let protectedKeywords: Set<String> = [
        "gemini", "antigravity", "agy", "windowserver", "kernel_task",
        "launchd", "loginwindow", "systemstats", "opendirectoryd",
        "distnoted", "macmemoryguard", "battery hog"
    ]
    
    private init() {}
    
    public func fullAnalysis() -> [String: Any] {
        let snap = currentSnapshot()
        let procs = topProcesses(limit: 15)
        let episodes = recentEpisodes(hours: 72.0)
        let daemon = isAgentRunning()
        
        return [
            "snapshot": snap,
            "processes": procs,
            "episodes": episodes,
            "daemonRunning": daemon,
            "timestamp": Date().timeIntervalSince1970
        ]
    }
    
    public func currentSnapshot() -> [String: Any] {
        let pageSize = UInt64(vm_kernel_page_size)
        var totalMem: UInt64 = 8 * 1024 * 1024 * 1024
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalMem, &len, nil, 0)
        
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStat = vm_statistics64_data_t()
        let ret = withUnsafeMutablePointer(to: &vmStat) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        
        let activeBytes = ret == KERN_SUCCESS ? UInt64(vmStat.active_count) * pageSize : 0
        let inactiveBytes = ret == KERN_SUCCESS ? UInt64(vmStat.inactive_count) * pageSize : 0
        let wiredBytes = ret == KERN_SUCCESS ? UInt64(vmStat.wire_count) * pageSize : 0
        let freeBytes = ret == KERN_SUCCESS ? UInt64(vmStat.free_count) * pageSize : 0
        let compressedBytes = ret == KERN_SUCCESS ? UInt64(vmStat.compressor_page_count) * pageSize : 0
        let totalSwapIns = ret == KERN_SUCCESS ? UInt64(vmStat.swapins) : 0
        let totalSwapOuts = ret == KERN_SUCCESS ? UInt64(vmStat.swapouts) : 0
        
        let swapInsDelta: UInt64
        let swapOutsDelta: UInt64
        if isFirstCall {
            swapInsDelta = 0
            swapOutsDelta = 0
            isFirstCall = false
        } else {
            swapInsDelta = (totalSwapIns >= lastSwapIns) ? (totalSwapIns - lastSwapIns) : 0
            swapOutsDelta = (totalSwapOuts >= lastSwapOuts) ? (totalSwapOuts - lastSwapOuts) : 0
        }
        lastSwapIns = totalSwapIns
        lastSwapOuts = totalSwapOuts
        
        var xsw = xsw_usage()
        var xswLen = MemoryLayout<xsw_usage>.size
        var swapTotal: UInt64 = 0
        var swapUsed: UInt64 = 0
        if sysctlbyname("vm.swapusage", &xsw, &xswLen, nil, 0) == 0 {
            swapTotal = UInt64(xsw.xsu_total)
            swapUsed = UInt64(xsw.xsu_used)
        }
        
        var pressureLevel: Int32 = 1
        var plLen = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &plLen, nil, 0)
        
        let usedBytes = activeBytes + wiredBytes + compressedBytes
        let statusStr: String
        let statusIcon: String
        if pressureLevel >= 4 {
            statusStr = "CRITICAL"
            statusIcon = "🔴"
        } else if pressureLevel == 2 {
            statusStr = "WARNING"
            statusIcon = "🟡"
        } else {
            // Heuristic check for thrashing
            if totalMem > 0 && Double(usedBytes) / Double(totalMem) > 0.95 && swapUsed > (1500 * 1024 * 1024) && freeBytes < (100 * 1024 * 1024) {
                statusStr = "WARNING"
                statusIcon = "🟡"
            } else {
                statusStr = "NORMAL"
                statusIcon = "🟢"
            }
        }
        
        let mb = 1024.0 * 1024.0
        return [
            "total_mb": Int((Double(totalMem) / mb).rounded()),
            "used_mb": Int((Double(usedBytes) / mb).rounded()),
            "active_mb": Int((Double(activeBytes) / mb).rounded()),
            "inactive_mb": Int((Double(inactiveBytes) / mb).rounded()),
            "wired_mb": Int((Double(wiredBytes) / mb).rounded()),
            "compressed_mb": Int((Double(compressedBytes) / mb).rounded()),
            "free_mb": Int((Double(freeBytes) / mb).rounded()),
            "used_percent": totalMem > 0 ? (Double(usedBytes) / Double(totalMem) * 100.0).rounded() : 0,
            "swap_total_mb": Int((Double(swapTotal) / mb).rounded()),
            "swap_used_mb": Int((Double(swapUsed) / mb).rounded()),
            "swap_ins_delta": swapInsDelta,
            "swap_outs_delta": swapOutsDelta,
            "pressure_level": pressureLevel,
            "pressure_status": statusStr,
            "pressure_icon": statusIcon
        ]
    }
    
    public func topProcesses(limit: Int = 15) -> [[String: Any]] {
        let expectedBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard expectedBytes > 0 else { return [] }
        
        let count = Int(expectedBytes) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let actualBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, expectedBytes)
        guard actualBytes > 0 else { return [] }
        
        let validPids = Int(actualBytes) / MemoryLayout<pid_t>.size
        var list: [[String: Any]] = []
        list.reserveCapacity(validPids)
        
        for i in 0..<validPids {
            let pid = pids[i]
            guard pid > 0 else { continue }
            
            var tai = proc_taskallinfo()
            let sz = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &tai, Int32(MemoryLayout<proc_taskallinfo>.size))
            guard sz == MemoryLayout<proc_taskallinfo>.size else { continue }
            
            let ppid = pid_t(tai.pbsd.pbi_ppid)
            let resident = tai.ptinfo.pti_resident_size
            
            var footprint: UInt64 = resident
            var rusage = rusage_info_v4()
            let rusageRet = withUnsafeMutablePointer(to: &rusage) { ptr in
                ptr.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) { rusagePtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePtr)
                }
            }
            if rusageRet == 0 && rusage.ri_phys_footprint > 0 {
                footprint = rusage.ri_phys_footprint
            }
            
            var nameBuf = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuf, 256)
            var name = String(cString: nameBuf)
            if name.isEmpty {
                name = withUnsafePointer(to: &tai.pbsd.pbi_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
                }
            }
            
            var bundleId: String? = nil
            var appName: String? = nil
            #if canImport(AppKit)
            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                bundleId = runningApp.bundleIdentifier
                appName = runningApp.localizedName
            }
            #endif
            
            let displayName = appName ?? name
            let lower = (displayName + " " + name + " " + (bundleId ?? "")).lowercased()
            var isProt = false
            for kw in protectedKeywords {
                if lower.contains(kw) {
                    isProt = true
                    break
                }
            }
            
            let mb = 1024.0 * 1024.0
            list.append([
                "pid": pid,
                "ppid": ppid,
                "name": name,
                "displayName": displayName,
                "bundleId": bundleId ?? "",
                "footprintMB": Int((Double(footprint) / mb).rounded()),
                "rssMB": Int((Double(resident) / mb).rounded()),
                "isProtected": isProt
            ])
        }
        
        list.sort { ($0["footprintMB"] as? Int ?? 0) > ($1["footprintMB"] as? Int ?? 0) }
        return Array(list.prefix(limit))
    }
    
    public func recentEpisodes(hours: Double = 72.0) -> [[String: Any]] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbPath = home.appendingPathComponent(".macmemoryguard/metrics.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        
        let cutoff = Date().addingTimeInterval(-hours * 3600).timeIntervalSince1970
        let sql = "SELECT id, status, started_at, ended_at, duration_sec, peak_swap, notification_count FROM episodes WHERE started_at >= ? ORDER BY started_at DESC LIMIT 20;"
        var stmt: OpaquePointer?
        var results: [[String: Any]] = []
        
        let df = DateFormatter()
        df.dateFormat = "dd.MM HH:mm"
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, cutoff)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let statusStr = String(cString: sqlite3_column_text(stmt, 1))
                let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                var endedStr = "В процессе"
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                    endedStr = df.string(from: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)))
                }
                let durationSec = sqlite3_column_double(stmt, 4)
                let peakSwapBytes = UInt64(sqlite3_column_int64(stmt, 5))
                let notifCount = Int(sqlite3_column_int(stmt, 6))
                
                results.append([
                    "id": id,
                    "status": statusStr,
                    "startedAt": df.string(from: startedAt),
                    "endedAt": endedStr,
                    "durationMin": String(format: "%.1f", durationSec / 60.0),
                    "peakSwapMB": Int(peakSwapBytes / (1024 * 1024)),
                    "notificationCount": notifCount
                ])
            }
        }
        sqlite3_finalize(stmt)
        return results
    }
    
    public func isAgentRunning() -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        return output.contains("ru.suprotec.macmemoryguard")
    }
    
    public func buildReportMarkdown(hours: Double = 72.0) -> String {
        let snap = currentSnapshot()
        let episodes = recentEpisodes(hours: hours)
        let procs = topProcesses(limit: 20)
        
        var md = "# Отчёт MacMemoryGuard (Battery Hog Integration)\n\n"
        md += "**Дата формирования:** \(Date())\n"
        md += "**Устройство:** Apple Silicon M3, 8 ГБ Unified Memory\n"
        md += "**Текущее давление:** \(snap["pressure_icon"] ?? "") \(snap["pressure_status"] ?? "")\n"
        md += "**RAM:** \(snap["used_mb"] ?? 0) МБ (\(snap["used_percent"] ?? 0)%), Сжато: \(snap["compressed_mb"] ?? 0) МБ\n"
        md += "**Swap:** \(snap["swap_used_mb"] ?? 0) МБ из \(snap["swap_total_mb"] ?? 0) МБ\n\n"
        
        md += "## Зарегистрированные эпизоды давления памяти\n\n"
        if episodes.isEmpty {
            md += "Эпизодов дефицита памяти не зарегистрировано.\n\n"
        } else {
            md += "| Статус | Начало | Окончание | Длительность | Пик Swap | Алертов |\n"
            md += "| :--- | :--- | :--- | :--- | :--- | :--- |\n"
            for ep in episodes {
                md += "| \(ep["status"] ?? "") | \(ep["startedAt"] ?? "") | \(ep["endedAt"] ?? "") | \(ep["durationMin"] ?? "") мин | \(ep["peakSwapMB"] ?? 0) МБ | \(ep["notificationCount"] ?? 0) |\n"
            }
            md += "\n"
        }
        
        md += "## Топ процессов по физическому Footprint\n\n"
        md += "| Приложение | Footprint | RSS | Защита |\n"
        md += "| :--- | :--- | :--- | :--- |\n"
        for p in procs {
            let prot = (p["isProtected"] as? Bool ?? false) ? "🛡️ Защищён" : "Обычный"
            md += "| `\(p["displayName"] ?? "")` | \(p["footprintMB"] ?? 0) МБ | \(p["rssMB"] ?? 0) МБ | \(prot) |\n"
        }
        
        return md
    }
}
