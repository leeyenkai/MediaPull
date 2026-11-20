// Spike for D-116 (SPEC section 41): how this Mac reaches a phone plugged in by USB. Not part of the app.
//
//   swift docs/spikes/device-probe.swift icc   # Apple's camera framework: devices, contents, PTP pass-through reads
//   swift docs/spikes/device-probe.swift usb   # still-image USB interfaces opened directly, then with seize
//
// Run `usb` first with nothing else open that imports photos; `icc` makes the system's camera daemon open the phone.
// Only read operations are sent: GetDeviceInfo, OpenSession, GetStorageIDs, GetObjectHandles, GetObjectInfo,
// GetPartialObject64, CloseSession. Nothing is written to the phone.

import Foundation
import ImageCaptureCore
import IOKit
import IOUSBHost

func line(_ text: String) { print(text); fflush(stdout) }

// MARK: PTP containers (little-endian: length, type, code, transaction id, parameters)

func command(_ code: UInt16, _ transaction: UInt32, _ params: [UInt32] = []) -> Data {
    var data = Data()
    func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    put32(UInt32(12 + 4 * params.count))
    put16(1)
    put16(code)
    put32(transaction)
    params.forEach(put32)
    return data
}

func u16(_ d: Data, _ o: Int) -> UInt16 { d.count >= o + 2 ? UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 : 0 }
func u32(_ d: Data, _ o: Int) -> UInt32 { d.count >= o + 4 ? UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16 : 0 }

/// A PTP string: a count of UTF-16 units (with the terminator), then the units.
func string(_ d: Data, _ o: inout Int) -> String {
    guard o < d.count else { return "" }
    let count = Int(d[d.startIndex + o])
    o += 1
    var units: [UInt16] = []
    for i in 0 ..< count { units.append(u16(d, o + 2 * i)) }
    o += 2 * count
    return String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
}

/// Manufacturer, model, version and serial from a DeviceInfo dataset, and whether it speaks MTP.
func describeDeviceInfo(_ d: Data) -> String {
    var o = 8
    let ext = string(d, &o)
    o += 2
    for _ in 0 ..< 5 { o += 4 + 2 * Int(u32(d, o)) } // operations, events, device props, capture and image formats
    let maker = string(d, &o), model = string(d, &o), version = string(d, &o), serial = string(d, &o)
    return "extensions \"\(ext)\" (MTP: \(ext.contains("microsoft.com"))), \(maker) \(model) \(version), serial \(serial)"
}

// MARK: Apple's camera framework

final class Probe: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    let browser = ICDeviceBrowser()
    var transaction: UInt32 = 1

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        line("icc: browsing; plug in a phone (Ctrl-C to stop)")
    }

    func deviceBrowser(_: ICDeviceBrowser, didAdd device: ICDevice, moreComing _: Bool) {
        line(String(format: "icc: added \"%@\" vendor 0x%04x product 0x%04x transport %@ kind %@",
                    device.name ?? "?", device.usbVendorID, device.usbProductID, device.transportType ?? "?",
                    device.productKind ?? "?"))
        line("icc: capabilities \(device.capabilities)")
        guard let camera = device as? ICCameraDevice else { return }
        camera.delegate = self
        camera.mediaPresentation = .originalAssets
        camera.requestOpenSession()
    }

    func deviceBrowser(_: ICDeviceBrowser, didRemove device: ICDevice, moreGoing _: Bool) { line("icc: removed \(device.name ?? "?")") }

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        line("icc: session open on \(device.name ?? "?"): \(error.map { "\($0)" } ?? "ok")")
    }

    func didRemove(_ device: ICDevice) { line("icc: device went away \(device.name ?? "?")") }
    func device(_: ICDevice, didCloseSessionWithError _: (any Error)?) {}
    func cameraDevice(_: ICCameraDevice, didAdd _: [ICCameraItem]) {}
    func cameraDevice(_: ICCameraDevice, didRemove _: [ICCameraItem]) {}
    func cameraDevice(_: ICCameraDevice, didReceiveThumbnail _: CGImage?, for _: ICCameraItem, error _: (any Error)?) {}
    func cameraDevice(_: ICCameraDevice, didReceiveMetadata _: [AnyHashable: Any]?, for _: ICCameraItem, error _: (any Error)?) {}
    func cameraDevice(_: ICCameraDevice, didRenameItems _: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_: ICCameraDevice) {}
    func cameraDevice(_: ICCameraDevice, didReceivePTPEvent _: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) { line("icc: access allowed on \(device.name ?? "?")") }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { line("icc: access restricted on \(device.name ?? "?") (locked or not trusted)") }

    func deviceDidBecomeReady(withCompleteContentCatalog camera: ICCameraDevice) {
        let files = camera.mediaFiles ?? []
        line("icc: ready; \((camera.contents ?? []).count) top items, \(files.count) media files; serial \(camera.serialNumberString ?? "none")")
        for case let file as ICCameraFile in files.prefix(5) {
            line("icc:   \(file.name ?? "?") \(file.fileSize) bytes, UTI \(file.uti ?? "?"), fingerprint \(file.fingerprint ?? "none"), "
                + "group \(file.groupUUID ?? "-") related \(file.relatedUUID ?? "-"), sidecars \((file.sidecarFiles ?? []).count)")
        }
        passThrough(camera)
    }

    /// MTP reads through the framework's own session: does the system hand them on, and how fast?
    func passThrough(_ camera: ICCameraDevice) {
        send(camera, 0x1001) { data, _ in
            line("icc: GetDeviceInfo: \(describeDeviceInfo(data))")
            self.send(camera, 0x1004) { data, _ in
                let storage = u32(data, 4)
                line("icc: GetStorageIDs: first 0x\(String(storage, radix: 16)) (\(u32(data, 0)) storages)")
                self.send(camera, 0x1007, [storage, 0, 0xFFFF_FFFF]) { data, _ in
                    let count = Int(u32(data, 0))
                    line("icc: GetObjectHandles at the top: \(count)")
                    guard count > 0 else { return }
                    self.findFile(camera, handles: (0 ..< count).map { u32(data, 4 + 4 * $0) })
                }
            }
        }
    }

    func findFile(_ camera: ICCameraDevice, handles: [UInt32]) {
        guard let handle = handles.first else { return }
        send(camera, 0x1008, [handle]) { info, _ in
            var o = 52
            let name = string(info, &o)
            let format = u16(info, 4), size = u32(info, 8)
            line("icc: GetObjectInfo \(handle): \(name) format 0x\(String(format, radix: 16)) size \(size)")
            if format == 0x3001 || size == 0 {
                self.findFile(camera, handles: Array(handles.dropFirst()))
                return
            }
            let started = Date()
            let chunk: UInt32 = 4 << 20
            self.send(camera, 0x95C1, [handle, 0, 0, chunk]) { data, response in
                let seconds = Date().timeIntervalSince(started)
                line(String(format: "icc: GetPartialObject64: %d bytes in %.2f s (%.1f MB/s), response 0x%04x",
                            data.count, seconds, Double(data.count) / seconds / 1_000_000, u16(response, 6)))
            }
        }
    }

    func send(_ camera: ICCameraDevice, _ code: UInt16, _ params: [UInt32] = [], then: @escaping (Data, Data) -> Void) {
        transaction += 1
        camera.requestSendPTPCommand(command(code, transaction, params), outData: nil) { data, response, error in
            if let error {
                line("icc: 0x\(String(code, radix: 16)) failed: \(error)")
                return
            }
            let result = u16(response, 6)
            guard result == 0x2001 else {
                line("icc: 0x\(String(code, radix: 16)) answered 0x\(String(result, radix: 16)) (\(response.count) response bytes)")
                return
            }
            // The data phase may arrive with or without its 12-byte container header.
            let body = data.count >= 12 && u16(data, 4) == 2 ? data.dropFirst(12) : data
            then(Data(body), response)
        }
    }
}

