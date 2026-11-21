# Spike S6: fonts for Edit/Frame (R-4607, D-129)

Question: how many fonts can text layers offer without bundling any, can the list be read offline, and what does
fetching one of Apple's downloadable fonts involve?

Method (2026-11-21, macOS 26 on this Mac): `CTFontManagerCopyAvailableFontFamilyNames` for installed families;
`CTFontDescriptorCreateMatchingFontDescriptors` with `kCTFontDownloadableAttribute` for Apple's downloadable fonts.

| Question | Answer |
|---|---|
| Installed families | 190 (Helvetica Neue with 14 faces, Avenir Next, Futura, Didot, Bodoni 72, Baskerville, Snell Roundhand, Zapfino, Bradley Hand, Noteworthy among them) |
| Downloadable families not yet installed | 230 (1,170 faces), among them many Latin display and script families as well as other scripts |
| Is the list read offline? | Yes: 0.15 s, no network; macOS keeps the catalogue of downloadable fonts locally |
| How is one fetched? | `CTFontDescriptorMatchFontDescriptorsWithProgressHandler`; macOS downloads it from Apple and installs it for every app |

Decision: about 420 families with nothing bundled. Downloadable families are listed with a download symbol; fetching
one happens only after the person allows font downloads once (Settings can turn it off). The call lives in
`MediaPullEdit/FontCatalog.swift` only (`check.sh` enforces it).
