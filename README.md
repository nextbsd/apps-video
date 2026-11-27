# Video

Play and record video on NextBSD, as QuickTime Player on a Mac: open a clip
or a screen recording from File Viewer and play it, or make a new screen,
camera or sound recording with sound.

- **Playing:** a plain window that is the video, with floating controls that
  fade when the pointer rests: volume, skip back and forward (10 seconds),
  play and pause, the speed (½× to 2×, keeping the pitch roughly), full
  screen, and a scrubber with the time played and the length. Keys: Space
  plays and pauses, ← and → skip 5 seconds, ↑ and ↓ change the volume, ⌘F
  goes full screen (Escape comes back). File › Get Info (⌘I) shows the size,
  the length, the dimensions and the codecs.
- **Formats:** what NextBSD's ffmpeg decodes: H.264, HEVC, VP8, VP9,
  MPEG-1/2/4, Theora and MJPEG video; AAC, MP3, Opus, Vorbis, FLAC, ALAC, AC-3
  and PCM sound; in .mov, .mp4, .m4v, .mkv, .webm, .avi, .mpg, .ts, .ogv and
  the sound-only files (.mp3, .m4a, .flac, .ogg, .opus, .wav ...). File
  Viewer opens them in Video (`NSTypes` in `VideoInfo.plist`).
- **Recording:** File › New Screen, Camera or Sound Recording opens the
  recording window: the source (Screen, Selection, Camera or Sound only), the
  microphone with its level live, the red record button, and the time and size
  counting up. Camera and sound recordings are saved to `~/Videos` as .mov
  (MPEG-4 video and AAC sound, the encoders NextBSD's ffmpeg has) and open to
  play when they stop.
- **Screen recordings** are made by Screenshot (nextbsd/nextbsd#715), which
  owns screen capture: Video hands over to it, and the movie Screenshot saves
  opens in Video. Video starts `Screenshot.app` with `-Record screen` or
  `-Record selection`, Screenshot's own interface (its `SSRequest.h` and
  README), which opens its toolbar ready to record; `VDScreenRecording.m` is
  the only place that knows.

Light and Dark follow `NBAppearance`, as every NextBSD app; the video and its
controls are dark in both.

## How it works

| File | What it does |
|---|---|
| `VDMedia.c` | Plays a file: a thread reads and decodes with libavformat and libavcodec, scaling pictures with libswscale to the size shown and sound with libswresample; another plays the sound through OSS. The clock follows the sound device; late pictures are dropped. With no sound device a file plays silently, in time. |
| `VDAudio.c` | OSS: `/dev/dsp` for playing, the inputs in `/dev/sndstat` for recording, and the level meter. |
| `VDRecorder.c` | Writes recordings: the mov muxer, the MPEG-4 and AAC encoders. |
| `WCCapture*.c`, `WCImage.c` | Cameras (V4L2), a copy of apps-settings' Webcam's; keep them in step. |
| `VDPlayer.m`, `VDRecording.m`, `VDController.m` | The windows, the controls and the menus. |

GNUstep's libs-av (AVFoundation on ffmpeg) reads metadata but its `AVPlayer`
doesn't play yet, so Video uses the ffmpeg libraries itself.

## Building

```
. /System/Library/Makefiles/GNUstep.sh
gmake
gmake install        # /System/Applications/Video.app
```

It needs the ffmpeg libraries and headers from NextBSD-gnustep-support (in the
GNUstep SDK too), with the MPEG-4 and AAC encoders and the mov muxer
(nextbsd-gnustep-support#13) for recording.

## Defaults

| Key | What it does |
|---|---|
| `VideoRecordingsFolder` | Where recordings go (`~/Videos`). |
| `VideoMicrophone` | The microphone last chosen (its device), or `none`. |
| `VideoCamera` | The camera to use (its device, `/dev/video0`); the first one otherwise. |
| `VideoVolume` | The volume last set, 0–1. |
| `VideoTestSources` | `YES` lists a test pattern camera and a test tone microphone, for machines with neither. |
| `VideoNoOpenPanel` | `YES`: no Open panel when Video starts with nothing to open. |

Installed by the NextBSD desktop as `/System/Applications/Video.app`, built
by [nextbsd-desktop](https://github.com/nextbsd/nextbsd-desktop). Work is
tracked in [nextbsd/nextbsd](https://github.com/nextbsd/nextbsd) (#718). Its
help book comes with the Help work (#714).

BSD 2-Clause; see [LICENSE](LICENSE).
