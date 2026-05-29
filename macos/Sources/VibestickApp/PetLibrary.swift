import AppKit
import Foundation
import VibestickMacCore

struct PetManifest: Codable, Equatable {
    var id: String
    var displayName: String
    var description: String
    var spritesheetPath: String
}

struct PetDefinition: Identifiable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let spritesheetURL: URL
    let isBuiltIn: Bool
}

struct PetImportMetadata {
    let displayName: String
    let description: String
}

enum PetLibraryError: LocalizedError, Equatable {
    case duplicate(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .duplicate(let id):
            return "宠物“\(id)”已存在。"
        case .invalid(let message):
            return message
        }
    }
}

final class PetLibrary {
    static let builtInPetId = "golden-shaded-cat"
    static let atlasSize = CGSize(width: 1536, height: 1872)

    private static let manifestFileName = "pet.json"
    private static let spritesheetFileName = "spritesheet.png"
    private static let selectionFileName = "pet-selection.json"

    private let rootDirectory: URL
    private let selectionURL: URL
    private let builtInSpritesheetURL: URL
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        rootDirectory: URL = VibestickPaths.userApplicationSupportDirectory.appendingPathComponent("pets", isDirectory: true),
        selectionURL: URL = VibestickPaths.userApplicationSupportDirectory.appendingPathComponent(selectionFileName),
        builtInSpritesheetURL: URL = PetLibrary.defaultBuiltInSpritesheetURL(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.selectionURL = selectionURL
        self.builtInSpritesheetURL = builtInSpritesheetURL
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    var builtInPet: PetDefinition {
        PetDefinition(
            id: Self.builtInPetId,
            displayName: "Golden Shaded Cat",
            description: "The built-in Vibestick desktop pet.",
            spritesheetURL: builtInSpritesheetURL,
            isBuiltIn: true)
    }

    func pets() -> [PetDefinition] {
        var result = [builtInPet]
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else {
            return result
        }

        for directory in directories.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(PetManifest.self, from: data)
            else {
                continue
            }
            let sheetURL = directory.appendingPathComponent(manifest.spritesheetPath)
            guard fileManager.fileExists(atPath: sheetURL.path) else {
                continue
            }
            result.append(PetDefinition(
                id: manifest.id,
                displayName: manifest.displayName,
                description: manifest.description,
                spritesheetURL: sheetURL,
                isBuiltIn: false))
        }

        var seen = Set<String>()
        return result.filter { pet in
            let key = pet.id.lowercased()
            guard !seen.contains(key) else {
                return false
            }
            seen.insert(key)
            return true
        }
    }

    func currentPet() -> PetDefinition {
        if let selected = readSelection(),
           let pet = pets().first(where: { $0.id.caseInsensitiveCompare(selected) == .orderedSame }) {
            return pet
        }
        return builtInPet
    }

