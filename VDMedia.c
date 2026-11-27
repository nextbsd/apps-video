/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "VDMedia.h"
#include "VDAudio.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define VDQueueSize 6			/* pictures decoded ahead */
#define VDRingSeconds 2			/* sound decoded ahead */
#define VDChunk 1024			/* sound frames a write */
#define VDFade 256			/* overlap at other speeds */
#define VDLate 0.15			/* sound this late is dropped */
#define VDEarly 0.15			/* sound this early waits */
#define VDResync 0.04			/* the device's clock moves ours */

struct VDMedia
{
  AVFormatContext *format;
  int videoIndex;		/* -1: none */
  int audioIndex;
  AVCodecContext *video;
  AVCodecContext *audio;
  struct SwsContext *sws;
  SwrContext *swr;
  AVChannelLayout swrInLayout;
  int swrInFormat;
  int swrInRate;
  double startOffset;		/* the file's first time, seconds */
  double frameSeconds;		/* a picture's length, a guess */
  VDMediaInfo info;

  pthread_t decodeThread;
  pthread_t audioThread;
  int haveDecodeThread;
  int haveAudioThread;
  pthread_mutex_t lock;
  pthread_cond_t cond;		/* any change: broadcast */
  int quit;

  int seekPending;		/* asked for, not yet done */
  int seeking;			/* asked for, until the decoder's done it */
  double seekTarget;
  double skipUntil;		/* drop what's decoded before this */
  int generation;		/* goes up with each seek */
  int eof;			/* everything's decoded */
  double decodedEnd;		/* the end of what's decoded */
  int atEnd;

  /* Pictures: queue[head], ... count of them, oldest first. */
  VDImage queue[VDQueueSize];
  int head;
  int count;
  int outWidth;
  int outHeight;
  int needFirst;		/* show the next picture whatever its time */

  /* Sound: rate frames a second of channels 16-bit samples. */
  VDAudioOut *out;
  int rate;
  int channels;
  int16_t *ring;
  int ringFrames;
  int ringRead;
  int ringCount;
  double ringTime;		/* the time of the frame at ringRead */
  int ringStarted;		/* ringTime is known since the seek */
  char audioStatus[96];

  float volume;
  double speed;

  /* The clock: at baseTime (monotonic seconds) it was basePts. */
  int playing;
  double basePts;
  double baseTime;
};

static double
VDNow (void)
{
  struct timespec ts;

  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (double) ts.tv_sec + ts.tv_nsec / 1e9;
}

static double
VDClockLocked (VDMedia *m)
{
  if (!m->playing)
    return m->basePts;
  return m->basePts + (VDNow () - m->baseTime) * m->speed;
}

static void
VDSetClockLocked (VDMedia *m, double pts)
{
  m->basePts = pts;
  m->baseTime = VDNow ();
}

static void
VDError (char *error, size_t errorSize, const char *what, int code)
{
  char reason[AV_ERROR_MAX_STRING_SIZE];

  av_strerror (code, reason, sizeof (reason));
  snprintf (error, errorSize, "%s: %s", what, reason);
}

/* ---- what's in a file ---- */

