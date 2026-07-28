/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * Copyright (c) 2000 The NetBSD Foundation, Inc.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE NETBSD FOUNDATION, INC. AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * Minimal getopt implementation for MSVC (where POSIX getopt is unavailable).
 * Provides the standard getopt(), getopt_long(), getopt_long_only() API.
 */

#ifndef COMPAT_GETOPT_H
#define COMPAT_GETOPT_H

#ifdef __cplusplus
extern "C" {
#endif

/* POSIX getopt global variables */
extern char *optarg;
extern int optind;
extern int opterr;
extern int optopt;

/* Long option structure (POSIX) */
struct option {
    const char *name;
    int has_arg;
    int *flag;
    int val;
};

/* Values for has_arg */
#define no_argument       0
#define required_argument 1
#define optional_argument 2

/* getopt() - parse short options */
int getopt(int argc, char * const argv[], const char *optstring);

/* getopt_long() - parse long and short options */
int getopt_long(int argc, char * const argv[],
                const char *optstring,
                const struct option *longopts, int *longindex);

/* getopt_long_only() - like getopt_long but '-' matches long options too */
int getopt_long_only(int argc, char * const argv[],
                     const char *optstring,
                     const struct option *longopts, int *longindex);

#ifdef __cplusplus
}
#endif

#endif /* COMPAT_GETOPT_H */
