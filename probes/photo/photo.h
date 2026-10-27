#ifndef NIH_PHOTO_H
#define NIH_PHOTO_H
#include <stddef.h>
#include <stdint.h>
/* Private single-owner scratch. No logging, files or persistent output. */
int nih_photo_decode(const uint8_t *, size_t, uint8_t *, size_t, uint8_t *, size_t);
#endif
