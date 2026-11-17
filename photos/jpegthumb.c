// -*- Mode: C -*-

// small JPEGs from big ones (scans, which have no EXIF thumbnail), with
//  libjpeg's DCT scaling: decoding at 1/8 scale skips most of the IDCT.
//  the decoder's rows go straight into a compressor writing to memory.
//
// all of it, from the header on, is done a bit at a time (jt_step), so
//  that the server can let other threads run in between.  that's
//  libjpeg's I/O suspension (see "I/O suspension" in libjpeg.txt): our
//  data source hands libjpeg one chunk of the file per step, and when
//  libjpeg wants more, fill_input_buffer says "not yet" (FALSE).
//  jpeg_read_header, jpeg_start_decompress and jpeg_read_scanlines then
//  return early, having backed up to the start of whatever they were in
//  the middle of (src->next_input_byte), and the next step keeps the
//  data from there on, adds another chunk, and calls them again.  this
//  matters most for progressive JPEGs, where jpeg_start_decompress reads
//  the whole file.
//
// libjpeg reports errors by calling error_exit, which by default calls
//  exit().  here it longjmps back to the jt_ call that was running, which
//  records the message and cleans up.  only C frames (ours and libjpeg's)
//  are ever between the setjmp and the longjmp, and libjpeg's allocations
//  all go when its objects are destroyed.
//
//   h = jt_open (path, target)  never NULL unless out of memory
//   jt_step (h, nrows)          1: more to do, 0: done, -1: failed (jt_error)
//   jt_size (h), jt_copy (h, dst)  the JPEG, once jt_step returns 0
//   jt_close (h)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <jpeglib.h>

#include "jpegthumb.h"

// input per step.
#define JT_CHUNK (64 * 1024)

// a progressive JPEG is held whole in memory while it's decoded: don't
//  let one take the server down.
#define JT_MAX_MEMORY (512L * 1024 * 1024)

typedef struct {
  struct jpeg_error_mgr pub;
  jmp_buf jump;
  int failed;
} jt_error_mgr;

typedef struct {
  struct jpeg_source_mgr pub;
  FILE *in;
  unsigned char *buf;
  size_t cap;
  long skip;             // bytes to skip before the next read
  int eof;
  unsigned char eoi[2];  // a fake EOI, for a file that ends early
} jt_source;

enum { JT_HEADER, JT_START, JT_SCAN, JT_DONE, JT_FAILED };

typedef struct {
  struct jpeg_decompress_struct d;
  struct jpeg_compress_struct c;
  jt_error_mgr derr, cerr;
  jt_source src;
  int d_made, c_made;    // jpeg_create_* done
  int target;
  JSAMPARRAY row;
  unsigned char *out;    // from jpeg_mem_dest
  unsigned long out_size;
  int state;
  char error[JMSG_LENGTH_MAX + 32];
} jt;

// --------------------------------------------------------------------------------
// the data source

static void
src_init (j_decompress_ptr d)
{
}

// libjpeg has used up what we gave it.  this step's input is all there
//  is: suspend, unless the file has ended.
static boolean
src_fill (j_decompress_ptr d)
{
  jt_source *s = (jt_source *) d->src;
  if (!s->eof) {
    return FALSE;
  }
  // the file ended early: give libjpeg an EOI, so it stops (it warns
  //  about the missing data, and fills the rest of the image in grey).
  s->eoi[0] = 0xFF;
  s->eoi[1] = JPEG_EOI;
  s->pub.next_input_byte = s->eoi;
  s->pub.bytes_in_buffer = 2;
  return TRUE;
}

static void
src_skip (j_decompress_ptr d, long n)
{
  jt_source *s = (jt_source *) d->src;
  if (n <= 0) {
    return;
  }
  if ((size_t) n <= s->pub.bytes_in_buffer) {
    s->pub.next_input_byte += n;
    s->pub.bytes_in_buffer -= n;
  } else {
    // the rest is skipped when the next chunk is read.
    s->skip += n - s->pub.bytes_in_buffer;
    s->pub.next_input_byte += s->pub.bytes_in_buffer;
    s->pub.bytes_in_buffer = 0;
  }
}

static void
src_term (j_decompress_ptr d)
{
}

