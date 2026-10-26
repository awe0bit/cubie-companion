import Foundation

struct BoardStatus: Codable {
    let sampledAt: String
    let hostname: String
    let cpuPercent: Double?
    let memoryUsedBytes: Double?
    let memoryTotalBytes: Double?
    let diskUsedBytes: Double?
    let diskTotalBytes: Double?
    let uptimeSeconds: Double?
    let rxBytesPerSecond: Double?
    let txBytesPerSecond: Double?
    let temperatures: [Temperature]
    let powerWatts: Double?
    let fanRPM: Double?
}

struct Temperature: Codable, Identifiable {
    var id: String { name }
    let name: String
    let celsius: Double
}

struct BoardService: Codable, Identifiable {
    let id: String
    let unit: String
    let name: String
    let state: String
    let controllable: Bool

    var stateText: String {
        switch state {
        case "active": return "运行中"
        case "inactive": return "已停止"
        case "failed": return "故障"
        case "activating": return "启动中"
        case "deactivating": return "停止中"
        default: return "未知状态"
        }
    }
}

struct ServiceList: Codable {
    let sampledAt: String
    let services: [BoardService]
}

struct NetworkStatus: Codable {
    let sampledAt: String
    let profile: String?
    let interface: String
    let campusStatus: String
    let campusCheckedAt: String?
    let requiresAttention: Bool?
    let attemptsLastHour: Int?
    let tunnelReady: Bool

    var campusText: String {
        switch campusStatus {
        case "online": return "认证在线"
        case "off_network": return "不在校园网"
        case "confirming_outage": return "确认断线中"
        case "backoff": return "等待重试"
        case "captcha_required": return "需要人工验证码"
        case "authenticated_no_internet": return "认证成功，出网异常"
        case "service_unavailable": return "套餐或服务不可用"
        case "authentication_disabled": return "自动认证未开启"
        case "auth_rejected": return "认证被拒绝"
        case "manual_required": return "需要人工处理"
        case "frequency_limited": return "认证频率受限"
        case "configuration_required": return "认证配置未完成"
        case "credentials_required": return "设备缺少校园网凭据"
        case "credentials_permissions": return "校园网凭据权限异常"
        case "network_binding_failed": return "认证网卡绑定失败"
        case "paused": return "已暂停认证"
        case "stale": return "认证状态已过期"
        default: return "尚未获取"
        }
    }
}

struct Capabilities: Codable {
    let apiVersion: Int
    let role: String
    let serviceControl: Bool
    let deviceReboot: Bool
    let rawLogs: Bool
    let dockerControl: Bool
    let ledControl: Bool
    let powerMeasurement: Bool
    let fanRPM: Bool
    let deviceInventory: Bool?
    let managementInventory: Bool?
}

struct ManagementStatus: Codable {
    let sampledAt: String
    let leds: [BoardLED]
    let containers: [BoardContainer]
    let dockerAvailable: Bool
}

struct BoardLED: Codable, Identifiable {
    let id: String
    let name: String
    let mode: String
    let controllable: Bool
    var modeText: String { mode == "system" ? "跟随系统" : mode == "on" ? "常亮" : "已关闭" }
}

struct BoardContainer: Codable, Identifiable {
    let id: String
    let name: String
    let image: String
    let state: String
    let controllable: Bool
    var stateText: String {
        switch state {
        case "running": return "运行中"
        case "exited": return "已停止"
        case "created": return "待启动"
        case "paused": return "已暂停"
        case "restarting": return "重启中"
        case "dead": return "故障"
        default: return "未知状态"
        }
    }
}

struct DeviceInventory: Codable {
    let sampledAt: String
    let board: BoardHardware
    let devices: [HardwareDevice]
}

struct BoardHardware: Codable {
    let model: String?
    let architecture: String?
    let kernel: String?
    let cpuCores: Int?
    let memoryBytes: Double?
}

struct HardwareDevice: Codable, Identifiable {
    let id: String
    let category: String
    let name: String
    let node: String
    let bus: String
    let driver: String?
    let state: String
    let vendorID: String?
    let productID: String?
    let capacityBytes: Double?
    let speedMbps: Double?
    let removable: Bool?

    var symbol: String {
        switch category {
        case "storage": return "internaldrive"
        case "network": return bus == "wifi" ? "wifi" : "network"
        case "bluetooth": return "antenna.radiowaves.left.and.right"
        default: return "cable.connector"
        }
    }

    var stateText: String {
        switch state {
        case "detected": return "已识别"
        case "up": return "链路已连接"
        case "down", "lowerlayerdown": return "链路未连接"
        case "blocked": return "未授权"
        case "dormant": return "等待链路"
        case "notpresent": return "设备不可用"
        default: return "状态未知"
        }
    }

    var busText: String {
        switch bus {
        case "usb": return "USB"
        case "sd": return "SD"
        case "mmc": return "MMC"
        case "nvme": return "NVMe"
        case "wifi": return "无线网卡"
        case "ethernet": return "以太网卡"
        case "bluetooth": return "蓝牙"
        default: return "系统设备"
        }
    }
}

struct ServiceEvents: Codable {
    let serviceId: String
    let scope: String
    let events: [ServiceEvent]
}

struct ServiceEvent: Codable, Identifiable {
    var id: String { timestamp + message }
    let timestamp: String
    let message: String
}

struct Accepted: Codable { let accepted: Bool }
struct APIProblem: Codable { let error: String }

struct ConnectionCredentials: Codable {
    let baseURL: String
    let apiToken: String
    let accessClientID: String
    let accessClientSecret: String
}

enum Display {
    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(max(0, min(value, Double(Int64.max / 2)))), countStyle: .binary)
    }

    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func uptime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let minutes = Int(min(seconds / 60, 100_000_000))
        if minutes >= 1440 { return "\(minutes / 1440) 天 \(minutes % 1440 / 60) 小时" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分" }
        return "\(minutes) 分钟"
    }
}
