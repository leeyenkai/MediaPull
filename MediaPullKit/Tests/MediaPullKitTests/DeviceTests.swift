import Foundation
@testable import MediaPullDevices
import XCTest

/// Section 41: the read-only MTP client, routing, the import plan, the record of imports and the importer.
final class DeviceTests: XCTestCase {
    // MARK: Read-only (R-4107)

    func testOnlyReadOperationsCanBeBuilt() {
        XCTAssertTrue(MTPOperation.allowedCodes.isDisjoint(with: MTPOperation.writeCodes))
        let built: [MTPOperation] = [
            .getDeviceInfo(), .openSession(1), .closeSession(), .getStorageIDs(), .getStorageInfo(1),
            .getObjectHandles(storage: 1, parent: 0xFFFF_FFFF), .getObjectInfo(1), .getObject(1), .getThumb(1),
            .getPartialObject(1, offset: 0, length: 1), .getPartialObject64(1, offset: 0, length: 1),
            .getObjectPropsSupported(format: 0x3000), .getObjectPropValue(1, property: 0xDC04), .getObjectPropList(1, property: 0xDC04),
            .getObjectReferences(1),
        ]
        XCTAssertEqual(Set(built.map(\.code)), MTPOperation.allowedCodes)
        let ranges = Array(0x1000 ... 0x1025) + Array(0x9801 ... 0x9811) + Array(0x95C1 ... 0x95C5)
        for code in ranges.map(UInt16.init) where MTPOperation.writeCodes.contains(code) {
            XCTAssertFalse(MTPOperation.allowedCodes.contains(code), "0x\(String(code, radix: 16)) changes a device")
        }
        for code in [0x100B, 0x100D, 0x100F, 0x1019, 0x101A, 0x9804, 0x9808] as [UInt16] {
            XCTAssertTrue(MTPOperation.writeCodes.contains(code), "delete, send, format, move, copy and set are all known writes")
        }
    }

    func testCommandsCarryTheirParametersLittleEndian() throws {
        let table: [(MTPOperation, [UInt32])] = [
            (.getDeviceInfo(), []),
            (.openSession(7), [7]),
            (.getObjectReferences(9), [9]),
            (.getObjectHandles(storage: 0x0001_0001, parent: 0xFFFF_FFFF), [0x0001_0001, 0, 0xFFFF_FFFF]),
            (.getPartialObject64(5, offset: 0x1_0000_0002, length: 8), [5, 2, 1, 8]),
            (.getObjectPropList(3, property: 0xDC04), [3, 0, 0xDC04, 0, 0]),
        ]
        for (operation, parameters) in table {
            let data = operation.command(transaction: 0x0102_0304)
            let header = try MTPContainer.header(data)
            XCTAssertEqual(Int(header.length), 12 + 4 * parameters.count)
            XCTAssertEqual(header.type, 1)
            XCTAssertEqual(header.code, operation.code)
            XCTAssertEqual(header.transaction, 0x0102_0304)
            XCTAssertEqual(data.count, Int(header.length))
            XCTAssertEqual((0 ..< parameters.count).map { data.le32(12 + 4 * $0) }, parameters)
            XCTAssertEqual(Array(data.prefix(4)), [UInt8(12 + 4 * parameters.count), 0, 0, 0])
        }
    }

    // MARK: Containers

    func testContainersSplitAcrossPacketsAreJoined() throws {
        for size in [0, 1, 500, 512 - 12, 512, 16384 - 12, 16384, 40000] {
            let payload = Data((0 ..< size).map { UInt8($0 % 251) })
            var stream = MTPContainer.data(payload, code: 0x1009, transaction: 4)
            // A data phase that fills whole packets ends with a zero-length packet.
            let packet = size % 2 == 0 ? 512 : 16384
            var packets = stride(from: 0, to: stream.count, by: packet).map { stream.subdata(in: $0 ..< min(stream.count, $0 + packet)) }
            if stream.count % packet == 0 { packets.append(Data()) }
            stream = MTPContainer.response(MTPReply.ok, transaction: 4, parameters: [9])
            packets.append(stream)
            let reply = try MTPContainer.reply(packets)
            XCTAssertEqual(reply.data, payload, "size \(size)")
            XCTAssertEqual(reply.code, MTPReply.ok)
            XCTAssertEqual(reply.parameters, [9])
        }
    }