// before each step: keep what libjpeg hasn't used (from its backtrack
//  point on), and add another chunk.  returns 0 if out of memory.
static int
src_feed (jt_source *s)
{
  size_t kept = s->pub.bytes_in_buffer;
  if (s->eof || s->pub.next_input_byte == s->eoi || kept >= JT_CHUNK) {
    return 1;
  }
  if (kept + JT_CHUNK > s->cap) {
    size_t cap = kept + JT_CHUNK;
    unsigned char *buf = malloc (cap);
    if (!buf) {
      return 0;
    }
    if (kept > 0) {
      memcpy (buf, s->pub.next_input_byte, kept);
    }
    free (s->buf);
    s->buf = buf;
    s->cap = cap;
  } else if (kept > 0) {
    memmove (s->buf, s->pub.next_input_byte, kept);
  }
  if (s->skip > 0) {
    if (fseek (s->in, s->skip, SEEK_CUR) != 0) {
      s->eof = 1;
    }
    s->skip = 0;
  }
  size_t n = s->eof ? 0 : fread (s->buf + kept, 1, JT_CHUNK, s->in);
  if (n == 0) {
    s->eof = 1;
  }
  s->pub.next_input_byte = s->buf;
  s->pub.bytes_in_buffer = kept + n;
  return 1;
}

// --------------------------------------------------------------------------------

static void
jt_error_exit (j_common_ptr cinfo)
{
  jt_error_mgr *err = (jt_error_mgr *) cinfo->err;
  err->failed = 1;
  longjmp (err->jump, 1);
}

// warnings (e.g. "premature end of data") would go to stderr: ignore them.
static void
jt_output_message (j_common_ptr cinfo)
{
}

static void
jt_cleanup (jt *h)
{
  if (h->c_made) {
    jpeg_destroy_compress (&h->c);
    h->c_made = 0;
  }
  if (h->d_made) {
    jpeg_destroy_decompress (&h->d);
    h->d_made = 0;
  }
  if (h->src.in) {
    fclose (h->src.in);
    h->src.in = NULL;
  }
  free (h->src.buf);
  h->src.buf = NULL;
}

static int
jt_fail_with (jt *h, const char *why)
{
  snprintf (h->error, sizeof (h->error), "%s", why);
  h->state = JT_FAILED;
  jt_cleanup (h);
  if (h->out) {
    free (h->out);
    h->out = NULL;
  }
  return -1;
}

static int
jt_fail (jt *h, j_common_ptr cinfo)
{
  char buffer[JMSG_LENGTH_MAX];
  (*cinfo->err->format_message) (cinfo, buffer);
  return jt_fail_with (h, buffer);
}

void *
jt_open (char *path, int target)
{
  jt *h = calloc (1, sizeof (jt));
  if (!h) {
    return NULL;
  }
  h->target = target;
  h->state = JT_HEADER;
  if (!(h->src.in = fopen (path, "rb"))) {
    jt_fail_with (h, "can't open the file");
    return h;
  }
  h->d.err = jpeg_std_error (&h->derr.pub);
  h->derr.pub.error_exit = jt_error_exit;
  h->derr.pub.output_message = jt_output_message;
  if (setjmp (h->derr.jump)) {
    jt_fail (h, (j_common_ptr) &h->d);
    return h;
  }
  jpeg_create_decompress (&h->d);
  h->d_made = 1;
  h->d.mem->max_memory_to_use = JT_MAX_MEMORY;
  h->src.pub.init_source = src_init;
  h->src.pub.fill_input_buffer = src_fill;
  h->src.pub.skip_input_data = src_skip;
  h->src.pub.resync_to_restart = jpeg_resync_to_restart;
  h->src.pub.term_source = src_term;
  h->d.src = &h->src.pub;
  return h;
}

