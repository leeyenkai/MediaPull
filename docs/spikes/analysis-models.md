# Analysis models: benchmark and choice

Measured on 15 November 2026 on this Mac (Apple M2 Pro, 10 cores, 16 GB, macOS 27.0.1) for SPEC sections 36 to 39 and decision D-67.

There were two rounds:
- **Round 1** compared smaller models, licences included.
- **Round 2** followed the request to use the most accurate current models, with licences set aside for this private tool.

The app ships the round-2 choices.

## Round 2: the models MediaPull uses

| Job | Model | Size in the app | Result on this Mac |
|---|---|---|---|
| Free-text search, subjects, similar sets | **MobileCLIP2-S3** (timm/MobileCLIP2-S3-OpenCLIP, revision `2a5959ca`), image and text towers in fp16 | 475 MB | See below |
| Face recognition | **AdaFace IR-101**, trained on WebFace12M (CVLFace, revision `54f602a0`) | 125 MB | See below |
| Faces and landmarks | **SCRFD-10G with landmarks** (InsightFace `det_10g.onnx`, converted through onnx2torch) | 8 MB | Aligns faces to the template the recognition model was trained on |
| Labels, text | Apple Vision (built in) | 0 | Unchanged from round 1 |
| Places | GeoNames cities of 1,000 people or more | 9 MB | 171,939 places |

The research covered MobileCLIP2 S3, S4 and L-14, PE-Core, SigLIP 2, DFN, EVA-CLIP, MetaCLIP 2 and TULIP for search. For faces it covered AdaFace, CVLFace ViT KP-RPE, LVFace, TopoFR, TransFace, ArcFace R100 and buffalo_l, and for detection SCRFD, RetinaFace and YuNet.

Larger image–text models, and every SigLIP 2 model, exceed the 800 MB budget once the face models are added: SigLIP 2's 256k-token vocabulary alone is 393 MB.

**MobileCLIP2-S3 against round 1's best (MobileCLIP-S2).** Same 3,000 COCO photos, same Swift pipeline:

| Measure | S2 | S3 |
|---|---|---|
| A caption's photo in the top 1 | 48.7 % | **54.9 %** |
| In the top 5 | 74.3 % | **79.0 %** |
| In the top 10 | 83.4 % | **86.9 %** |
| Top tag right | 90.5 % | **92.7 %** |
| Subject sort at ≥ 50 % confidence | 94.8 % filed, 92.7 % right | 95.4 % filed, **94.8 %** right |
| Time per image, Neural Engine | 23 ms | 28 ms |

The converted text tower matches PyTorch exactly (cosine 0.99999 in fp16).

**AdaFace IR-101 with SCRFD alignment against round 1's EdgeFace-S with Apple's landmarks.** LFW, 6,000 pairs, 10-fold:

| Measure | EdgeFace-S, Vision landmarks | AdaFace IR-101, SCRFD |
|---|---|---|
| Accuracy | 96.95 % | **99.80 %** (published: 99.82 %) |
| True matches at 0.1 % false matches | 93.6 % | **99.7 %** |
| One photo at a quarter size | 96.88 % | **99.75 %** |
| One photo re-saved as JPEG at quality 5 | 97.33 % | **99.83 %** |
| Grouping 4,318 photos of 158 people | 98.6 % pure at 0.4 | **99.9 % pure, 99.9 % together at 0.34** (159 groups) |
| Detection + embedding per face | 13 + 1.3 ms | 27 + 7 ms |

Other variants tested:
- **BGR input:** 99.82 %.
- **Mirrored-crop fusion:** 99.82 % at twice the cost.
- **Choice:** both are within noise, so the app uses RGB without fusion.
- **Match threshold:** 0.34, the strictest value that still kept 99.9 % of each person's photos together.

**Whole pipeline, production code** (`Analyzer`, 1,000 COCO photos, two at a time):
- **Throughput:** 26.5 photos a second.
- **Memory:** 180 MB peak.
- **Work done:** 308 faces embedded, all photos labelled, 208 with text.

Two problems were found and fixed along the way:
- **Background priority** was throttled about tenfold (2.2 photos a second), so analysis runs at utility priority.
- **Accurate text recognition** stalls Vision for up to a minute on macOS 27.0 before failing (a known system problem), so it is skipped on that version and probed in the background elsewhere.