    func testBadContainersAreRefused() {
        let table: [(String, [Data])] = [
            ("shorter than a header", [Data([1, 2, 3])]),
            ("length below 12", [Data([4, 0, 0, 0, 3, 0, 1, 0x20, 0, 0, 0, 0])]),
            ("cut short", [Data([40, 0, 0, 0, 2, 0, 9, 0x10, 0, 0, 0, 0, 1, 2])]),
            ("no response", [MTPContainer.data(Data([1]), code: 0x1009, transaction: 1)]),
        ]
        for (what, packets) in table {
            XCTAssertThrowsError(try MTPContainer.reply(packets), what)
        }
    }

    func testPassThroughDataIsTakenWithOrWithoutItsHeader() {
        let payload = Data([1, 2, 3, 4, 5])
        XCTAssertEqual(MTPContainer.payload(MTPContainer.data(payload, code: 0x1008, transaction: 2), code: 0x1008), payload)
        XCTAssertEqual(MTPContainer.payload(payload, code: 0x1008), payload)
        // Bytes that only look like a header of another operation are data.
        let other = MTPContainer.data(payload, code: 0x1009, transaction: 2)
        XCTAssertEqual(MTPContainer.payload(other, code: 0x1008), other)
    }

    // MARK: Datasets

    func testStringsAreReadAsTheDeviceWritesThem() throws {
        for text in ["", "a", "IMG_0001.JPG", "Photos d’été", "東京タワー.jpg", "🐈 cat.heic", String(repeating: "x", count: 200)] {
            var data = Data()
            data.appendPTPString(text)
            data.appendLE(UInt32(0xDEAD_BEEF))
            var reader = MTPReader(data)
            XCTAssertEqual(try reader.string(), text)
            XCTAssertEqual(try reader.u32(), 0xDEAD_BEEF, "the string's length was read exactly: \(text)")
        }
        var truncated = MTPReader(Data([5, 0x41, 0]))
        XCTAssertThrowsError(try truncated.string())
        var array = MTPReader(Data([0xFF, 0xFF, 0, 0, 1, 0]))
        XCTAssertThrowsError(try array.array16(), "a count longer than the data")
    }

    func testObjectInfoRoundTrips() throws {
        let taken = Date(timeIntervalSince1970: 1_717_266_605)
        let table = [
            MTPObjectInfo(storage: 0x0001_0001, format: 0x3801, compressedSize: 2_345_678, thumbFormat: 0x3801, parent: 12,
                          name: "PXL_20240601_183005.jpg", captured: taken, modified: taken),
            MTPObjectInfo(storage: 0x0002_0001, format: 0x3001, compressedSize: 0, parent: 0xFFFF_FFFF, name: "DCIM"),
            MTPObjectInfo(storage: 1, format: 0x300B, compressedSize: 0xFFFF_FFFF, parent: 3, name: "long video.mp4"),
        ]
        for info in table {
            XCTAssertEqual(try MTPObjectInfo(info.encoded()), info)
        }
        XCTAssertTrue(table[1].isFolder)
    }

