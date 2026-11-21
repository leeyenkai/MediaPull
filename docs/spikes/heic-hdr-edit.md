# Spike S2: keeping HDR in an edited copy (R-4203, section 46)

Question: when a photo with an HDR gain map (iPhone HEIC, recent cameras' HEIF) is edited — cropped, adjusted, framed —
can the exported copy keep its HDR, by rendering through Core Image in extended range and writing an ISO gain map
(`CIImageRepresentationOption.hdrImage`, `kCGImageDestinationEncodeToISOGainmap`, macOS 15 and later)? And do the
maker notes and the Live Photo content identifier survive that route?

Status: method below; to be run with the person's HDR HEIC (an iPhone photo of a bright sky or lamps).

## Method
1. Decode with `kCGImageSourceDecodeToHDR` (or `CIImage(contentsOf:options: [.expandToHDR: true])`); check the headroom.
2. Crop and adjust through the Edit/Frame renderer; render to an extended-range RGBA half-float image.
3. Write HEIC with the ISO gain-map option; read back: the gain map present (`kCGImageAuxiliaryDataTypeISOGainMap`),
   the headroom within 10 % of the original, the picture shown in HDR by the Preview pane.
4. Compare the maker notes and `ContentIdentifier` before and after.

## What each result decides
- HDR kept: Edit/Frame exports HDR photos as HDR HEIC (JPEG with an ISO gain map where supported).
- Not kept: exports are SDR, tone-mapped, and the Export panel says "HDR is not kept in an edited copy" (as the quick
  editor does today).
