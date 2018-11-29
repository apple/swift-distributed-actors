//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <signal.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <sys/types.h>
#include <sys/ucontext.h>
#include <unistd.h>

#include <dispatch/dispatch.h>

#include "include/survive_crash_support.h"

/* This variable holds the dispatch group in the time between the crash handler
 * being registered and the first crash having happened. Otherwise NULL.
 * To be used with atomic_compare_exchange_strong */
static _Atomic dispatch_group_t crashGroup = NULL;

__attribute__((noinline))
void complain_and_pause_thread(void *ctx) {
    int fd[2] = { -1, -1 };
    /* manually align the stack to a 16 byte boundary. Please someone
     * knowledgable tell me what the __attribute__ to do that is ;). */
    __asm__("subq $15, %%rsp\n"
            "movq $0xfffffffffff0, %%rsi\n"
            "andq %%rsi, %%rsp\n" ::: "sp", "si", "cc", "memory");

    dispatch_group_t g = crashGroup;
    if (g && atomic_compare_exchange_strong(&crashGroup, &g, NULL)) {
        /* we won the race and the handler is set */

        dispatch_group_leave(g); /* this should fire the crash handler */
        dispatch_release(g);
    }
    pipe(fd);
    while (true) {
        char buf;
        read(fd[0], &buf, 1);
    }
}

static void sighandler(int signo, siginfo_t *si, void *data) {
    ucontext_t *uc = (ucontext_t *)data;

#ifdef __linux__
    uc->uc_mcontext.gregs[REG_RIP] = (greg_t)&complain_and_pause_thread;
#elif __APPLE__
    uc->uc_mcontext->__ss.__rip = (uint64_t)&complain_and_pause_thread;
#else
#   error platform unsupported
#endif
}


/* returns errno and sets errno appropriately, 0 on success */
int install_swift_crash_handler(void(^crashHappened)(void)) {
    dispatch_group_t g = dispatch_group_create();

    dispatch_group_t g_actual = NULL;
    if (atomic_compare_exchange_strong(&crashGroup, &g_actual, g)) {
        /* we won the race */
        assert(crashGroup == g);

        dispatch_group_enter(crashGroup);
        dispatch_group_notify(crashGroup,
                              dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                              crashHappened);

        struct sigaction sa = { 0 };
        sa.sa_flags = SA_ONSTACK | SA_RESTART | SA_SIGINFO;
        sa.sa_sigaction = sighandler;

        int e = sigaction(SIGILL, &sa, NULL);
        if (e) {
            int errno_save = errno;
            dispatch_release(g);
            errno = errno_save;
            assert(errno_save != 0);
            return errno_save;
        }

        sa.sa_flags = SA_ONSTACK | SA_RESTART | SA_SIGINFO;
        sa.sa_sigaction = sighandler;
        e = sigaction(SIGABRT, &sa, NULL);
        if (e) {
            int errno_save = errno;
            dispatch_release(g);
            errno = errno_save;
            assert(errno_save != 0);
            return errno_save;
        }

        /* no need to release g, will be done when the crash happens. */
        return 0;
    } else {
        /* we lost the race so couldn't install the handler */
        dispatch_release(g);

        errno = EBUSY;
        return errno;
    }
}

void simulate_trap(void) {
    __asm__("UD2");
}