**In the app** (`--selftest-analyse`, 96 files including hashing and storage):
- **Speed:** 16.7 files a second.
- **Network:** no sockets opened.
- **People:** the three people in the test set found with 12 photos each, and two named from their folders.

**Size:**

| Part | Size |
|---|---|
| Staged models and data | 618 MB |
| App with models | 696 MB |
| Budget | 800 MB |

**Accuracy limits that still apply:**
- **Children:** not measurable with LFW.
- **Strongly turned faces:** remain the hardest case.
- **Real libraries:** these are harder than LFW (lighting, partial faces, look-alike relatives). The threshold can be loosened or tightened in Settings > Faces, and corrections are kept.

---

## Round 1 (superseded)

## Set-up

| | |
|---|---|
| Photos | 3,000 COCO val2017 photos (the first 3,000 by id), 640 px, each with 5 written captions and object labels from 80 categories |
| Faces | LFW: 13,233 face photos of 5,749 people, 250 px; the standard 6,000 test pairs (3,000 same person, 3,000 different) in 10 folds |
| Harness | A throwaway Swift command-line tool (Vision, Core ML, Accelerate; no third-party code), photos decoded with ImageIO at ≤512 px as the app would |
| Conversion | `scripts/convert-models.sh` (pinned torch 2.7.0, coremltools 9.0); models in fp16 ML Program format |
| Data | Downloads and checksums in `~/Library/Caches/MediaPullBuild/bench/`, never in the repository |

## Results

### Apple's built-in Vision requests (no bundling needed)

| Request | Median per photo | Result |
|---|---|---|
| Image classifier | 10.8 ms | 1,303 labels. Against COCO, on the 54 categories with the same name: 97.6 % precision and 27.4 % recall at confidence ≥ 0.5 (94.1 % / 37.3 % at ≥ 0.3). About 7 labels per photo at ≥ 0.5 |
| Text recognition, fast | 8.8 ms (photos), 32 ms (text pages) | 75.7 % of words found in rendered text from 11 to 36 pt |
| Text recognition, accurate | fails | Every call fails on this macOS build with an internal runtime error, on the CPU, GPU and Neural Engine alike, and in both the old and the new Vision API. The app will try accurate first and fall back to fast. |
| Face rectangles | 7.7 ms | A face was found in 662 of 946 photos where a person covers more than 5 % of the frame (people facing away count as misses) |
| Feature print | 6.0 ms | 768 values |
| Aesthetics `isUtility` | 7.5 ms | **Not usable as a screenshot signal.** It flagged 385 of 3,000 ordinary photos (12.8 %) and only 5 of 60 text images |

### Image–text models (free-text search, tags, similar sets)

| | MobileCLIP-S2 (Apple) | OpenCLIP ViT-B/16 DataComp.XL |
|---|---|---|
| Size in the app | **189 MB** | 286 MB |
| Image, Neural Engine | **22.9 ms** | 34.4 ms |
| Image, GPU | 44.1 ms | 55.0 ms |
| Text query | 2.2 ms | 2.7 ms |
| Caption → photo search, 3,000 photos: recall at 1 / 5 / 10 | **48.7 / 74.3 / 83.4 %** | 42.8 / 70.1 / 78.9 % |
| Zero-shot tag: the top tag is right | **90.5 %** | 89.7 % |
| Subject sort at confidence ≥ 0.5 | 94.8 % filed, 92.7 % of them right | 90.9 % filed, 93.9 % right |
| Subject sort at confidence ≥ 0.7 | 84.9 % filed, 95.4 % right | 78.8 % filed, 96.4 % right |
| Memory while embedding | +20 MB, peak 154 MB | +18 MB, peak 201 MB |
| Weights licence | Apple's 2024 MobileCLIP weights licence (see below) | MIT |

Both run best on the Neural Engine: the GPU is slower and uses more memory, which also leaves the GPU free for the window.

**Conversion checks:**
- The Swift CLIP tokenizer (no packages) produces exactly the reference tokens (6 of 6 test strings, including accents and truncation). It takes 0.017 ms per caption.
- The converted OpenCLIP text model matches PyTorch exactly (cosine 1.000).
- The image model gives cosine 0.99 or better on identical pixels. Different resampling, such as Lanczos against the bicubic used in training, moves single embeddings to between 0.88 and 0.97. The search and tag results above already include this, because they ran through the app's own decoding.

