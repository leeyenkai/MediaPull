#!/bin/bash
# Builds a minimal LGPL ffmpeg and ffprobe for Apple silicon: no network protocols, only the
# demuxers, muxers, codecs and filters MediaPull needs, hardware encoders through VideoToolbox.
set -euo pipefail

CACHE="${MEDIAPULL_ENGINE_CACHE:-$HOME/Library/Caches/MediaPullBuild}"
DL="$CACHE/downloads"
OUT="$CACHE/engines/ffmpeg"
WORK="$CACHE/ffmpeg-build"
VERSION="9.0.2"
SHA="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
mkdir -p "$DL"

TARBALL="$DL/ffmpeg-$VERSION.tar.xz"
if [[ ! -f "$TARBALL" || "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" != "$SHA" ]]; then
  curl -sSLf --retry 3 -o "$TARBALL" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
fi
[[ "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" == "$SHA" ]] || { echo "error: ffmpeg SHA-256 mismatch" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK"
tar -xJf "$TARBALL" -C "$WORK"
cd "$WORK/ffmpeg-$VERSION"

./configure \
  --prefix="$WORK/install" \
  --arch=arm64 --target-os=darwin --cc=clang \
  --extra-cflags="-mmacosx-version-min=26.0 -O2" --extra-ldflags="-mmacosx-version-min=26.0" \
  --disable-shared --enable-static --disable-doc --disable-debug --disable-ffplay \
  --disable-network --disable-autodetect \
  --enable-zlib --enable-videotoolbox --enable-audiotoolbox \
  --disable-everything \
  --enable-protocol=file,pipe \
  --enable-demuxer=mov,matroska,mpegts,aac,mp3,ogg,flac,wav,image2,image2pipe,gif,apng,png_pipe,jpeg_pipe,webp_pipe,concat,rawvideo,ivf,h264,hevc,m4v \
  --enable-muxer=mp4,mov,ipod,matroska,webm,gif,apng,image2,image2pipe,adts,null,rawvideo \
  --enable-decoder=h264,hevc,vp8,vp9,av1,mpeg4,aac,aac_latm,mp3,mp3float,opus,vorbis,flac,alac,pcm_s16le,pcm_f32le,mjpeg,png,apng,gif,webp,rawvideo \
  --enable-encoder=h264_videotoolbox,hevc_videotoolbox,aac_at,aac,gif,apng,png,rawvideo,pcm_s16le,mjpeg \
  --enable-parser=h264,hevc,vp8,vp9,av1,aac,aac_latm,mpegaudio,opus,vorbis,flac,png,gif,webp,mjpeg \
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,vp9_superframe,vp9_superframe_split,extract_extradata \
  --enable-filter=palettegen,paletteuse,scale,fps,format,null,anull,aresample,aformat,split,setpts,copy,pad,crop \
  --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,vp9_videotoolbox,av1_videotoolbox

make -j"$(sysctl -n hw.ncpu)"
make install

mkdir -p "$OUT"
cp "$WORK/install/bin/ffmpeg" "$WORK/install/bin/ffprobe" "$OUT/"
strip "$OUT/ffmpeg" "$OUT/ffprobe"
codesign --force --sign - "$OUT/ffmpeg" "$OUT/ffprobe"
cp COPYING.LGPLv2.1 "$OUT/LICENSE-ffmpeg.txt"
echo "$VERSION" > "$OUT/VERSION"
cd /
rm -rf "$WORK"
ls -la "$OUT"
"$OUT/ffmpeg" -hide_banner -version | head -1
