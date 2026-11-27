/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "VDRecorder.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libswscale/swscale.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VDVideoQuality 4		/* MPEG-4's quantiser, 2 (best)-31 */

struct VDRecorder
{
  AVFormatContext *format;
  AVStream *videoStream;
  AVStream *audioStream;
  AVCodecContext *video;
  AVCodecContext *audio;
  struct SwsContext *sws;
  AVFrame *picture;
  AVFrame *sound;
  AVPacket *packet;
  int64_t lastPts;		/* the last picture's, in frames */
  int soundFill;		/* samples in sound so far */
  int64_t soundPts;		/* in samples */
  int channels;
};

static void
VDError (char *error, size_t errorSize, const char *what, int code)
{
  char reason[AV_ERROR_MAX_STRING_SIZE];

  av_strerror (code, reason, sizeof (reason));
  snprintf (error, errorSize, "%s: %s", what, reason);
}

/* Sends frame (NULL: the end) and writes the packets that come out. */
static int
VDEncode (VDRecorder *r, AVCodecContext *c, AVStream *st, AVFrame *frame,
          char *error, size_t errorSize)
{
  int e = avcodec_send_frame (c, frame);

  if (e < 0)
    {
      VDError (error, errorSize, "Can't encode the recording", e);
      return -1;
    }
  for (;;)
    {
      e = avcodec_receive_packet (c, r->packet);
      if (e == AVERROR (EAGAIN) || e == AVERROR_EOF)
        return 0;
      if (e < 0)
        {
          VDError (error, errorSize, "Can't encode the recording", e);
          return -1;
        }
      av_packet_rescale_ts (r->packet, c->time_base, st->time_base);
      r->packet->stream_index = st->index;
      e = av_interleaved_write_frame (r->format, r->packet);
      if (e < 0)
        {
          VDError (error, errorSize, "Can't write the recording", e);
          return -1;
        }
    }
}

static void
VDFree (VDRecorder *r)
{
  if (r->format != NULL && r->format->pb != NULL)
    avio_closep (&r->format->pb);
  avformat_free_context (r->format);
  avcodec_free_context (&r->video);
  avcodec_free_context (&r->audio);
  sws_freeContext (r->sws);
  av_frame_free (&r->picture);
  av_frame_free (&r->sound);
  av_packet_free (&r->packet);
  free (r);
}

static int
VDOpenVideo (VDRecorder *r, int width, int height, char *error,
             size_t errorSize)
{
  const AVCodec *codec = avcodec_find_encoder (AV_CODEC_ID_MPEG4);
  AVCodecContext *c;
  int e;

  if (codec == NULL)
    {
      snprintf (error, errorSize, "This system's ffmpeg has no MPEG-4"
                " encoder");
      return -1;
    }
  r->videoStream = avformat_new_stream (r->format, NULL);
  r->video = c = avcodec_alloc_context3 (codec);
  if (r->videoStream == NULL || c == NULL)
    {
      snprintf (error, errorSize, "Out of memory");
      return -1;
    }
  c->width = width & ~1;
  c->height = height & ~1;
  c->pix_fmt = AV_PIX_FMT_YUV420P;
  c->time_base = (AVRational) { 1, VDRecorderFrameRate };
  c->framerate = (AVRational) { VDRecorderFrameRate, 1 };
  c->gop_size = VDRecorderFrameRate * 2;
  c->max_b_frames = 0;
  c->flags |= AV_CODEC_FLAG_QSCALE;
  c->global_quality = FF_QP2LAMBDA * VDVideoQuality;
  c->thread_count = 0;
  if (r->format->oformat->flags & AVFMT_GLOBALHEADER)
    c->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  if ((e = avcodec_open2 (c, codec, NULL)) < 0)
    {
      VDError (error, errorSize, "Can't start the MPEG-4 encoder", e);
      return -1;
    }
  avcodec_parameters_from_context (r->videoStream->codecpar, c);
  r->videoStream->time_base = c->time_base;
  r->picture = av_frame_alloc ();
  if (r->picture == NULL)
    return -1;
  r->picture->format = c->pix_fmt;
  r->picture->width = c->width;
  r->picture->height = c->height;
  if ((e = av_frame_get_buffer (r->picture, 0)) < 0)
    {
      VDError (error, errorSize, "Out of memory", e);
      return -1;
    }
  r->lastPts = -1;
  return 0;
}

static int
VDOpenAudio (VDRecorder *r, int rate, int channels, char *error,
             size_t errorSize)
{
  const AVCodec *codec = avcodec_find_encoder (AV_CODEC_ID_AAC);
  AVCodecContext *c;
  int e;

  if (codec == NULL)
    {
      snprintf (error, errorSize, "This system's ffmpeg has no AAC"
                " encoder");
      return -1;
    }
  r->audioStream = avformat_new_stream (r->format, NULL);
  r->audio = c = avcodec_alloc_context3 (codec);
  if (r->audioStream == NULL || c == NULL)
    {
      snprintf (error, errorSize, "Out of memory");
      return -1;
    }
  c->sample_fmt = AV_SAMPLE_FMT_FLTP;
  c->sample_rate = rate;
  av_channel_layout_default (&c->ch_layout, channels);
  c->bit_rate = channels > 1 ? 160000 : 96000;
  c->time_base = (AVRational) { 1, rate };
  if (r->format->oformat->flags & AVFMT_GLOBALHEADER)
    c->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  if ((e = avcodec_open2 (c, codec, NULL)) < 0)
    {
      VDError (error, errorSize, "Can't start the AAC encoder", e);
      return -1;
    }
  avcodec_parameters_from_context (r->audioStream->codecpar, c);
  r->audioStream->time_base = c->time_base;
  r->sound = av_frame_alloc ();
  if (r->sound == NULL)
    return -1;
  r->sound->format = c->sample_fmt;
  r->sound->sample_rate = rate;
  av_channel_layout_copy (&r->sound->ch_layout, &c->ch_layout);
  r->sound->nb_samples = c->frame_size > 0 ? c->frame_size : 1024;
  if ((e = av_frame_get_buffer (r->sound, 0)) < 0)
    {
      VDError (error, errorSize, "Out of memory", e);
      return -1;
    }
  r->channels = channels;
  return 0;
}