**Search examples (MobileCLIP-S2, top 5 of 3,000):**
- "a cat sleeping": five sleeping or lying cats.
- "people playing tennis": five tennis scenes.
- "a red car": weaker. It returns a red fire hydrant and a burgundy hot rod among unrelated vehicles.

### Face recognition (identity)

Faces are found and their landmarks read with Apple's Vision, aligned to the standard 112 px five-point template, then embedded.

| | EdgeFace-S (γ 0.5) | SFace |
|---|---|---|
| Size in the app | **7.2 MB** | 18.4 MB |
| Embedding per face | **1.3 ms** | 2.2 ms |
| LFW verification (10-fold) | **96.95 %** | 94.63 % |
| True matches at 0.1 % false matches | **93.6 %** | 88.0 % |
| Same person, facing the camera (< 15°) | 96.5 % found | 92.8 % |
| Same person, turned more than 30° | 88.2 % found | 82.7 % |
| One photo at a quarter size (face about 28 px) | 96.9 % (no loss) | 95.0 % |
| One photo re-saved as JPEG at quality 5 | 97.3 % (no loss) | 95.3 % |
| Grouping 4,324 photos of 158 people at similarity ≥ 0.4 | 244 groups, 98.6 % pure, 92.8 % of same-person pairs together | 248 groups, 94.9 % pure, 87.6 % |
| Grouping at similarity ≥ 0.5 | 270 groups, 99.3 % pure, 92.3 % together | 305 groups, 98.0 % pure |
| Licence (weights) | CC BY-NC-SA 4.0 (code BSD-3) | Apache 2.0 |

