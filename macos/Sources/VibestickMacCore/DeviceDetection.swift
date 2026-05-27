import Foundation

public struct DeviceIdentity: Codable, Equatable, Sendable {
    public let name: String
    public let vendorId: String
    public let productId: String

    public var normalizedVendorId: String {
        Self.normalizeHexId(vendorId)
    }

    public var normalizedProductId: String {
        Self.normalizeHexId(productId)
    }

    public init(name: String, vendorId: String, productId: String) {
        self.name = name
        self.vendorId = vendorId
        self.productId = productId
    }

    public func matches(instanceId: String?) -> Bool {
        guard let instanceId, !instanceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let normalized = instanceId.uppercased()
        return normalized.contains("VID_\(normalizedVendorId)&PID_\(normalizedProductId)")
    }

    public func matches(vendorId: Int?, productId: Int?) -> Bool {
        guard let vendorId, let productId else {
            return false
        }

        return Self.normalizeHexId(String(format: "%04X", vendorId)) == normalizedVendorId
            && Self.normalizeHexId(String(format: "%04X", productId)) == normalizedProductId
    }

    private static func normalizeHexId(_ value: String) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "&H", with: "", options: .caseInsensitive)
            .uppercased()
        return String(repeating: "0", count: max(0, 4 - trimmed.count)) + trimmed
    }
}

public struct VibestickDeviceOptions: Equatable, Sendable {
    public let device: DeviceIdentity
    public let bootloader: DeviceIdentity
    public let bootloaderVolumeLabel: String
    public let bootloaderBoardId: String
    public let launchDebounce: TimeInterval

    public init(
        device: DeviceIdentity = DeviceIdentity(name: "Vibestick RP2040", vendorId: "2E8A", productId: "4002"),
        bootloader: DeviceIdentity = DeviceIdentity(name: "Raspberry Pi RP2 UF2 Bootloader", vendorId: "2E8A", productId: "0003"),
        bootloaderVolumeLabel: String = "RPI-RP2",
        bootloaderBoardId: String = "RPI-RP2",
        launchDebounce: TimeInterval = 5
    ) {
        self.device = device
        self.bootloader = bootloader
        self.bootloaderVolumeLabel = bootloaderVolumeLabel
        self.bootloaderBoardId = bootloaderBoardId
        self.launchDebounce = launchDebounce
    }
}

public struct DeviceSnapshot: Codable, Equatable, Sendable {
    public let instanceId: String?
    public let friendlyName: String?
    public let vendorId: Int?
    public let productId: Int?
    public let volumePath: String?
    public let volumeLabel: String?
    public let boardInfoText: String?

    public init(
        instanceId: String? = nil,
        friendlyName: String? = nil,
        vendorId: Int? = nil,
        productId: Int? = nil,
        volumePath: String? = nil,
        volumeLabel: String? = nil,
        boardInfoText: String? = nil
    ) {
        self.instanceId = instanceId
        self.friendlyName = friendlyName
        self.vendorId = vendorId
        self.productId = productId
        self.volumePath = volumePath
        self.volumeLabel = volumeLabel
        self.boardInfoText = boardInfoText
    }
}

public enum DeviceDetectionKind: String, Codable, Sendable {
    case none
    case bootloader
    case vibestickDevice
}

public struct DeviceDetectionResult: Codable, Equatable, Sendable {
    public let kind: DeviceDetectionKind
    public let message: String
    public let matchedIdentity: DeviceIdentity?
    public let snapshot: DeviceSnapshot?

    public init(
        kind: DeviceDetectionKind,
        message: String,
        matchedIdentity: DeviceIdentity? = nil,
        snapshot: DeviceSnapshot? = nil
    ) {
        self.kind = kind
        self.message = message
        self.matchedIdentity = matchedIdentity
        self.snapshot = snapshot
    }

    public static let none = DeviceDetectionResult(kind: .none, message: "No Vibestick device detected.")
}

public enum DeviceDetector {
    public static func detect(
        _ snapshots: [DeviceSnapshot],
        options: VibestickDeviceOptions = VibestickDeviceOptions()
    ) -> DeviceDetectionResult {
        if let deviceSnapshot = snapshots.first(where: { isVibestickDevice($0, options: options) }) {
            return DeviceDetectionResult(
                kind: .vibestickDevice,
                message: "Detected \(options.device.name).",
                matchedIdentity: options.device,
                snapshot: deviceSnapshot)
        }

        if let bootloaderSnapshot = snapshots.first(where: { isBootloader($0, options: options) }) {
            return DeviceDetectionResult(
                kind: .bootloader,
                message: "Detected RP2 bootloader; waiting for Vibestick firmware.",
                matchedIdentity: options.bootloader,
                snapshot: bootloaderSnapshot)
        }

        return .none
    }

    public static func isVibestickDevice(
        _ snapshot: DeviceSnapshot,
        options: VibestickDeviceOptions = VibestickDeviceOptions()
    ) -> Bool {
        options.device.matches(instanceId: snapshot.instanceId)
            || options.device.matches(vendorId: snapshot.vendorId, productId: snapshot.productId)
    }

    public static func isBootloader(
        _ snapshot: DeviceSnapshot,
        options: VibestickDeviceOptions = VibestickDeviceOptions()
    ) -> Bool {
        options.bootloader.matches(instanceId: snapshot.instanceId)
            || options.bootloader.matches(vendorId: snapshot.vendorId, productId: snapshot.productId)
            || isBootloaderVolume(snapshot, options: options)
    }

    private static func isBootloaderVolume(
        _ snapshot: DeviceSnapshot,
        options: VibestickDeviceOptions
    ) -> Bool {
        if snapshot.volumeLabel?.caseInsensitiveCompare(options.bootloaderVolumeLabel) == .orderedSame {
            return true
        }

        return snapshot.boardInfoText?.range(
            of: "Board-ID: \(options.bootloaderBoardId)",
            options: .caseInsensitive) != nil
    }
}

public enum DeviceAutoLaunchAction: String, Codable, Sendable {
    case none
    case launch
    case alreadyRunning
    case debounced
    case bootloaderOnly
}

public struct DeviceAutoLaunchDecision: Codable, Equatable, Sendable {
    public let action: DeviceAutoLaunchAction
    public let message: String
}

public final class DeviceAutoLaunchPolicy: @unchecked Sendable {
    private let debounce: TimeInterval
    private var lastLaunchAt: Date?

    public init(debounce: TimeInterval) {
        self.debounce = debounce
    }

    public func evaluate(
        detection: DeviceDetectionResult,
        isGuiAlreadyRunning: Bool,
        now: Date
    ) -> DeviceAutoLaunchDecision {
        if detection.kind == .bootloader {
            return DeviceAutoLaunchDecision(
                action: .bootloaderOnly,
                message: "RP2 bootloader is connected; flash Vibestick firmware before auto-launching the GUI.")
        }

        if detection.kind != .vibestickDevice {
            return DeviceAutoLaunchDecision(action: .none, message: detection.message)
        }

        if isGuiAlreadyRunning {
            return DeviceAutoLaunchDecision(action: .alreadyRunning, message: "Vibestick GUI is already running.")
        }

        if let lastLaunchAt, now.timeIntervalSince(lastLaunchAt) < debounce {
            return DeviceAutoLaunchDecision(
                action: .debounced,
                message: "Vibestick device event ignored because the GUI was launched recently.")
        }

        lastLaunchAt = now
        return DeviceAutoLaunchDecision(action: .launch, message: "Vibestick device detected; launching the GUI.")
    }
}
