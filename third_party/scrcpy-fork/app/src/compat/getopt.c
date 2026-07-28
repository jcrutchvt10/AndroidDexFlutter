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
 *
 * Provides getopt(), getopt_long(), getopt_long_only() using a simple
 * state-machine approach. This is a clean-room reimplementation based on the
 * POSIX specification — no proprietary code.
 */

#include "getopt.h"

#include <stdio.h>
#include <string.h>

/* Global state */
char *optarg = NULL;
int optind = 1;
int opterr = 1;
int optopt = 0;

/* Internal state */
static int optwhere = 1;  /* next char to process in the current argv element */

static const char *
_progname(void) {
    /* Best-effort: return basename of argv[0] (the caller sets optind=1, but
       we read argv[-1] which is argv[0] by convention). Not critical. */
    return "scrcpy";
}

/* getopt() - POSIX short-option parser */
int
getopt(int argc, char * const argv[], const char *optstring)
{
    if (optind >= argc || argv[optind] == NULL)
        return -1;

    const char *arg = argv[optind];
    if (arg[0] != '-' || arg[1] == '\0') {
        /* Not an option (bare '-' or no leading dash) */
        return -1;
    }
    if (arg[1] == '-' && arg[2] == '\0') {
        /* "--" end of options marker */
        optind++;
        return -1;
    }

    char c = arg[optwhere];
    if (c == '\0') {
        /* End of this argument, move to the next */
        optwhere = 1;
        optind++;
        return getopt(argc, argv, optstring);
    }

    /* Find the option in optstring */
    const char *match = strchr(optstring, c);
    if (match == NULL) {
        /* Unknown option */
        optopt = (unsigned char)c;
        if (opterr)
            fprintf(stderr, "%s: illegal option -- %c\n", _progname(), c);
        optwhere++;
        return '?';
    }

    if (match[1] == ':') {
        /* Option requires an argument */
        if (arg[optwhere + 1] != '\0') {
            /* Argument follows in the same argv element (e.g. -oarg) */
            optarg = (char *)&arg[optwhere + 1];
            optwhere = 1;
            optind++;
        } else {
            /* Argument is the next argv element */
            optwhere = 1;
            optind++;
            if (optind >= argc) {
                optopt = (unsigned char)c;
                if (opterr)
                    fprintf(stderr, "%s: option requires an argument -- %c\n",
                            _progname(), c);
                return (optstring[0] == ':') ? ':' : '?';
            }
            optarg = (char *)argv[optind];
            optind++;
        }
        return c;
    }

    /* No argument required */
    optwhere++;
    return c;
}

/* getopt_long() - POSIX long-option parser */
int
getopt_long(int argc, char * const argv[],
            const char *optstring,
            const struct option *longopts, int *longindex)
{
    if (optind >= argc || argv[optind] == NULL)
        return -1;

    const char *arg = argv[optind];
    if (arg[0] != '-')
        return -1;

    /* Handle long options (--option or --option=value) */
    if (arg[1] == '-') {
        const char *longarg = arg + 2;
        if (*longarg == '\0') {
            /* "--" end of options */
            optind++;
            return -1;
        }

        /* Split "longopt=value" into name and value */
        const char *eq = strchr(longarg, '=');
        size_t namelen = eq ? (size_t)(eq - longarg) : strlen(longarg);

        /* Search long options */
        int found = -1;
        for (int i = 0; longopts[i].name != NULL; i++) {
            if (strlen(longopts[i].name) == namelen &&
                strncmp(longopts[i].name, longarg, namelen) == 0) {
                found = i;
                break;
            }
        }

        if (found < 0) {
            /* No match — try ambiguous abbreviation (not implemented) */
            optopt = 0;
            if (opterr)
                fprintf(stderr, "%s: unrecognized option '--%s'\n",
                        _progname(), longarg);
            optind++;
            return '?';
        }

        if (longindex)
            *longindex = found;

        const struct option *lo = &longopts[found];

        if (lo->has_arg == required_argument) {
            if (eq) {
                optarg = (char *)(eq + 1);
            } else {
                optind++;
                if (optind >= argc) {
                    if (opterr)
                        fprintf(stderr,
                                "%s: option '--%s' requires an argument\n",
                                _progname(), lo->name);
                    return (optstring && optstring[0] == ':') ? ':' : '?';
                }
                optarg = (char *)argv[optind];
            }
        } else if (lo->has_arg == optional_argument) {
            optarg = eq ? (char *)(eq + 1) : NULL;
        } else {
            if (eq) {
                /* Option doesn't take an argument but one was provided */
                if (opterr)
                    fprintf(stderr,
                            "%s: option '--%s' doesn't allow an argument\n",
                            _progname(), lo->name);
                return '?';
            }
            optarg = NULL;
        }

        optind++;
        optwhere = 1;

        if (lo->flag) {
            *lo->flag = lo->val;
            return 0;
        }
        return lo->val;
    }

    /* Single-dash short option (only when '-' is not a long option) */
    /* Process as short option via getopt */
    return getopt(argc, argv, optstring);
}

/* getopt_long_only() - Like getopt_long() but single '-' matches long opts */
int
getopt_long_only(int argc, char * const argv[],
                 const char *optstring,
                 const struct option *longopts, int *longindex)
{
    if (optind >= argc || argv[optind] == NULL)
        return -1;

    const char *arg = argv[optind];
    if (arg[0] != '-')
        return -1;

    /* Try it as a long option first (single-dash long option) */
    if (arg[1] != '-') {
        const char *longarg = arg + 1;
        const char *eq = strchr(longarg, '=');
        size_t namelen = eq ? (size_t)(eq - longarg) : strlen(longarg);

        /* Check if it matches any long option */
        for (int i = 0; longopts[i].name != NULL; i++) {
            if (strlen(longopts[i].name) == namelen &&
                strncmp(longopts[i].name, longarg, namelen) == 0) {
                /* Long match — process as getopt_long with -- prefix */
                /* Build a synthetic --longarg argv entry */
                char saved = (char)argv[optind][1];
                argv[optind][1] = '-';  /* temporarily make it --arg */
                /* 'arg' may have been modified by the const cast; restore */
                int ret = getopt_long(argc, argv, optstring, longopts, longindex);
                argv[optind][1] = saved;
                return ret;
            }
        }
        /* No long match — fall through to normal short option parsing */
    }

    return getopt_long(argc, argv, optstring, longopts, longindex);
}
