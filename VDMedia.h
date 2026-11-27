/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * VDMedia: plays a file, as a plain C interface the window drives.
 *
 * Decoding is NextBSD's ffmpeg (libavformat, libavcodec, libswscale,
 * libswresample), whatever it was built to read: H.264, HEVC, VP8,
 * VP9, MPEG-1/2/4 and Theora; AAC, MP3, Opus, Vorbis, FLAC and PCM.
 * (GNUstep's libs-av, AVFoundation on ffmpeg, reads assets' metadata,
 * but its AVPlayer doesn't play yet, so Video uses ffmpeg itself.)
 *
 * One thread reads and decodes, ahead of time: pictures, scaled to the
 * size the window shows them at, into a short queue, and sound, as
 * 16-bit at the device's rate, into a ring. Another plays the sound
 * through OSS (VDAudio). The clock is the time since play was pressed,
 * kept in step with what the sound device has actually played; the
 * window asks for the picture of the moment on a timer, and pictures
 * that are late are dropped. Without a sound device (or sound) the
 * clock alone keeps time, so a file plays, silently.
 *
 * Other speeds than 1x keep the pitch, roughly: the sound is cut into
 * short pieces that are overlapped closer together or further apart.
 */

#ifndef _VD_MEDIA_H_
#define _VD_MEDIA_H_

#include <stddef.h>

typedef struct VDMedia VDMedia;

typedef struct
{
  double duration;		/* seconds; 0 when unknown */
  int hasVideo;
  int hasAudio;
  int width;			/* as shown (the pixel aspect applied) */
  int height;
  double frameRate;		/* 0 when unknown */
  char container[64];		/* "QuickTime / MOV" */
  char videoCodec[96];		/* "H.264 / AVC / MPEG-4 AVC ..." */
  char audioCodec[96];
  int sampleRate;
  int channels;
  long long bitRate;		/* bits a second, overall; 0 unknown */
} VDMediaInfo;

/* A picture: packed 8-bit RGB, width x height, stride bytes a row. */
typedef struct
{
  int width;
  int height;
  size_t stride;
  unsigned char *rgb;
  size_t capacity;		/* malloc'd at rgb */
  double time;			/* seconds */
} VDImage;

/* Reads what's in the file, without playing it. 0, or -1 with why in
   error. */
int VDMediaProbe (const char *path, VDMediaInfo *info, char *error,
                  size_t errorSize);

/* Opens path, paused at the start. NULL with why in error. */
VDMedia *VDMediaOpen (const char *path, char *error, size_t errorSize);
void VDMediaClose (VDMedia *media);

void VDMediaGetInfo (VDMedia *media, VDMediaInfo *info);

/* Why there's no sound ("No sound output"), or "". */
const char *VDMediaAudioStatus (VDMedia *media);

void VDMediaPlay (VDMedia *media);
void VDMediaPause (VDMedia *media);
int VDMediaIsPlaying (VDMedia *media);

/* Played to the end (and stopped there). */
int VDMediaAtEnd (VDMedia *media);

/* Where it is, in seconds. */
double VDMediaTime (VDMedia *media);

/* Goes to seconds (clamped to the file), showing the picture there
   even while paused. */
void VDMediaSeek (VDMedia *media, double seconds);

/* 0.0-1.0, of the file's own loudness. */
void VDMediaSetVolume (VDMedia *media, float volume);

/* 0.5-2.0. */
void VDMediaSetSpeed (VDMedia *media, double speed);

/* The size the window shows pictures at, in pixels; pictures are
   scaled to it as they're decoded. */
void VDMediaSetOutputSize (VDMedia *media, int width, int height);

/* 1 and the picture of the moment in image (allocated as needed) when
   it's another than last time; 0 when not. */
int VDMediaCopyFrame (VDMedia *media, VDImage *image);

void VDImageFree (VDImage *image);

#endif /* _VD_MEDIA_H_ */