**Accuracy limits, measured:**
- **Side profiles** are the main weakness: faces turned more than 30° are matched 8 points less often.
- **Small faces** held up surprisingly well: down to about 28 px there was no loss. So the planned 64 px minimum can come down to 32 px.
- **Heavy JPEG compression** made no difference.
- **Children** could not be measured: LFW has almost none. NIST's face-recognition study (NIST IR 8280) reports more false matches for children and the elderly.
- **Below the published figures** (99.78 % for EdgeFace-S), because Apple's landmarks are not the detector these models were trained with. The worst pairs showed occasional bad landmarks and background faces. A landmark sanity check with a fallback to the face box already raised accuracy from 93.3 % to 97.0 %.
- A dedicated five-point face detector (for example OpenCV's YuNet, MIT, under 1 MB) would probably close most of the remaining gap. It would be one more model to convert and test.

Grouping works as intended: at ≥ 0.4 almost every group is one person (98.6 %). The cost is that about 7 % of a person's photos land in extra small groups, which the merge command fixes. Wrong-person merges are much rarer than splits, which is the safer way to fail.

### Search speed (Accelerate, brute force, one query)

| Library | Float32 vectors | Float16 vectors (half the memory) |
|---|---|---|
| 5,000 photos | 0.24 ms, 10 MB | 0.52 ms, 5 MB |
| 50,000 photos | 2.9 ms, 98 MB | 4.1 ms, 49 MB |
| 200,000 photos | 12.5 ms, 391 MB | 17.3 ms, 195 MB |

Brute force is fast enough, with no index needed. Float16 storage, converted in chunks, halves memory for about 40 % more time.

### Everything together

Per photo: decode at ≤ 512 px, classifier, aesthetics, feature print, fast text recognition, faces with landmarks, face embeddings, MobileCLIP image embedding. 1,000 COCO photos:

| | Photos per second | Peak memory |
|---|---|---|
| One at a time | 17.9 | 168 MB |
| Two at a time | 35.2 | 175 MB |

The cost per photo, summed over both workers:

| Step | Time per photo |
|---|---|
| Vision requests | 25 ms |
| Image embedding | 16 ms |
| Faces | 10 ms |
| Decoding | 5 ms |
| Face embeddings | under 1 ms |

Camera photos (12 MP and up) take longer to decode than these 640 px photos. Expect roughly 15 to 25 photos per second, so a 10,000-photo library takes about 7 to 11 minutes for the first pass.

## Recommendation

| Job | Choice | Size | Why |
|---|---|---|---|
| Content labels | Apple's image classifier | 0 | 97.6 % precise at ≥ 0.5, built in, 1,303 labels for the tag filter |
| Recognised text | Apple's text recognition (accurate, falling back to fast) | 0 | Built in; accurate mode is broken on this macOS build |
| Free-text search, subject sort, similar sets | **MobileCLIP-S2**, Core ML package from `apple/coreml-mobileclip` at revision `3e0a7bfb`, under its 2024 licence | 189 MB | Best on every measure: +4 points search recall, a third faster and 97 MB smaller than OpenCLIP |
| Faces | **EdgeFace-S** | 7.2 MB | 97.0 % against SFace's 94.6 %, purer groups, faster, smaller |
| Place names | GeoNames cities of 1,000 people or more, regions and countries, compiled to a compact index | about 6 MB (estimate) | CC BY 4.0, offline |
| Screenshots | Deterministic signs only | 0 | The `isUtility` score failed the test; to be dropped from R-3604 with D-67 |

**Projected app size:** about 280 MB with these choices (74 MB today, plus 189, 7, about 6 and 1.4 MB for the tokenizer vocabulary), well inside 800 MB. With OpenCLIP instead it would be about 375 MB.

### The licence question to decide

- **MobileCLIP-S2.** The pinned Core ML revision (November 2024) points to Apple's 2024 "ML-MobileCLIP Model Weights and Data" licence. It grants "a personal, non-exclusive license … to use, reproduce, modify and redistribute" the weights, provided the notice is kept. A copy is saved with the model.
  - In 2025 Apple moved its MobileCLIP model repositories to a research-only licence. That change did not touch this Core ML revision, but its licence link now points at a deleted file.
  - Under the 2024 text, a personal, non-commercial tool is clearly covered. Whether Apple means the newer licence to apply to older copies is not stated.
  - If you want no ambiguity at all, OpenCLIP ViT-B/16 (MIT) is the alternative. It costs 4 points of search recall, about 11 ms per photo and 97 MB.
- **EdgeFace-S.** CC BY-NC-SA 4.0 allows non-commercial use with attribution. Converting the model is an adaptation, so it must keep the same licence if it is ever shared; it is not, since this is a personal tool. SFace (Apache 2.0) is the fallback.
- **GeoNames.** CC BY 4.0 needs a credit in About.

## Proposed budgets (section 22)

| Area | Budget | Measured |
|---|---|---|
| App bundle | ≤ 800 MB | about 280 MB projected |
| Analysis, first pass | ≥ 15 photos per second, two at a time | 35 per second on 640 px photos |
| Analysis memory | ≤ 250 MB above idle | 175 MB peak |
| Search, 50,000 photos | ≤ 20 ms including the text query | 2.2 ms text + 4.1 ms scan |
| Analysis when idle | no CPU | to be measured in the app |

## Model checksums (SHA-256 of each package's sorted file hashes)

| File | SHA-256 |
|---|---|
| `mobileclip_s2_image.mlpackage` | `43338f48fadfef0455ab242d1ec9eb964290b7375c6d9b642ef4cb83d3c7e2b7` |
| `mobileclip_s2_text.mlpackage` | `17537eafeac6c2abf966c67cb5c021575656193c711cc5e87b372ecfb1d6afec` |
| `edgeface_s.mlpackage` (converted) | `79ad7cff729f9be438bdf3790aa24f410d6b4216f1185ee1a89bfee772b51b51` |
| `edgeface_s_gamma_05.pt` (source, repository commit `ba955538`) | `dc59abda2e8580399fd115a1eeb07e1f21156196db604b884407bcf0f17efb07` |
| `openclip_b16_image.mlpackage` (converted, alternative) | `05aa8e9ff54eacfac6c412761279b37df2f1d5980885275e86603cca09d9a5c1` |
| `openclip_b16_text.mlpackage` (converted, alternative) | `76b08dd729cb3ad4f490da54a7e83c3b059aeaa473d4f9823e594565bdc728c8` |
| `sface.mlpackage` (converted, fallback) | `822532c296c96f21850f9467be20bfff6703dd4e36ef5cff5cab6467d9ceb33f` |
| `face_recognition_sface_2021dec.onnx` (source) | `0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79` |
| CLIP `vocab.json` / `merges.txt` | `5047b556…4d4363` / `f5263931…eba85` |

The converted packages are checksummed as converted here. A reconversion may not be byte-identical, so `scripts/models.lock` will pin the packages that are actually bundled.
