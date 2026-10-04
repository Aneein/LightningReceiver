/* Lightning Receiver - MinGW compatibility shims for the no-OS driver.
 * Force-included (-include) into every translation unit by build.ps1. */
#ifndef LR_COMPAT_H
#define LR_COMPAT_H

/* BSD strsep() is used by ad9361_parse_fir(); MinGW does not provide it.
 * A real prototype matters on 64-bit: an implicit int return would truncate
 * the pointer. */
char *strsep(char **stringp, const char *delim);

#endif
