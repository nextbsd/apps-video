/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * VDRecorder: writes a recording as a QuickTime movie (.mov), with the
 * encoders NextBSD's ffmpeg has (nextbsd-gnustep-support#13): MPEG-4
 * part 2 video and AAC sound, through libavformat's mov muxer.
 *
 * Pictures come as packed RGB with the time they were taken; sound as
 * 16-bit interleaved samples, in order, at the rate given. Either may be
 * left out (a sound recording has no pictures). Everything here runs on
 * the caller's thread.
 */

#ifndef _VD_RECORDER_H_
#define _VD_RECORDER_H_

#include <stddef.h>
#include <stdint.h>

#define VDRecorderExtension "mov"
#define VDRecorderFrameRate 30

typedef struct VDRecorder VDRecorder;

/* Starts a movie at path, a new file. width x height pictures (0 x 0:
   none), sound at rate with channels (0: none). NULL with why in
   error. */
VDRecorder *VDRecorderStart (const char *path, int width, int height,
                             int rate, int channels, char *error,
                             size_t errorSize);

/* Adds a picture taken seconds after the start. Pictures of another
   size are scaled. 0, or -1 with why in error. */
int VDRecorderAddPicture (VDRecorder *recorder, const unsigned char *rgb,
                          int width, int height, size_t stride,
                          double seconds, char *error, size_t errorSize);

/* Adds frames of sound. 0, or -1 with why in error. */
int VDRecorderAddSound (VDRecorder *recorder, const int16_t *samples,
                        int frames, char *error, size_t errorSize);

/* Bytes written so far. */
long long VDRecorderBytes (VDRecorder *recorder);

/* Writes what's left and closes the movie. 0, or -1 with why in error;
   the recorder is freed either way. */
int VDRecorderFinish (VDRecorder *recorder, char *error, size_t errorSize);

#endif /* _VD_RECORDER_H_ */
