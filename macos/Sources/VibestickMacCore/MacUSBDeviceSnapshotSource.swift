import Foundation
import IOKit

public final class MacUSBDeviceSnapshotSource: @unchecked Sendable {
    private let options: VibestickDeviceOptions
    private let volumesRoot: URL
    private let fileManager: FileManager
    private let includeUSBDevices: Bool

    public init(
        options: VibestickDeviceOptions = VibestickDeviceOptions(),
        volumesRoot: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        fileManager: FileManager = .default,
        includeUSBDevices: Bool = true
    ) {
        self.options = options
        self.volumesRoot = volumesRoot
        self.fileManager = fileManager
        self.includeUSBDevices = includeUSBDevices
    }

    public func getSnapshots() -> [DeviceSnapshot] {
        (includeUSBDevices ? usbSnapshots() : []) + bootloaderVolumeSnapshots()
    }

    public func startAttachNotifications(
        queue: DispatchQueue = .main,
        handler: @escaping @Sendable () -> Void
    ) -> MacUSBDeviceNotificationToken? {
        guard let notificationPort = IONotificationPortCreate(kIOMainPortDefault) else {
            return nil
        }

        let box = MacUSBDeviceNotificationBox(handler: handler)
        IONotificationPortSetDispatchQueue(notificationPort, queue)

        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            notificationPort,
            kIOMatchedNotification,
            IOServiceMatching("IOUSBDevice"),
            macUSBDeviceMatchedCallback,
            Unmanaged.passUnretained(box).toOpaque(),
            &iterator)
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(notificationPort)
            return nil
        }

        Self.drain(iterator)
        return MacUSBDeviceNotificationToken(notificationPort: notificationPort, iterator: iterator, box: box)
    }

    private func usbSnapshots() -> [DeviceSnapshot] {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBDevice"), &iterator)
        guard result == KERN_SUCCESS else {
            return []
        }
        defer {
            IOObjectRelease(iterator)
        }

        var snapshots: [DeviceSnapshot] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else {
                break
            }
            defer {
                IOObjectRelease(service)
            }

            guard let vendorId = Self.intProperty("idVendor", service: service),
                  let productId = Self.intProperty("idProduct", service: service)
            else {
                continue
            }

            let serial = Self.stringProperty("USB Serial Number", service: service)
            let instanceId = Self.instanceId(vendorId: vendorId, productId: productId, serial: serial)
            snapshots.append(DeviceSnapshot(
                instanceId: instanceId,
                friendlyName: Self.stringProperty("USB Product Name", service: service)
                    ?? Self.stringProperty("Product Name", service: service),
                vendorId: vendorId,
                productId: productId))
        }

        return snapshots
    }

    private func bootloaderVolumeSnapshots() -> [DeviceSnapshot] {
        let bootloaderVolume = volumesRoot.appendingPathComponent(options.bootloaderVolumeLabel, isDirectory: true)
        guard fileManager.fileExists(atPath: bootloaderVolume.path) else {
            return []
        }

        let boardInfoPath = bootloaderVolume.appendingPathComponent("INFO_UF2.TXT")
        let boardInfoText = try? String(contentsOf: boardInfoPath, encoding: .utf8)
        return [
            DeviceSnapshot(
                volumePath: bootloaderVolume.path,
                volumeLabel: options.bootloaderVolumeLabel,
                boardInfoText: boardInfoText)
        ]
    }

    private static func intProperty(_ name: String, service: io_object_t) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func stringProperty(_ name: String, service: io_object_t) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        else {
            return nil
        }

        return value as? String
    }

    private static func instanceId(vendorId: Int, productId: Int, serial: String?) -> String {
        let base = String(format: "USB\\VID_%04X&PID_%04X", vendorId, productId)
        guard let serial, !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base
        }
        return "\(base)\\\(serial)"
    }

    private static func drain(_ iterator: io_iterator_t) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else {
                break
            }
            IOObjectRelease(service)
        }
    }
}

public final class MacUSBDeviceNotificationToken: @unchecked Sendable {
    private let notificationPort: IONotificationPortRef
    private let iterator: io_iterator_t
    private let box: MacUSBDeviceNotificationBox

    fileprivate init(
        notificationPort: IONotificationPortRef,
        iterator: io_iterator_t,
        box: MacUSBDeviceNotificationBox
    ) {
        self.notificationPort = notificationPort
        self.iterator = iterator
        self.box = box
    }

    deinit {
        _ = box
        IOObjectRelease(iterator)
        IONotificationPortDestroy(notificationPort)
    }
}

private final class MacUSBDeviceNotificationBox: @unchecked Sendable {
    let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }
}

private let macUSBDeviceMatchedCallback: IOServiceMatchingCallback = { context, iterator in
    while true {
        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            break
        }
        IOObjectRelease(service)
    }

    guard let context else {
        return
    }
    let box = Unmanaged<MacUSBDeviceNotificationBox>.fromOpaque(context).takeUnretainedValue()
    box.handler()
}
