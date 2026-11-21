#!/bin/bash
# Builds a minimal LGPL ffmpeg and ffprobe for Apple silicon: no network protocols, only the
# demuxers, muxers, codecs and filters MediaPull needs, hardware encoders through VideoToolbox, and the LGPL LAME
# MP3 encoder built from source (D-131).
set -euo pipefail

CACHE="${MEDIAPULL_ENGINE_CACHE:-$HOME/Library/Caches/MediaPullBuild}"
DL="$CACHE/downloads"
OUT="$CACHE/engines/ffmpeg"
WORK="$CACHE/ffmpeg-build"
VERSION="9.0.2"
SHA="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
LAME_VERSION="3.100"
LAME_SHA="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
mkdir -p "$DL"
source "$(dirname "$0")/cache-stamp.sh"
mkdir -p "$OUT" && cache_unmark ffmpeg

TARBALL="$DL/ffmpeg-$VERSION.tar.xz"
if [[ ! -f "$TARBALL" || "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" != "$SHA" ]]; then
  curl -sSLf --retry 3 -o "$TARBALL" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
fi
[[ "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" == "$SHA" ]] || { echo "error: ffmpeg SHA-256 mismatch" >&2; exit 1; }

LAME_TARBALL="$DL/lame-$LAME_VERSION.tar.gz"
if [[ ! -f "$LAME_TARBALL" || "$(shasum -a 256 "$LAME_TARBALL" | awk '{print $1}')" != "$LAME_SHA" ]]; then
  curl -sSLf --retry 3 -o "$LAME_TARBALL" "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
fi
[[ "$(shasum -a 256 "$LAME_TARBALL" | awk '{print $1}')" == "$LAME_SHA" ]] || { echo "error: LAME SHA-256 mismatch" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK"
tar -xJf "$TARBALL" -C "$WORK"
tar -xzf "$LAME_TARBALL" -C "$WORK"

# LAME: the encoder library only, static. Its export list names a function 3.100 no longer has.
cd "$WORK/lame-$LAME_VERSION"
sed -i '' '/lame_init_old/d' include/libmp3lame.sym
CFLAGS="-mmacosx-version-min=26.0 -O2" LDFLAGS="-mmacosx-version-min=26.0" ./configure \
  --prefix="$WORK/install" --host=aarch64-apple-darwin --disable-shared --enable-static --disable-frontend \
  --disable-decoder --disable-dependency-tracking >/dev/null
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null
cp COPYING "$WORK/LICENSE-lame.txt"

cd "$WORK/ffmpeg-$VERSION"

./configure \
  --prefix="$WORK/install" \
  --arch=arm64 --target-os=darwin --cc=clang \
  --extra-cflags="-mmacosx-version-min=26.0 -O2 -I$WORK/install/include" \
  --extra-ldflags="-mmacosx-version-min=26.0 -L$WORK/install/lib" \
  --disable-shared --enable-static --disable-doc --disable-debug --disable-ffplay \
  --disable-network --disable-autodetect \
  --enable-zlib --enable-videotoolbox --enable-audiotoolbox --enable-libmp3lame \
  --disable-everything \
  --enable-protocol=file,pipe \
  --enable-demuxer=mov,matroska,mpegts,aac,mp3,ogg,flac,wav,aiff,image2,image2pipe,gif,apng,png_pipe,jpeg_pipe,webp_pipe,concat,rawvideo,ivf,h264,hevc,m4v \
  --enable-muxer=mp4,mov,ipod,matroska,webm,gif,apng,image2,image2pipe,adts,null,rawvideo,mp3,flac,ogg,opus,wav,aiff,streamhash,framemd5,pcm_f32le \
  --enable-decoder=h264,hevc,vp8,vp9,av1,mpeg4,aac,aac_latm,mp3,mp3float,opus,vorbis,flac,alac,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_u8,pcm_s8,pcm_mulaw,pcm_alaw,adpcm_ima_wav,adpcm_ima_qt,adpcm_ms,pcm_f64be,mjpeg,png,apng,gif,webp,bmp,rawvideo \
  --enable-encoder=h264_videotoolbox,hevc_videotoolbox,aac_at,aac,gif,apng,png,rawvideo,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,mjpeg,libmp3lame,flac,alac \
  --enable-parser=h264,hevc,vp8,vp9,av1,aac,aac_latm,mpegaudio,opus,vorbis,flac,png,gif,webp,mjpeg \
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,vp9_superframe,vp9_superframe_split,extract_extradata \
  --enable-filter=palettegen,paletteuse,scale,fps,format,null,anull,aresample,aformat,split,setpts,copy,pad,crop,atrim,afade,volume,loudnorm,concat,asetpts,asetnsamples,ebur128,amix \
  --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,vp9_videotoolbox,av1_videotoolbox

make -j"$(sysctl -n hw.ncpu)"
make install

mkdir -p "$OUT"
cp "$WORK/install/bin/ffmpeg" "$WORK/install/bin/ffprobe" "$OUT/"
strip "$OUT/ffmpeg" "$OUT/ffprobe"
codesign --force --sign - "$OUT/ffmpeg" "$OUT/ffprobe"
cp COPYING.LGPLv2.1 "$OUT/LICENSE-ffmpeg.txt"
cp "$WORK/LICENSE-lame.txt" "$OUT/LICENSE-lame.txt"
echo "$VERSION" > "$OUT/VERSION"
echo "$LAME_VERSION" > "$OUT/LAME_VERSION"
cache_mark ffmpeg
cd /
rm -rf "$WORK"
ls -la "$OUT"
"$OUT/ffmpeg" -hide_banner -version | head -1
