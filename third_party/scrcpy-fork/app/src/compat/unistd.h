/* Minimal unistd.h for MSVC — provides getopt and basic POSIX functions */
#ifndef COMPAT_UNISTD_H
#define COMPAT_UNISTD_H

#include "getopt.h"

#ifdef _MSC_VER
/* MSVC provides _getpid() but not getpid() */
#include <process.h>
#define getpid _getpid
#endif

#endif /* COMPAT_UNISTD_H */
