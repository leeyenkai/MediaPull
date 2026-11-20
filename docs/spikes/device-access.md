# Spike: reaching a phone over USB (D-116, SPEC section 41)

Question: how can MediaPull read photos and videos from an iPhone and from an Android phone in its default "File
transfer" (MTP) mode, read-only, with no third-party code?

## What is known without a phone

- macOS has no MTP support, still true on macOS 26. Android phones offer MTP ("File transfer") or PTP ("Transferring
  photos" / "PTP"); after each plug-in they start in "No data transfer" until the person picks a mode in the
  notification.
- Apple's ImageCaptureCore reads iPhones (camera roll, HEIC/HEVC originals with `mediaPresentation = .originalAssets`,
  Live Photo pairs through `groupUUID`/`relatedUUID`, a per-file `fingerprint`) and Android phones in PTP mode.
- MTP is PTP with more operations on the same USB still-image interface (class 6, subclass 1, protocol 1; some older
  Samsung phones use a vendor-specific interface named "MTP"). The system camera daemon opens these devices whenever any
  ImageCaptureCore client is browsing and holds them exclusively.
- `IOUSBHostObjectInitOptionsDeviceCapture` needs root or the `com.apple.vm.device-access` entitlement (SDK header), so
  it is not an option for MediaPull. `DeviceSeize` only *asks* the current owner to close.
- `ICDeviceBrowser.requestContentsAuthorization` is iOS only; macOS has no contents prompt for this framework.
- ImageCaptureCore's pass-through, `ICCameraDevice.requestSendPTPCommand(_:outData:completion:)`, sends any PTP-format
  operation inside the framework's own session. MTP operations use the same container format, so an MTP client can sit
  on top of it with no contention, if the framework hands an MTP-mode phone to apps at all.

## The probe

`docs/spikes/device-probe.swift` (not part of the app) sends only read operations.

```
swift docs/spikes/device-probe.swift usb
swift docs/spikes/device-probe.swift icc
```

`usb` opens each still-image interface directly (then with seize) and asks for DeviceInfo. `icc` browses with
ImageCaptureCore, opens a session, lists the first files, then runs DeviceInfo, StorageIDs, ObjectHandles, ObjectInfo
and a 4 MB GetPartialObject64 through pass-through and prints the speed. Run `usb` first, with Photos, Image Capture
and Preview closed.

## Results (to fill in with real phones)

| Phone, mode | `usb` open | `usb` seize | `icc` listed | `icc` media files | pass-through DeviceInfo | GetPartialObject64 MB/s |
|---|---|---|---|---|---|---|
| iPhone | | | | | | |
| Pixel, File transfer | | | | | | |
| Pixel, PTP | | | | | | |
| Samsung, File transfer | | | | | | |
| No phone (this Mac, 2026-11-20) | nothing listed | — | nothing listed | — | — | — |

## Decision rule

1. If `icc` lists MTP-mode Android phones and pass-through answers: the MTP client uses `MTPPassThroughTransport`
   (no contention, no root). This is the expected route.
2. Else, if `usb open` or `usb seize` works while nothing else is browsing: `MTPUSBTransport`, and MediaPull stops its
   own ImageCaptureCore browsing for phones routed to MTP.
3. Else: Android phones are read in PTP mode only, with the hint "On the phone, choose Transferring photos (PTP) in
   the USB notification", and D-116 says so.

The MTP codec, session and import work the same over either transport, so they are built and tested before this is
settled; only the transport file waits for the result.