static int
VDIsPicture (AVStream *st)
{
  return (st->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0;
}

static void
VDCodecName (const AVCodecParameters *par, char *name, size_t size)
{
  const AVCodecDescriptor *d = avcodec_descriptor_get (par->codec_id);

  if (d == NULL)
    snprintf (name, size, "Unknown");
  else
    snprintf (name, size, "%s", d->long_name ? d->long_name : d->name);
}

static void
VDFillInfo (AVFormatContext *f, int videoIndex, int audioIndex,
            VDMediaInfo *info)
{
  AVStream *st;
  AVRational sar, rate;

  memset (info, 0, sizeof (*info));
  if (f->duration != AV_NOPTS_VALUE && f->duration > 0)
    info->duration = f->duration / (double) AV_TIME_BASE;
  snprintf (info->container, sizeof (info->container), "%s",
            f->iformat->long_name ? f->iformat->long_name
            : f->iformat->name);
  info->bitRate = f->bit_rate;
  if (videoIndex >= 0)
    {
      st = f->streams[videoIndex];
      info->hasVideo = 1;
      info->width = st->codecpar->width;
      info->height = st->codecpar->height;
      sar = av_guess_sample_aspect_ratio (f, st, NULL);
      if (sar.num > 0 && sar.den > 0 && sar.num != sar.den)
        info->width = (int) lrint (info->width * av_q2d (sar));
      rate = av_guess_frame_rate (f, st, NULL);
      if (rate.num > 0 && rate.den > 0)
        info->frameRate = av_q2d (rate);
      VDCodecName (st->codecpar, info->videoCodec, sizeof (info->videoCodec));
      if (info->duration == 0 && st->duration != AV_NOPTS_VALUE)
        info->duration = st->duration * av_q2d (st->time_base);
    }
  if (audioIndex >= 0)
    {
      st = f->streams[audioIndex];
      info->hasAudio = 1;
      info->sampleRate = st->codecpar->sample_rate;
      info->channels = st->codecpar->ch_layout.nb_channels;
      VDCodecName (st->codecpar, info->audioCodec, sizeof (info->audioCodec));
      if (info->duration == 0 && st->duration != AV_NOPTS_VALUE)
        info->duration = st->duration * av_q2d (st->time_base);
    }
}

/* Opens and reads the file's streams; picks a video and a sound one. */
static int
VDOpenFormat (const char *path, AVFormatContext **format, int *videoIndex,
              int *audioIndex, char *error, size_t errorSize)
{
  AVFormatContext *f = NULL;
  int r;

  av_log_set_level (AV_LOG_ERROR);
  r = avformat_open_input (&f, path, NULL, NULL);
  if (r < 0)
    {
      if (r == AVERROR_INVALIDDATA)
        snprintf (error, errorSize, "It isn't a kind of video Video can"
                  " open");
      else
        VDError (error, errorSize, "Can't open it", r);
      return -1;
    }
  r = avformat_find_stream_info (f, NULL);
  if (r < 0)
    {
      VDError (error, errorSize, "Can't read it", r);
      avformat_close_input (&f);
      return -1;
    }
  *videoIndex = av_find_best_stream (f, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (*videoIndex >= 0 && VDIsPicture (f->streams[*videoIndex]))
    *videoIndex = -1;		/* a song's cover */
  *audioIndex = av_find_best_stream (f, AVMEDIA_TYPE_AUDIO, -1,
                                     *videoIndex, NULL, 0);
  if (*videoIndex < 0)
    *videoIndex = -1;
  if (*audioIndex < 0)
    *audioIndex = -1;
  if (*videoIndex < 0 && *audioIndex < 0)
    {
      snprintf (error, errorSize, "It has no video or sound");
      avformat_close_input (&f);
      return -1;
    }
  *format = f;
  return 0;
}

int
VDMediaProbe (const char *path, VDMediaInfo *info, char *error,
              size_t errorSize)
{
  AVFormatContext *f;
  int v, a;

  if (VDOpenFormat (path, &f, &v, &a, error, errorSize) != 0)
    return -1;
  VDFillInfo (f, v, a, info);
  avformat_close_input (&f);
  return 0;
}

static AVCodecContext *
VDOpenDecoder (AVStream *st)
{
  const AVCodec *codec = avcodec_find_decoder (st->codecpar->codec_id);
  AVCodecContext *c;

  if (codec == NULL)
    return NULL;
  c = avcodec_alloc_context3 (codec);
  if (c == NULL)
    return NULL;
  if (avcodec_parameters_to_context (c, st->codecpar) < 0)
    {
      avcodec_free_context (&c);
      return NULL;
    }
  c->pkt_timebase = st->time_base;
  c->thread_count = 0;		/* as many as there are CPUs */
  if (avcodec_open2 (c, codec, NULL) < 0)
    {
      avcodec_free_context (&c);
      return NULL;
    }
  return c;
}

/* ---- decoding ---- */

static int
VDRingFree (VDMedia *m)
{
  return m->ringFrames - m->ringCount;
}

static void
VDFlushLocked (VDMedia *m, double target)
{
  m->head = 0;
  m->count = 0;
  m->ringRead = 0;
  m->ringCount = 0;
  m->ringTime = target;
  m->ringStarted = 0;
  m->skipUntil = target;
  m->decodedEnd = target;
  m->eof = 0;
  m->atEnd = 0;
  m->needFirst = 1;
  m->generation++;
}

static void
VDDoSeek (VDMedia *m, double target)
{
  int64_t ts = (int64_t) ((target + m->startOffset) * AV_TIME_BASE);

  avformat_seek_file (m->format, -1, INT64_MIN, ts, ts, 0);
  if (m->video != NULL)
    avcodec_flush_buffers (m->video);
  if (m->audio != NULL)
    avcodec_flush_buffers (m->audio);
  pthread_mutex_lock (&m->lock);
  VDFlushLocked (m, target);
  if (!m->seekPending)
    m->seeking = 0;
  pthread_cond_broadcast (&m->cond);
  pthread_mutex_unlock (&m->lock);
}

static double
VDFrameTime (VDMedia *m, AVFrame *frame, AVStream *st, double fallback)
{
  int64_t pts = frame->best_effort_timestamp;

  if (pts == AV_NOPTS_VALUE)
    return fallback;
  return pts * av_q2d (st->time_base) - m->startOffset;
}

static void
VDPushPicture (VDMedia *m, AVFrame *frame)
{
  AVStream *st = m->format->streams[m->videoIndex];
  VDImage *slot;
  double t;
  int generation, w, h;
  uint8_t *dst[4];
  int dstStride[4];
  size_t stride, need;

  pthread_mutex_lock (&m->lock);
  t = VDFrameTime (m, frame, st, m->decodedEnd);
  if (t + m->frameSeconds / 2 < m->skipUntil)
    {
      pthread_mutex_unlock (&m->lock);
      return;			/* before where it was asked to go */
    }
  while (m->count == VDQueueSize && !m->quit && !m->seekPending)
    pthread_cond_wait (&m->cond, &m->lock);
  if (m->quit || m->seekPending)
    {
      pthread_mutex_unlock (&m->lock);
      return;
    }
  generation = m->generation;
  slot = &m->queue[(m->head + m->count) % VDQueueSize];
  w = m->outWidth > 0 ? m->outWidth : m->info.width;
  h = m->outHeight > 0 ? m->outHeight : m->info.height;
  pthread_mutex_unlock (&m->lock);

  /* The slot isn't in the queue yet: only this thread touches it. */
  w = w < 2 ? 2 : (w > 8192 ? 8192 : w);
  h = h < 2 ? 2 : (h > 8192 ? 8192 : h);
  stride = ((size_t) w * 3 + 15) & ~(size_t) 15;
  need = stride * (size_t) h;
  if (slot->capacity < need)
    {
      unsigned char *bigger = realloc (slot->rgb, need);

      if (bigger == NULL)
        return;
      slot->rgb = bigger;
      slot->capacity = need;
    }
  m->sws = sws_getCachedContext (m->sws, frame->width, frame->height,
                                 frame->format, w, h, AV_PIX_FMT_RGB24,
                                 SWS_BILINEAR, NULL, NULL, NULL);
  if (m->sws == NULL)
    return;
  dst[0] = slot->rgb;
  dst[1] = dst[2] = dst[3] = NULL;
  dstStride[0] = (int) stride;
  dstStride[1] = dstStride[2] = dstStride[3] = 0;
  sws_scale (m->sws, (const uint8_t *const *) frame->data, frame->linesize,
             0, frame->height, dst, dstStride);
  slot->width = w;
  slot->height = h;
  slot->stride = stride;
  slot->time = t;

  pthread_mutex_lock (&m->lock);
  if (generation == m->generation && !m->seekPending && !m->quit)
    {
      m->count++;
      if (t + m->frameSeconds > m->decodedEnd)
        m->decodedEnd = t + m->frameSeconds;
      pthread_cond_broadcast (&m->cond);
    }
  pthread_mutex_unlock (&m->lock);
}

/* Puts frames of sound into the ring, waiting for room. */
static void
VDRingPutLocked (VDMedia *m, const int16_t *samples, int frames)
{
  int n, at, i, room;

  while (frames > 0)
    {
      while (VDRingFree (m) == 0 && !m->quit && !m->seekPending)
        pthread_cond_wait (&m->cond, &m->lock);
      if (m->quit || m->seekPending)
        return;
      room = VDRingFree (m);
      n = frames < room ? frames : room;
      for (i = 0; i < n; i++)
        {
          at = (m->ringRead + m->ringCount + i) % m->ringFrames;
          if (samples != NULL)
            memcpy (m->ring + at * m->channels, samples + i * m->channels,
                    sizeof (int16_t) * (size_t) m->channels);
          else
            memset (m->ring + at * m->channels, 0,
                    sizeof (int16_t) * (size_t) m->channels);
        }
      m->ringCount += n;
      frames -= n;
      if (samples != NULL)
        samples += n * m->channels;
      pthread_cond_broadcast (&m->cond);
    }
}

static int
VDSetUpResampler (VDMedia *m, AVFrame *frame)
{
  AVChannelLayout outLayout;

  if (m->swr != NULL && frame->format == m->swrInFormat
      && frame->sample_rate == m->swrInRate
      && av_channel_layout_compare (&frame->ch_layout, &m->swrInLayout) == 0)
    return 0;
  swr_free (&m->swr);
  av_channel_layout_uninit (&m->swrInLayout);
  av_channel_layout_default (&outLayout, m->channels);
  if (swr_alloc_set_opts2 (&m->swr, &outLayout, AV_SAMPLE_FMT_S16, m->rate,
                           &frame->ch_layout, frame->format,
                           frame->sample_rate, 0, NULL) < 0
      || swr_init (m->swr) < 0)
    {
      swr_free (&m->swr);
      return -1;
    }
  av_channel_layout_copy (&m->swrInLayout, &frame->ch_layout);
  m->swrInFormat = frame->format;
  m->swrInRate = frame->sample_rate;
  return 0;
}

static void
VDPushSound (VDMedia *m, AVFrame *frame)
{
  AVStream *st = m->format->streams[m->audioIndex];
  int16_t *buffer;
  int capacity, frames, skip;
  double t, expected, gap;

  if (frame->sample_rate <= 0 || VDSetUpResampler (m, frame) != 0)
    return;
  capacity = (int) av_rescale_rnd (swr_get_delay (m->swr, frame->sample_rate)
                                   + frame->nb_samples, m->rate,
                                   frame->sample_rate, AV_ROUND_UP) + 64;
  buffer = malloc (sizeof (int16_t) * (size_t) capacity
                   * (size_t) m->channels);
  if (buffer == NULL)
    return;
  frames = swr_convert (m->swr, (uint8_t **) &buffer, capacity,
                        (const uint8_t **) frame->extended_data,
                        frame->nb_samples);
  if (frames <= 0)
    {
      free (buffer);
      return;
    }

  pthread_mutex_lock (&m->lock);
  expected = m->ringTime + (double) m->ringCount / m->rate;
  t = VDFrameTime (m, frame, st, m->ringStarted ? expected : m->skipUntil);
  /* Before where it was asked to go: drop that much. */
  skip = 0;
  if (t < m->skipUntil)
    {
      skip = (int) ((m->skipUntil - t) * m->rate);
      if (skip >= frames)
        {
          pthread_mutex_unlock (&m->lock);
          free (buffer);
          return;
        }
      t += (double) skip / m->rate;
    }
  if (!m->ringStarted)
    {
      m->ringTime = t;
      m->ringStarted = 1;
    }
  else
    {
      /* A hole in the sound: silence, up to a second. */
      gap = t - (m->ringTime + (double) m->ringCount / m->rate);
      if (gap > 0.1)
        VDRingPutLocked (m, NULL, (int) (fmin (gap, 1.0) * m->rate));
    }
  VDRingPutLocked (m, buffer + skip * m->channels, frames - skip);
  t += (double) (frames - skip) / m->rate;
  if (!m->seekPending && t > m->decodedEnd)
    m->decodedEnd = t;
  pthread_mutex_unlock (&m->lock);
  free (buffer);
}

static void
VDReceive (VDMedia *m, AVCodecContext *c, AVFrame *frame)
{
  while (avcodec_receive_frame (c, frame) == 0)
    {
      if (c == m->video)
        VDPushPicture (m, frame);
      else
        VDPushSound (m, frame);
      av_frame_unref (frame);
      if (m->seekPending || m->quit)
        break;
    }
}

static int
VDFullLocked (VDMedia *m)
{
  if (m->video != NULL && m->count == VDQueueSize)
    return 1;
  if (m->audio != NULL && VDRingFree (m) < m->rate / 4)
    return 1;
  return 0;
}

static void *
VDDecodeThread (void *arg)
{
  VDMedia *m = arg;
  AVPacket *packet = av_packet_alloc ();
  AVFrame *frame = av_frame_alloc ();
  double target;
  int r;

  for (;;)
    {
      pthread_mutex_lock (&m->lock);
      while (!m->quit && !m->seekPending && (m->eof || VDFullLocked (m)))
        pthread_cond_wait (&m->cond, &m->lock);
      if (m->quit)
        {
          pthread_mutex_unlock (&m->lock);
          break;
        }
      if (m->seekPending)
        {
          target = m->seekTarget;
          m->seekPending = 0;
          pthread_mutex_unlock (&m->lock);
          VDDoSeek (m, target);
          continue;
        }
      pthread_mutex_unlock (&m->lock);

      r = av_read_frame (m->format, packet);
      if (r < 0)
        {
          /* The end (or an error, which ends it too): what the decoders
             still hold comes out. */
          if (m->video != NULL)
            {
              avcodec_send_packet (m->video, NULL);
              VDReceive (m, m->video, frame);
              avcodec_flush_buffers (m->video);
            }
          if (m->audio != NULL)
            {
              avcodec_send_packet (m->audio, NULL);
              VDReceive (m, m->audio, frame);
              avcodec_flush_buffers (m->audio);
            }
          pthread_mutex_lock (&m->lock);
          if (!m->seekPending)
            m->eof = 1;
          pthread_cond_broadcast (&m->cond);
          pthread_mutex_unlock (&m->lock);
          continue;
        }
      if (m->video != NULL && packet->stream_index == m->videoIndex)
        {
          if (avcodec_send_packet (m->video, packet) == 0)
            VDReceive (m, m->video, frame);
        }
      else if (m->audio != NULL && packet->stream_index == m->audioIndex)
        {
          if (avcodec_send_packet (m->audio, packet) == 0)
            VDReceive (m, m->audio, frame);
        }
      av_packet_unref (packet);
    }
  av_packet_free (&packet);
  av_frame_free (&frame);
  return NULL;
}

/* ---- playing the sound ---- */

/* Copies frames from the ring at offset without taking them. */
static void
VDRingPeekLocked (VDMedia *m, int offset, int16_t *to, int frames)
{
  int i, at;

  for (i = 0; i < frames; i++)
    {
      if (offset + i < m->ringCount)
        {
          at = (m->ringRead + offset + i) % m->ringFrames;
          memcpy (to + i * m->channels, m->ring + at * m->channels,
                  sizeof (int16_t) * (size_t) m->channels);
        }
      else
        memset (to + i * m->channels, 0,
                sizeof (int16_t) * (size_t) m->channels);
    }
}

static void
VDRingTakeLocked (VDMedia *m, int frames)
{
  if (frames > m->ringCount)
    frames = m->ringCount;
  m->ringRead = (m->ringRead + frames) % m->ringFrames;
  m->ringCount -= frames;
  m->ringTime += (double) frames / m->rate;
  pthread_cond_broadcast (&m->cond);
}

static void
VDWaitLocked (VDMedia *m, double seconds)
{
  struct timespec ts;
  double until;

  clock_gettime (CLOCK_REALTIME, &ts);
  until = ts.tv_sec + ts.tv_nsec / 1e9 + seconds;
  ts.tv_sec = (time_t) until;
  ts.tv_nsec = (long) ((until - (double) ts.tv_sec) * 1e9);
  pthread_cond_timedwait (&m->cond, &m->lock, &ts);
}

static void *
VDAudioThread (void *arg)
{
  VDMedia *m = arg;
  int c = m->channels;
  int16_t *segment = malloc (sizeof (int16_t) * (VDChunk + VDFade) * 2
                             * (size_t) c);
  int16_t *tail = calloc ((size_t) VDFade * 2 * (size_t) c,
                          sizeof (int16_t));
  int16_t *out = malloc (sizeof (int16_t) * VDChunk * (size_t) c);
  int haveTail = 0, generation = -1, advance, need, i, k;
  double clock, speed, after, deviceClock, w;
  float volume;
  long v;

  if (segment == NULL || tail == NULL || out == NULL)
    goto done;
  pthread_mutex_lock (&m->lock);
  for (;;)
    {
      if (m->quit)
        break;
      if (m->generation != generation)
        {
          generation = m->generation;
          haveTail = 0;
          if (m->out != NULL)
            {
              pthread_mutex_unlock (&m->lock);
              VDAudioOutReset (m->out);
              pthread_mutex_lock (&m->lock);
            }
          continue;
        }
      if (!m->playing || m->seeking || m->ringCount == 0)
        {
          VDWaitLocked (m, 0.01);
          continue;
        }
      clock = VDClockLocked (m);
      speed = m->speed;
      volume = m->volume;
      if (m->ringTime < clock - VDLate)
        {
          /* Late (the decoder fell behind): skip to the clock. */
          VDRingTakeLocked (m, (int) ((clock - m->ringTime) * m->rate));
          haveTail = 0;
          continue;
        }
      if (m->ringTime > clock + VDEarly)
        {
          VDWaitLocked (m, 0.01);
          continue;
        }
      advance = speed == 1.0 ? VDChunk : (int) lrint (VDChunk * speed);
      need = speed == 1.0 ? VDChunk : VDChunk + VDFade;
      if (m->ringCount < (need > advance ? need : advance) && !m->eof)
        {
          VDWaitLocked (m, 0.01);
          continue;
        }
      VDRingPeekLocked (m, 0, segment, need);
      VDRingTakeLocked (m, advance);
      after = m->ringTime;
      pthread_mutex_unlock (&m->lock);

      /* Another speed: each piece is faded in over the end of the one
         before. */
      if (speed != 1.0)
        {
          if (haveTail)
            for (i = 0; i < VDFade; i++)
              {
                w = (double) i / VDFade;
                for (k = 0; k < c; k++)
                  segment[i * c + k] =
                    (int16_t) (segment[i * c + k] * w
                               + tail[i * c + k] * (1.0 - w));
              }
          memcpy (tail, segment + VDChunk * c,
                  sizeof (int16_t) * VDFade * (size_t) c);
          haveTail = 1;
        }
      else
        haveTail = 0;
      for (i = 0; i < VDChunk * c; i++)
        {
          v = lrintf (segment[i] * volume);
          out[i] = (int16_t) (v > 32767 ? 32767 : (v < -32768 ? -32768 : v));
        }

      if (m->out != NULL)
        {
          if (VDAudioOutWrite (m->out, out, VDChunk) != 0)
            {
              pthread_mutex_lock (&m->lock);
              snprintf (m->audioStatus, sizeof (m->audioStatus),
                        "The sound output went away");
              VDAudioOutClose (m->out);
              m->out = NULL;
              continue;
            }
          deviceClock = after - VDAudioOutDelay (m->out) * speed;
          pthread_mutex_lock (&m->lock);
          if (m->playing && !m->seeking && generation == m->generation
              && fabs (deviceClock - VDClockLocked (m)) > VDResync)
            VDSetClockLocked (m, deviceClock);
        }
      else
        pthread_mutex_lock (&m->lock);
    }
  pthread_mutex_unlock (&m->lock);
done:
  free (segment);
  free (tail);
  free (out);
  return NULL;
}

/* ---- the interface ---- */

VDMedia *
VDMediaOpen (const char *path, char *error, size_t errorSize)
{
  VDMedia *m = calloc (1, sizeof (*m));
  char why[96];
  int v, a;

  if (m == NULL)
    {
      snprintf (error, errorSize, "Out of memory");
      return NULL;
    }
  if (VDOpenFormat (path, &m->format, &v, &a, error, errorSize) != 0)
    {
      free (m);
      return NULL;
    }
  m->videoIndex = v;
  m->audioIndex = a;
  VDFillInfo (m->format, v, a, &m->info);
  if (m->format->start_time != AV_NOPTS_VALUE)
    m->startOffset = m->format->start_time / (double) AV_TIME_BASE;
  m->frameSeconds = m->info.frameRate > 0 ? 1.0 / m->info.frameRate
    : 1.0 / 30;
  m->volume = 1.0f;
  m->speed = 1.0;
  m->needFirst = 1;
  pthread_mutex_init (&m->lock, NULL);
  pthread_cond_init (&m->cond, NULL);

  if (v >= 0 && (m->video = VDOpenDecoder (m->format->streams[v])) == NULL)
    m->info.hasVideo = 0;
  if (a >= 0 && (m->audio = VDOpenDecoder (m->format->streams[a])) == NULL)
    {
      m->info.hasAudio = 0;
      snprintf (m->audioStatus, sizeof (m->audioStatus),
                "Video can't play this file's sound (%s)",
                m->info.audioCodec);
    }
  if (m->video == NULL && m->audio == NULL)
    {
      snprintf (error, errorSize, "Video can't play %s",
                v >= 0 ? m->info.videoCodec : m->info.audioCodec);
      VDMediaClose (m);
      return NULL;
    }
  if (m->video == NULL)
    m->videoIndex = -1;
  if (m->audio == NULL)
    m->audioIndex = -1;

  if (m->audio != NULL)
    {
      m->out = VDAudioOutOpen (&m->rate, &m->channels, why, sizeof (why));
      if (m->out == NULL)
        {
          /* Played silently, in time. */
          snprintf (m->audioStatus, sizeof (m->audioStatus), "%s", why);
          m->rate = 48000;
          m->channels = 2;
        }
      m->ringFrames = m->rate * VDRingSeconds;
      m->ring = malloc (sizeof (int16_t) * (size_t) m->ringFrames
                        * (size_t) m->channels);
      if (m->ring == NULL)
        {
          snprintf (error, errorSize, "Out of memory");
          VDMediaClose (m);
          return NULL;
        }
      if (pthread_create (&m->audioThread, NULL, VDAudioThread, m) == 0)
        m->haveAudioThread = 1;
    }
  if (pthread_create (&m->decodeThread, NULL, VDDecodeThread, m) != 0)
    {
      snprintf (error, errorSize, "Can't start playing");
      VDMediaClose (m);
      return NULL;
    }
  m->haveDecodeThread = 1;
  return m;
}

void
VDMediaClose (VDMedia *m)
{
  int i;

  if (m == NULL)
    return;
  pthread_mutex_lock (&m->lock);
  m->quit = 1;
  pthread_cond_broadcast (&m->cond);
  pthread_mutex_unlock (&m->lock);
  if (m->haveDecodeThread)
    pthread_join (m->decodeThread, NULL);
  if (m->haveAudioThread)
    pthread_join (m->audioThread, NULL);
  VDAudioOutClose (m->out);
  avcodec_free_context (&m->video);
  avcodec_free_context (&m->audio);
  avformat_close_input (&m->format);
  sws_freeContext (m->sws);
  swr_free (&m->swr);
  av_channel_layout_uninit (&m->swrInLayout);
  for (i = 0; i < VDQueueSize; i++)
    free (m->queue[i].rgb);
  free (m->ring);
  pthread_mutex_destroy (&m->lock);
  pthread_cond_destroy (&m->cond);
  free (m);
}

void
VDMediaGetInfo (VDMedia *m, VDMediaInfo *info)
{
  *info = m->info;
}

const char *
VDMediaAudioStatus (VDMedia *m)
{
  return m->audioStatus;
}

/* Stops at the end once everything's been shown and heard. */
static void
VDCheckEndLocked (VDMedia *m)
{
  double end;

  if (!m->playing || !m->eof || m->seeking || m->count > 0)
    return;
  end = m->decodedEnd;
  if (m->ringCount > 0 && VDClockLocked (m) < end)
    return;
  if (VDClockLocked (m) < end)
    return;
  m->playing = 0;
  m->basePts = end;
  m->atEnd = 1;
}

void
VDMediaPlay (VDMedia *m)
{
  pthread_mutex_lock (&m->lock);
  if (m->atEnd)
    {
      m->atEnd = 0;
      m->seekPending = 1;
      m->seeking = 1;
      m->seekTarget = 0;
      m->basePts = 0;
    }
  m->playing = 1;
  m->baseTime = VDNow ();
  pthread_cond_broadcast (&m->cond);
  pthread_mutex_unlock (&m->lock);
}

void
VDMediaPause (VDMedia *m)
{
  pthread_mutex_lock (&m->lock);
  if (m->playing)
    {
      m->basePts = VDClockLocked (m);
      m->playing = 0;
    }
  pthread_cond_broadcast (&m->cond);
  pthread_mutex_unlock (&m->lock);
}

int
VDMediaIsPlaying (VDMedia *m)
{
  int playing;

  pthread_mutex_lock (&m->lock);
  VDCheckEndLocked (m);
  playing = m->playing;
  pthread_mutex_unlock (&m->lock);
  return playing;
}

int
VDMediaAtEnd (VDMedia *m)
{
  int atEnd;

  pthread_mutex_lock (&m->lock);
  VDCheckEndLocked (m);
  atEnd = m->atEnd;
  pthread_mutex_unlock (&m->lock);
  return atEnd;
}

double
VDMediaTime (VDMedia *m)
{
  double t;

  pthread_mutex_lock (&m->lock);
  t = VDClockLocked (m);
  pthread_mutex_unlock (&m->lock);
  if (m->info.duration > 0 && t > m->info.duration)
    t = m->info.duration;
  return t < 0 ? 0 : t;
}

void
VDMediaSeek (VDMedia *m, double seconds)
{
  if (m->info.duration > 0 && seconds > m->info.duration)
    seconds = m->info.duration;
  if (seconds < 0)
    seconds = 0;
  pthread_mutex_lock (&m->lock);
  m->seekPending = 1;
  m->seeking = 1;
  m->seekTarget = seconds;
  m->atEnd = 0;
  VDSetClockLocked (m, seconds);
  pthread_cond_broadcast (&m->cond);
  pthread_mutex_unlock (&m->lock);
}

void
VDMediaSetVolume (VDMedia *m, float volume)
{
  pthread_mutex_lock (&m->lock);
  m->volume = volume < 0 ? 0 : (volume > 1 ? 1 : volume);
  pthread_mutex_unlock (&m->lock);
}

void
VDMediaSetSpeed (VDMedia *m, double speed)
{
  pthread_mutex_lock (&m->lock);
  VDSetClockLocked (m, VDClockLocked (m));
  m->speed = speed < 0.5 ? 0.5 : (speed > 2.0 ? 2.0 : speed);
  pthread_mutex_unlock (&m->lock);
}

void
VDMediaSetOutputSize (VDMedia *m, int width, int height)
{
  pthread_mutex_lock (&m->lock);
  m->outWidth = width;
  m->outHeight = height;
  pthread_mutex_unlock (&m->lock);
}

int
VDMediaCopyFrame (VDMedia *m, VDImage *image)
{
  VDImage *first, swap;
  double clock;
  int found = 0;

  pthread_mutex_lock (&m->lock);
  if (m->seeking || m->count == 0)
    {
      VDCheckEndLocked (m);
      pthread_mutex_unlock (&m->lock);
      return 0;
    }
  clock = VDClockLocked (m);
  if (m->needFirst)
    {
      found = 1;
      m->needFirst = 0;
    }
  else
    /* The newest picture that's due; older ones are dropped. */
    while (m->count > 0 && m->queue[m->head].time <= clock + 0.005)
      {
        if (m->count > 1
            && m->queue[(m->head + 1) % VDQueueSize].time <= clock + 0.005)
          {
            m->head = (m->head + 1) % VDQueueSize;
            m->count--;
            continue;
          }
        found = 1;
        break;
      }
  if (found)
    {
      /* The caller's buffer and the slot's change places. */
      first = &m->queue[m->head];
      swap = *image;
      *image = *first;
      first->rgb = swap.rgb;
      first->capacity = swap.capacity;
      m->head = (m->head + 1) % VDQueueSize;
      m->count--;
    }
  pthread_cond_broadcast (&m->cond);
  VDCheckEndLocked (m);
  pthread_mutex_unlock (&m->lock);
  return found;
}

void
VDImageFree (VDImage *image)
{
  free (image->rgb);
  memset (image, 0, sizeof (*image));
}
