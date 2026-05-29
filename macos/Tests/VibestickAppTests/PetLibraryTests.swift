import AppKit
import XCTest
@testable import VibestickApp

final class PetLibraryTests: XCTestCase {
    func testRawAtlasImportSelectsPet() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let library = makeLibrary(in: temp)

        let imported = try library.importRawAtlas(
            PetLibrary.defaultBuiltInSpritesheetURL(),
            metadata: PetImportMetadata(displayName: "Test Cat", description: "Imported for tests."))

        XCTAssertEqual(imported.id, "test-cat")
        XCTAssertFalse(imported.isBuiltIn)
        XCTAssertEqual(library.currentPet().id, "test-cat")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("pets/test-cat/pet.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("pets/test-cat/spritesheet.png").path))
    }

    func testExportPackageContainsManifestAndSpritesheet() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let library = makeLibrary(in: temp)
        _ = try library.importRawAtlas(
            PetLibrary.defaultBuiltInSpritesheetURL(),
            metadata: PetImportMetadata(displayName: "Export Cat", description: "Export tests."))

        let output = temp.appendingPathComponent("export-cat.vibestick-pet.zip")
        try library.exportPet(id: "export-cat", to: output)
        let entries = try zipEntries(output)

        XCTAssertTrue(entries.contains("pet.json"))
        XCTAssertTrue(entries.contains("spritesheet.png"))
    }

    func testSelectionFallsBackToBuiltInPet() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try Data(#"{"currentPetId":"missing"}"#.utf8)
            .write(to: temp.appendingPathComponent("pet-selection.json"))
        let library = makeLibrary(in: temp)

        let current = library.currentPet()

        XCTAssertEqual(current.id, PetLibrary.builtInPetId)
        XCTAssertTrue(current.isBuiltIn)
    }

    func testDuplicateImportRequiresReplacement() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let library = makeLibrary(in: temp)
        _ = try library.importRawAtlas(
            PetLibrary.defaultBuiltInSpritesheetURL(),
            metadata: PetImportMetadata(displayName: "Dupe Cat", description: "First."))

        XCTAssertThrowsError(try library.importRawAtlas(
            PetLibrary.defaultBuiltInSpritesheetURL(),
            metadata: PetImportMetadata(displayName: "Dupe Cat", description: "Second."))) { error in
            XCTAssertEqual(error as? PetLibraryError, .duplicate("dupe-cat"))
        }
    }

    func testInvalidAtlasSizeIsRejected() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let library = makeLibrary(in: temp)
        let invalid = temp.appendingPathComponent("invalid.png")
        try writeTransparentPNG(invalid, width: 128, height: 128)

        XCTAssertThrowsError(try library.importRawAtlas(
            invalid,
            metadata: PetImportMetadata(displayName: "Tiny Cat", description: "Too small.")))
    }

    private func makeLibrary(in directory: URL) -> PetLibrary {
        PetLibrary(
            rootDirectory: directory.appendingPathComponent("pets", isDirectory: true),
            selectionURL: directory.appendingPathComponent("pet-selection.json"),
            builtInSpritesheetURL: PetLibrary.defaultBuiltInSpritesheetURL())
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vibestick-pet-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func zipEntries(_ url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.split(separator: "\n").map(String.init)
    }

    private func writeTransparentPNG(_ url: URL, width: Int, height: Int) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0),
              let data = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("Could not create PNG fixture.")
            return
        }
        try data.write(to: url)
    }
}