VDRecorder *
VDRecorderStart (const char *path, int width, int height, int rate,
                 int channels, char *error, size_t errorSize)
{
  VDRecorder *r = calloc (1, sizeof (*r));
  int e;

  if (r == NULL)
    {
      snprintf (error, errorSize, "Out of memory");
      return NULL;
    }
  av_log_set_level (AV_LOG_ERROR);
  e = avformat_alloc_output_context2 (&r->format, NULL, "mov", path);
  if (e < 0 || r->format == NULL)
    {
      VDError (error, errorSize, "This system's ffmpeg can't write"
               " QuickTime movies", e);
      VDFree (r);
      return NULL;
    }
  r->packet = av_packet_alloc ();
  if (r->packet == NULL
      || (width >= 2 && height >= 2
          && VDOpenVideo (r, width, height, error, errorSize) != 0)
      || (rate > 0 && channels > 0
          && VDOpenAudio (r, rate, channels, error, errorSize) != 0))
    {
      VDFree (r);
      return NULL;
    }
  if ((e = avio_open (&r->format->pb, path, AVIO_FLAG_WRITE)) < 0)
    {
      VDError (error, errorSize, "Can't make the file", e);
      VDFree (r);
      return NULL;
    }
  if ((e = avformat_write_header (r->format, NULL)) < 0)
    {
      VDError (error, errorSize, "Can't write the recording", e);
      VDFree (r);
      return NULL;
    }
  return r;
}

int
VDRecorderAddPicture (VDRecorder *r, const unsigned char *rgb, int width,
                      int height, size_t stride, double seconds,
                      char *error, size_t errorSize)
{
  const uint8_t *src[4] = { rgb, NULL, NULL, NULL };
  int srcStride[4] = { (int) stride, 0, 0, 0 };
  int64_t pts;
  int e;

  if (r->video == NULL)
    return 0;
  pts = (int64_t) llround (seconds * VDRecorderFrameRate);
  if (pts <= r->lastPts)
    return 0;			/* this frame's already taken */
  if ((e = av_frame_make_writable (r->picture)) < 0)
    {
      VDError (error, errorSize, "Out of memory", e);
      return -1;
    }
  r->sws = sws_getCachedContext (r->sws, width, height, AV_PIX_FMT_RGB24,
                                 r->video->width, r->video->height,
                                 AV_PIX_FMT_YUV420P, SWS_BILINEAR,
                                 NULL, NULL, NULL);
  if (r->sws == NULL)
    {
      snprintf (error, errorSize, "Can't convert the pictures");
      return -1;
    }
  sws_scale (r->sws, src, srcStride, 0, height, r->picture->data,
             r->picture->linesize);
  r->picture->pts = pts;
  r->lastPts = pts;
  return VDEncode (r, r->video, r->videoStream, r->picture, error,
                   errorSize);
}

int
VDRecorderAddSound (VDRecorder *r, const int16_t *samples, int frames,
                    char *error, size_t errorSize)
{
  int i, c, size;
  float *plane;

  if (r->audio == NULL)
    return 0;
  size = r->sound->nb_samples;
  for (i = 0; i < frames; i++)
    {
      if (r->soundFill == 0 && av_frame_make_writable (r->sound) < 0)
        {
          snprintf (error, errorSize, "Out of memory");
          return -1;
        }
      for (c = 0; c < r->channels; c++)
        {
          plane = (float *) r->sound->data[c];
          plane[r->soundFill] = samples[i * r->channels + c] / 32768.0f;
        }
      if (++r->soundFill == size)
        {
          r->sound->pts = r->soundPts;
          r->soundPts += size;
          r->soundFill = 0;
          if (VDEncode (r, r->audio, r->audioStream, r->sound, error,
                        errorSize) != 0)
            return -1;
        }
    }
  return 0;
}

long long
VDRecorderBytes (VDRecorder *r)
{
  long long n = r->format->pb != NULL ? avio_tell (r->format->pb) : 0;

  return n < 0 ? 0 : n;
}

int
VDRecorderFinish (VDRecorder *r, char *error, size_t errorSize)
{
  int failed = 0, e, size;

  if (r->audio != NULL && r->soundFill > 0)
    {
      /* The last, short piece of sound. */
      size = r->sound->nb_samples;
      r->sound->nb_samples = r->soundFill;
      r->sound->pts = r->soundPts;
      failed |= VDEncode (r, r->audio, r->audioStream, r->sound, error,
                          errorSize) != 0;
      r->sound->nb_samples = size;
    }
  if (r->video != NULL)
    failed |= VDEncode (r, r->video, r->videoStream, NULL, error,
                        errorSize) != 0;
  if (r->audio != NULL)
    failed |= VDEncode (r, r->audio, r->audioStream, NULL, error,
                        errorSize) != 0;
  if ((e = av_write_trailer (r->format)) < 0 && !failed)
    {
      VDError (error, errorSize, "Can't finish the recording", e);
      failed = 1;
    }
  VDFree (r);
  return failed ? -1 : 0;
}