    func selectPet(id: String) throws {
        guard pets().contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw PetLibraryError.invalid("找不到宠物“\(id)”。")
        }
        try writeSelection(id)
    }

    func importRawAtlas(_ sourceURL: URL, metadata: PetImportMetadata, replace: Bool = false) throws -> PetDefinition {
        let displayName = metadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            throw PetLibraryError.invalid("宠物名称不能为空。")
        }
        let id = Self.slugify(displayName)
        guard !id.isEmpty else {
            throw PetLibraryError.invalid("宠物名称需要包含字母或数字。")
        }
        let description = metadata.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Imported Vibestick pet."
            : metadata.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return try importValidatedSpritesheet(
            sourceURL,
            manifest: PetManifest(id: id, displayName: displayName, description: description, spritesheetPath: Self.spritesheetFileName),
            replace: replace)
    }

    func importPackage(_ packageURL: URL, replace: Bool = false) throws -> PetDefinition {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return try importPackageDirectory(packageURL, replace: replace)
        }

        guard fileManager.fileExists(atPath: packageURL.path) else {
            throw PetLibraryError.invalid("找不到宠物包文件。")
        }

        let staging = try createStagingDirectory()
        defer { try? fileManager.removeItem(at: staging) }
        let extracted = staging.appendingPathComponent("package", isDirectory: true)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        try extractZipSafely(packageURL, to: extracted)
        return try importPackageDirectory(extracted, replace: replace)
    }

    func exportPet(id: String, to outputURL: URL) throws {
        guard let pet = pets().first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw PetLibraryError.invalid("找不到宠物“\(id)”。")
        }

        let staging = try createStagingDirectory()
        defer { try? fileManager.removeItem(at: staging) }
        let manifest = PetManifest(
            id: pet.id,
            displayName: pet.displayName,
            description: pet.description,
            spritesheetPath: Self.spritesheetFileName)
        try writeManifest(manifest, to: staging.appendingPathComponent(Self.manifestFileName))
        try normalizeToPNG(pet.spritesheetURL, to: staging.appendingPathComponent(Self.spritesheetFileName))

        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try run("/usr/bin/zip", arguments: ["-qry", outputURL.path, Self.manifestFileName, Self.spritesheetFileName], currentDirectory: staging)
    }

    func deleteCustomPet(id: String) throws {
        guard id.caseInsensitiveCompare(Self.builtInPetId) != .orderedSame else {
            throw PetLibraryError.invalid("内置宠物不能删除。")
        }
        let target = rootDirectory.appendingPathComponent(Self.slugify(id), isDirectory: true)
        guard fileManager.fileExists(atPath: target.path) else {
            throw PetLibraryError.invalid("找不到宠物“\(id)”。")
        }
        try fileManager.removeItem(at: target)
        if readSelection()?.caseInsensitiveCompare(id) == .orderedSame {
            try writeSelection(Self.builtInPetId)
        }
    }

    func previewImage(for pet: PetDefinition) -> NSImage? {
        guard let image = NSImage(contentsOf: pet.spritesheetURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let frame = cgImage.cropping(to: CGRect(x: 0, y: 0, width: 192, height: 208))
        else {
            return nil
        }
        return NSImage(cgImage: frame, size: NSSize(width: 192, height: 208))
    }

    private func importPackageDirectory(_ directory: URL, replace: Bool) throws -> PetDefinition {
        let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw PetLibraryError.invalid("宠物包缺少 pet.json。")
        }
        let manifest = try readManifest(at: manifestURL)
        let spritesheetURL = try resolveSpritesheet(in: directory, manifestPath: manifest.spritesheetPath)
        return try importValidatedSpritesheet(spritesheetURL, manifest: manifest, replace: replace)
    }

    private func importValidatedSpritesheet(_ sourceURL: URL, manifest: PetManifest, replace: Bool) throws -> PetDefinition {
        let normalizedId = Self.slugify(try requireText(manifest.id, message: "宠物 id 不能为空。"))
        guard !normalizedId.isEmpty else {
            throw PetLibraryError.invalid("宠物 id 需要包含字母或数字。")
        }
        let displayName = try requireText(manifest.displayName, message: "宠物名称不能为空。")
        let description = manifest.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Imported Vibestick pet."
            : manifest.description.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateAtlas(sourceURL)

        let target = rootDirectory.appendingPathComponent(normalizedId, isDirectory: true)
        if fileManager.fileExists(atPath: target.path), !replace {
            throw PetLibraryError.duplicate(normalizedId)
        }

        let staging = try createStagingDirectory()
        defer { try? fileManager.removeItem(at: staging) }
        let stagedPet = staging.appendingPathComponent(normalizedId, isDirectory: true)
        try fileManager.createDirectory(at: stagedPet, withIntermediateDirectories: true)
        try normalizeToPNG(sourceURL, to: stagedPet.appendingPathComponent(Self.spritesheetFileName))
        let normalizedManifest = PetManifest(
            id: normalizedId,
            displayName: displayName,
            description: description,
            spritesheetPath: Self.spritesheetFileName)
        try writeManifest(normalizedManifest, to: stagedPet.appendingPathComponent(Self.manifestFileName))

        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: stagedPet, to: target)
        try writeSelection(normalizedId)
        return PetDefinition(
            id: normalizedManifest.id,
            displayName: normalizedManifest.displayName,
            description: normalizedManifest.description,
            spritesheetURL: target.appendingPathComponent(Self.spritesheetFileName),
            isBuiltIn: false)
    }

    private func validateAtlas(_ url: URL) throws {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw PetLibraryError.invalid("无法读取宠物 spritesheet；如果是 WebP，请确认当前系统支持该格式。")
        }
        guard cgImage.width == Int(Self.atlasSize.width), cgImage.height == Int(Self.atlasSize.height) else {
            throw PetLibraryError.invalid("宠物 spritesheet 必须是 1536x1872；当前是 \(cgImage.width)x\(cgImage.height)。")
        }
        guard Self.hasAlpha(cgImage) else {
            throw PetLibraryError.invalid("宠物 spritesheet 必须包含 alpha 透明通道。")
        }
    }

    private func normalizeToPNG(_ sourceURL: URL, to targetURL: URL) throws {
        guard let image = NSImage(contentsOf: sourceURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let representation = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .png, properties: [:])
        else {
            throw PetLibraryError.invalid("无法转换宠物 spritesheet 为 PNG。")
        }
        try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try representation.write(to: targetURL)
    }

    private func readManifest(at url: URL) throws -> PetManifest {
        do {
            let manifest = try decoder.decode(PetManifest.self, from: Data(contentsOf: url))
            let id = try requireText(manifest.id, message: "宠物 id 不能为空。")
            let displayName = try requireText(manifest.displayName, message: "宠物名称不能为空。")
            let spritesheetPath = try requireText(manifest.spritesheetPath, message: "宠物 spritesheetPath 不能为空。")
            guard Self.isSafeRelativePath(spritesheetPath) else {
                throw PetLibraryError.invalid("宠物 spritesheetPath 必须位于包内。")
            }
            return PetManifest(
                id: id,
                displayName: displayName,
                description: manifest.description.trimmingCharacters(in: .whitespacesAndNewlines),
                spritesheetPath: spritesheetPath)
        } catch let error as PetLibraryError {
            throw error
        } catch {
            throw PetLibraryError.invalid("无法读取宠物 manifest：\(error.localizedDescription)")
        }
    }

    private func writeManifest(_ manifest: PetManifest, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: url)
    }

    private func resolveSpritesheet(in directory: URL, manifestPath: String) throws -> URL {
        guard Self.isSafeRelativePath(manifestPath) else {
            throw PetLibraryError.invalid("宠物 spritesheetPath 必须位于包内。")
        }
        let candidate = directory.appendingPathComponent(manifestPath)
        if fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        for fallback in ["spritesheet.png", "spritesheet.webp"] {
            let fallbackURL = directory.appendingPathComponent(fallback)
            if fileManager.fileExists(atPath: fallbackURL.path) {
                return fallbackURL
            }
        }
        throw PetLibraryError.invalid("宠物包缺少引用的 spritesheet。")
    }

    private func extractZipSafely(_ zipURL: URL, to destination: URL) throws {
        let listing = try run("/usr/bin/zipinfo", arguments: ["-1", zipURL.path])
        for rawEntry in listing.split(separator: "\n") {
            let entry = String(rawEntry)
            guard Self.isSafeRelativePath(entry) else {
                throw PetLibraryError.invalid("宠物包包含不安全路径。")
            }
        }
        try run("/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, destination.path])
    }

    private func readSelection() -> String? {
        guard let data = try? Data(contentsOf: selectionURL),
              let selection = try? decoder.decode(PetSelection.self, from: data)
        else {
            return nil
        }
        return selection.currentPetId
    }

    private func writeSelection(_ id: String) throws {
        try fileManager.createDirectory(at: selectionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(PetSelection(currentPetId: id)).write(to: selectionURL)
    }

    private func createStagingDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vibestick-pet-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func run(_ executable: String, arguments: [String], currentDirectory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw PetLibraryError.invalid(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "宠物包处理失败。" : stderr)
        }
        return stdout
    }

    private func requireText(_ value: String, message: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw PetLibraryError.invalid(message)
        }
        return text
    }

    static func slugify(_ value: String) -> String {
        var output = ""
        var previousWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
            if isAllowed {
                output.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                output.append("-")
                previousWasDash = true
            }
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            return false
        }
        return !path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        case .none, .noneSkipFirst, .noneSkipLast, .alphaOnly:
            return false
        @unknown default:
            return false
        }
    }

    static func defaultBuiltInSpritesheetURL() -> URL {
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("VibestickMac_VibestickApp.bundle", isDirectory: true),
           let bundle = Bundle(url: resourceURL),
           let url = bundle.url(
            forResource: "golden-shaded-cat-spritesheet.cleaned",
            withExtension: "png",
            subdirectory: "PetSprites")
                ?? bundle.url(forResource: "golden-shaded-cat-spritesheet.cleaned", withExtension: "png")
        {
            return url
        }

        return Bundle.module.url(
            forResource: "golden-shaded-cat-spritesheet.cleaned",
            withExtension: "png",
            subdirectory: "PetSprites")
            ?? Bundle.module.url(forResource: "golden-shaded-cat-spritesheet.cleaned", withExtension: "png")
            ?? URL(fileURLWithPath: "/dev/null")
    }

    private struct PetSelection: Codable {
        let currentPetId: String
    }
}