    func testPTPDatesInEveryForm() {
        let utc = { (y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int) -> Date? in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))
        }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let table: [(String, Date?)] = [
            ("20240102T030405Z", utc(2024, 1, 2, 3, 4, 5)),
            ("20240102T030405.0Z", utc(2024, 1, 2, 3, 4, 5)),
            ("20240102T110405+0800", utc(2024, 1, 2, 3, 4, 5)),
            ("20240101T220405-0500", utc(2024, 1, 2, 3, 4, 5)),
            ("20240102T030405", local.date(from: DateComponents(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 5))),
            ("", nil),
            ("2024-01-02", nil),
            ("20241302T030405Z", nil),
            ("20240102X030405", nil),
        ]
        for (text, expected) in table {
            XCTAssertEqual(MTPDate.parse(text), expected, text)
        }
        let date = utc(2025, 12, 31, 23, 59, 58)!
        XCTAssertEqual(MTPDate.parse(MTPDate.format(date)), date)
    }

    // MARK: Session against a stand-in phone

    func testTheSessionListsReadsAndSendsOnlyReads() async throws {
        let phone = MTPResponderSimulator()
        let dcim = await phone.add("DCIM")
        let camera = await phone.add("Camera", in: dcim)
        let big = Data((0 ..< 300_000).map { UInt8($0 % 253) })
        let photo = await phone.add("PXL_1.jpg", in: camera, data: big, captured: Date(timeIntervalSince1970: 1_700_000_000))
        await phone.add("notes.txt", in: camera, data: Data("x".utf8))
        await phone.add("PXL_1.jpg.AAE", in: camera, data: Data("x".utf8))
        await phone.setBusy(2)
        let session = MTPSession(transport: phone)
        let info = try await session.open()
        XCTAssertTrue(info.speaksMTP)
        XCTAssertEqual(info.serial, "SIM0001")
        let identity = DeviceIdentity(name: "Pixel", serial: info.serial, vendorID: 0x18D1, productID: 0x4EE1)
        let source = MTPSource(identity: identity, session: session)
        let storages = try await source.storages()
        XCTAssertEqual(storages.map(\.name), ["Internal shared storage"])
        let top = try await source.children(of: DeviceFolder(storage: storages[0].id))
        XCTAssertEqual(top.map(\.name), ["DCIM"])
        let inside = try await source.children(of: DeviceFolder(storage: storages[0].id, ref: String(camera)))
        XCTAssertEqual(inside.map(\.name), ["PXL_1.jpg"], "only media are listed (R-4103)")
        XCTAssertEqual(inside[0].size, Int64(big.count))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return XCTFail("no file") }
        let handle = try FileHandle(forWritingTo: url)
        try await session.read(photo, size: UInt64(big.count), into: handle, chunk: 64 * 1024) { _ in }
        try handle.close()
        XCTAssertEqual(try Data(contentsOf: url), big, "chunked reads join up exactly")

        do {
            _ = try await session.objectInfo(999)
            XCTFail("an unknown handle is an error")
        } catch let MTPError.response(code, operation) {
            XCTAssertEqual(code, MTPReply.invalidObjectHandle)
            XCTAssertEqual(operation, 0x1008)
        }
        let received = await phone.received
        XCTAssertTrue(Set(received).isSubset(of: MTPOperation.allowedCodes))
        XCTAssertTrue(received.contains(0x95C1), "64-bit partial reads when the phone has them")
    }

    func testOlderPhonesAreReadWithThirtyTwoBitPartialReads() async throws {
        let phone = MTPResponderSimulator(supports64: false)
        let data = Data((0 ..< 70000).map { UInt8($0 % 7) })
        let handle = await phone.add("a.mp4", data: data)
        let session = MTPSession(transport: phone)
        _ = try await session.open()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        try await session.read(handle, size: UInt64(data.count), into: file, chunk: 16384) { _ in }
        try file.close()
        XCTAssertEqual(try Data(contentsOf: url), data)
        let received = await phone.received
        XCTAssertTrue(received.contains(0x101B))
        XCTAssertFalse(received.contains(0x95C1))
    }

    func testRouting() {
        let table: [(Int, String?, DeviceRouting.Backend)] = [
            (0x05AC, "microsoft.com: 1.0;", .imageCapture),
            (0x05AC, nil, .imageCapture),
            (0x18D1, "microsoft.com: 1.0; android.com: 1.0;", .mtp),
            (0x04E8, "Microsoft.com: 1.0;", .mtp),
            (0x04E8, "", .imageCapture),
            (0x04A9, nil, .imageCapture),
        ]
        for (vendor, extensions, backend) in table {
            XCTAssertEqual(DeviceRouting.backend(vendorID: vendor, extensions: extensions), backend, "\(vendor) \(extensions ?? "nil")")
        }
    }

    // MARK: Import plan (R-4104, R-4105)

    private func entry(_ name: String, size: Int64 = 100, pair: String? = nil, fingerprint: String? = nil) -> DeviceEntry {
        DeviceEntry(id: "0/\(name)", ref: name, storage: "0", name: name, isFolder: false, size: size,
                    taken: Date(timeIntervalSince1970: 1_700_000_000), fingerprint: fingerprint, pairKey: pair)
    }

    func testTheImportPlan() {
        let photo = entry("IMG_0001.HEIC", pair: "g1"), clip = entry("IMG_0001.MOV", pair: "g1")
        let plain = entry("IMG_0002.JPG"), video = entry("IMG_0003.MOV", pair: "g3")
        let done = entry("IMG_0004.JPG", fingerprint: "abc"), there = entry("IMG_0005.PNG", size: 42)
        let all = [clip, photo, plain, video, done, there, entry("IMG_0001.AAE")]
        let imported: Set<String> = [done.importKey]
        let existing: Set<String> = [ImportPlan.existingKey(name: "img_0005.png", size: 42)]

        let without = ImportPlan.make(all, imported: imported, existing: existing, includeClips: false)
        XCTAssertEqual(without.items.map(\.entry.name), ["IMG_0001.HEIC", "IMG_0002.JPG", "IMG_0003.MOV"])
        XCTAssertEqual(without.skipped, 2)
        XCTAssertEqual(without.clipsLeftOut, 1)

        let with = ImportPlan.make(all, imported: imported, existing: existing, includeClips: true)
        XCTAssertEqual(with.items.map(\.entry.name), ["IMG_0001.HEIC", "IMG_0001.MOV", "IMG_0002.JPG", "IMG_0003.MOV"])
        XCTAssertEqual(with.items[1].clipOf, photo.id, "the clip follows its photo")
        XCTAssertNil(with.items[3].clipOf, "a video alone is no clip")

        let photoDone = ImportPlan.make([photo, clip], imported: [photo.importKey], existing: [], includeClips: true)
        XCTAssertEqual(photoDone.items, [ImportItem(entry: clip, clipOf: nil)], "a clip whose photo came earlier keeps its own name")
    }

    func testImportKeys() {
        XCTAssertEqual(entry("a.jpg", fingerprint: "F1").importKey, "f:F1")
        XCTAssertEqual(entry("A.JPG").importKey, entry("a.jpg").importKey, "names compare without case")
        XCTAssertNotEqual(entry("a.jpg", size: 1).importKey, entry("a.jpg", size: 2).importKey)
        XCTAssertNotEqual(DeviceIdentity(name: "iPhone", serial: "X", vendorID: 1, productID: 2).key,
                          DeviceIdentity(name: "iPhone", serial: nil, vendorID: 1, productID: 2).key)
        XCTAssertEqual(DeviceIdentity(name: "Pixel", serial: "  ", vendorID: 1, productID: 2).key, "usb:1:2:Pixel")
    }

    func testTheRecordOfImportsSurvivesAndSetsABadFileAside() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let device = DeviceIdentity(name: "iPhone", serial: "ABC", vendorID: 0x05AC, productID: 0x12A8)
        let index = ImportedIndex(folder: folder, device: device)
        await index.record("f:1")
        await index.record("n:a.jpg|1|2")
        await index.save()
        let again = ImportedIndex(folder: folder, device: device)
        let keys = await again.all()
        XCTAssertEqual(keys, ["f:1", "n:a.jpg|1|2"])
        try Data("not json".utf8).write(to: again.url)
        let fresh = ImportedIndex(folder: folder, device: device)
        let empty = await fresh.all()
        XCTAssertTrue(empty.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(names.contains { $0.contains("unreadable") }, "the bad file is kept aside: \(names)")
        await fresh.forget()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.url.path))
    }

    // MARK: Importer

    func testTheImporterCopiesNamesAndDatesWithoutOverwriting() async throws {
        let fm = FileManager.default
        let destination = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let records = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: destination)
            try? fm.removeItem(at: records)
        }
        try Data("already here".utf8).write(to: destination.appendingPathComponent("IMG_1.jpg"))
        let phone = MTPResponderSimulator()
        let taken = Date(timeIntervalSince1970: 1_600_000_000)
        await phone.add("IMG_1.jpg", data: Data(repeating: 1, count: 5000), captured: taken)
        await phone.add("a:b.jpg", data: Data(repeating: 2, count: 10), captured: taken)
        let session = MTPSession(transport: phone)
        let info = try await session.open()
        let source = MTPSource(identity: DeviceIdentity(name: "Pixel", serial: info.serial, vendorID: 1, productID: 2), session: session)
        let entries = try await source.children(of: DeviceFolder(storage: "65537"))
        let index = ImportedIndex(folder: records, device: source.identity)
        let plan = ImportPlan.make(entries, imported: [], existing: [], includeClips: false)
        let outcome = await DeviceImporter.run(plan.items, from: source, into: destination, index: index) { _, _, _ in }
        XCTAssertTrue(outcome.failed.isEmpty, "\(outcome.failed.map(\.message))")
        let names = outcome.placed.map(\.lastPathComponent).sorted()
        XCTAssertEqual(names, ["IMG_1 2.jpg", "a_b.jpg"], "a taken name gets a number; names are made safe")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("IMG_1.jpg"), encoding: .utf8), "already here")
        let dates = try fm.attributesOfItem(atPath: destination.appendingPathComponent("a_b.jpg").path)
        XCTAssertEqual(dates[.modificationDate] as? Date, taken)
        XCTAssertEqual(dates[.creationDate] as? Date, taken)
        let recorded = await index.all()
        XCTAssertEqual(recorded, Set(entries.map(\.importKey)))
        let next = ImportPlan.make(entries, imported: recorded, existing: [], includeClips: false)
        XCTAssertTrue(next.items.isEmpty, "Import New finds nothing new")
    }

    func testUnpluggingFailsWhatIsLeft() async throws {
        let fm = FileManager.default
        let destination = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: destination) }
        let phone = MTPResponderSimulator()
        for number in 1 ... 3 {
            await phone.add("IMG_\(number).jpg", data: Data(repeating: UInt8(number), count: 100))
        }
        let session = MTPSession(transport: phone)
        _ = try await session.open()
        let source = MTPSource(identity: DeviceIdentity(name: "Pixel", serial: "S", vendorID: 1, productID: 2), session: session)
        let entries = try await source.children(of: DeviceFolder(storage: "65537"))
        await phone.setDisconnected(true)
        let index = ImportedIndex(folder: destination.appendingPathComponent(".records"), device: source.identity)
        let items = entries.map { ImportItem(entry: $0) }
        let outcome = await DeviceImporter.run(items, from: source, into: destination, index: index) { _, _, _ in }
        XCTAssertEqual(outcome.failed.count, 3)
        XCTAssertEqual(Set(outcome.failed.map(\.message)), ["The device was disconnected."])
    }

    func testClipsTakeTheirPhotosPlacedName() {
        let clip = ImportItem(entry: entry("IMG_0001.MOV"), clipOf: "0/IMG_0001.HEIC")
        XCTAssertEqual(DeviceImporter.name(for: clip, photoNames: ["0/IMG_0001.HEIC": "IMG_0001 2"]), "IMG_0001 2.MOV")
        XCTAssertEqual(DeviceImporter.name(for: clip, photoNames: [:]), "IMG_0001.MOV")
    }
}