// MARK: USB directly

func probeUSB() {
    for interfaceClass in [6, 0xFF] {
        let matching = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: nil, productID: nil, bcdDevice: nil, interfaceNumber: nil, configurationValue: nil,
            interfaceClass: NSNumber(value: interfaceClass), interfaceSubclass: nil, interfaceProtocol: nil, speed: nil, productIDArray: nil
        ).takeRetainedValue()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { continue }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let name = IORegistryEntryCreateCFProperty(service, "USB Interface Name" as CFString, nil, 0)?.takeRetainedValue() as? String
            if interfaceClass == 0xFF, name?.contains("MTP") != true { continue }
            line("usb: interface class \(interfaceClass) \"\(name ?? "")\"")
            for (label, options) in [("open", IOUSBHostObjectInitOptions()), ("seize", .deviceSeize)] {
                do {
                    let interface = try IOUSBHostInterface(__ioService: service, options: options, queue: nil, interestHandler: nil)
                    line("usb: \(label): ok")
                    deviceInfo(interface)
                    interface.destroy()
                    break
                } catch {
                    line("usb: \(label): \(error)")
                }
            }
        }
        IOObjectRelease(iterator)
    }
    line("usb: done")
}

/// GetDeviceInfo needs no session: one command out, data and response in.
func deviceInfo(_ interface: IOUSBHostInterface) {
    var bulkIn: IOUSBHostPipe?, bulkOut: IOUSBHostPipe?
    for address in Array(0x81 ... 0x8F) + Array(0x01 ... 0x0F) {
        guard let pipe = try? interface.copyPipe(withAddress: address) else { continue }
        guard pipe.descriptors.pointee.descriptor.bmAttributes & 3 == 2 else { continue }
        if address & 0x80 != 0 { bulkIn = bulkIn ?? pipe } else { bulkOut = bulkOut ?? pipe }
    }
    guard let bulkIn, let bulkOut else {
        line("usb: no bulk pipes")
        return
    }
    do {
        let out = NSMutableData(data: command(0x1001, 0))
        var sent = 0, read = 0
        try bulkOut.__sendIORequest(with: out, bytesTransferred: &sent, completionTimeout: 5)
        let buffer = NSMutableData(length: 64 * 1024)!
        try bulkIn.__sendIORequest(with: buffer, bytesTransferred: &read, completionTimeout: 5)
        let data = Data(bytes: buffer.bytes, count: read)
        line("usb: GetDeviceInfo: \(describeDeviceInfo(data.dropFirst(12)))")
    } catch {
        line("usb: GetDeviceInfo failed: \(error)")
    }
}

// MARK: Main

switch CommandLine.arguments.dropFirst().first {
case "icc":
    let probe = Probe()
    probe.start()
    RunLoop.main.run()
case "usb":
    probeUSB()
default:
    line("usage: swift docs/spikes/device-probe.swift icc|usb")
}
