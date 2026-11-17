// -*- Mode: C -*-

// small JPEGs from big ones, with libjpeg's DCT scaling (see jpegthumb.c).

void *jt_open (char *path, int target);
int jt_step (void *h, int nrows);
long jt_size (void *h);
void jt_copy (void *h, char *dst);
char *jt_error (void *h);
void jt_close (void *h);