// after the header: pick the scale, and the output.
static int
jt_setup (jt *h)
{
  // CMYK (Adobe) JPEGs: browsers disagree about how to show them, and
  //  libjpeg won't convert them to RGB.  leave them to the browser.
  if (h->d.jpeg_color_space == JCS_CMYK || h->d.jpeg_color_space == JCS_YCCK) {
    return 0;
  }
  // scale so that the long side is at least <target> pixels (or as close
  //  as the image allows): 1/8, 1/4, 1/2 or 1.
  JDIMENSION longest = h->d.image_width > h->d.image_height ? h->d.image_width : h->d.image_height;
  unsigned int denom = 8;
  while (denom > 1 && (longest / denom) < (JDIMENSION) h->target) {
    denom /= 2;
  }
  h->d.scale_num = 1;
  h->d.scale_denom = denom;
  h->d.out_color_space = (h->d.num_components == 1) ? JCS_GRAYSCALE : JCS_RGB;
  h->d.dct_method = JDCT_IFAST;
  h->d.do_fancy_upsampling = FALSE;
  return 1;
}

// the compressor, into memory.  (called inside jt_step's setjmp.)
static void
jt_start_output (jt *h)
{
  h->row = (*h->d.mem->alloc_sarray)
    ((j_common_ptr) &h->d, JPOOL_IMAGE, h->d.output_width * h->d.output_components, 1);
  h->c.err = jpeg_std_error (&h->cerr.pub);
  h->cerr.pub.error_exit = jt_error_exit;
  h->cerr.pub.output_message = jt_output_message;
  jpeg_create_compress (&h->c);
  h->c_made = 1;
  jpeg_mem_dest (&h->c, &h->out, &h->out_size);
  h->c.image_width = h->d.output_width;
  h->c.image_height = h->d.output_height;
  h->c.input_components = h->d.output_components;
  h->c.in_color_space = h->d.out_color_space;
  jpeg_set_defaults (&h->c);
  jpeg_set_quality (&h->c, 80, TRUE);
  jpeg_start_compress (&h->c, TRUE);
}

// one chunk of input's worth (and at most <nrows> rows of output).
int
jt_step (void *vh, int nrows)
{
  jt *h = (jt *) vh;
  if (h->state == JT_DONE) {
    return 0;
  } else if (h->state == JT_FAILED) {
    return -1;
  }
  // an error in either object lands here.
  if (setjmp (h->derr.jump) || setjmp (h->cerr.jump)) {
    if (h->derr.failed) {
      return jt_fail (h, (j_common_ptr) &h->d);
    } else {
      return jt_fail (h, (j_common_ptr) &h->c);
    }
  }
  if (!src_feed (&h->src)) {
    return jt_fail_with (h, "out of memory");
  }
  switch (h->state) {
  case JT_HEADER:
    if (jpeg_read_header (&h->d, TRUE) == JPEG_SUSPENDED) {
      return 1;
    }
    if (!jt_setup (h)) {
      return jt_fail_with (h, "CMYK");
    }
    h->state = JT_START;
    // fall through
  case JT_START:
    if (!jpeg_start_decompress (&h->d)) {
      return 1; // suspended
    }
    jt_start_output (h);
    h->state = JT_SCAN;
    // fall through
  case JT_SCAN:
    for (int i = 0; i < nrows && h->d.output_scanline < h->d.output_height; i++) {
      if (jpeg_read_scanlines (&h->d, h->row, 1) != 1) {
        return 1; // suspended
      }
      jpeg_write_scanlines (&h->c, h->row, 1);
    }
    if (h->d.output_scanline < h->d.output_height) {
      return 1;
    }
    jpeg_finish_compress (&h->c);
    // (not jpeg_finish_decompress: it would read the rest of the file,
    //  and a truncated one would fail there with a good thumbnail made.)
    jpeg_abort_decompress (&h->d);
    h->state = JT_DONE;
    jt_cleanup (h);
    return 0;
  }
  return -1;
}

long
jt_size (void *vh)
{
  jt *h = (jt *) vh;
  return (h->state == JT_DONE) ? (long) h->out_size : 0;
}

void
jt_copy (void *vh, char *dst)
{
  jt *h = (jt *) vh;
  if (h->state == JT_DONE) {
    memcpy (dst, h->out, h->out_size);
  }
}

char *
jt_error (void *vh)
{
  jt *h = (jt *) vh;
  return h->error;
}

void
jt_close (void *vh)
{
  jt *h = (jt *) vh;
  jt_cleanup (h);
  if (h->out) {
    free (h->out);
  }
  free (h);
}
