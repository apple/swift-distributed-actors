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
#include <stdio.h>
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

#include "include/survive_crash_support.h"
#include "include/crash_support.h"

void complain_and_pause_thread(void *ctx);
int my_tid();

static atomic_flag handler_set = ATOMIC_FLAG_INIT;

// shared
static FailCellCallback shared_fail_cell_cb = NULL;

static _Thread_local void* current_run_cell = NULL; // to capture cell pointer // TODO just context should be enough
static _Thread_local void* current_fail_context = NULL; // to close over the generic

pthread_mutex_t lock;

void sact_segfault_sighandler(int sig, siginfo_t* siginfo, void* data) {
    fprintf(stderr, "!!!!! [survive_crash] SIGSEGV received! Dumping backtrace and terminating process.\n");
    sact_dump_backtrace();

    sleep(1000);

    // proceed with causing a core dump
    signal(sig, SIG_DFL);
    kill(getpid(), sig);
}

static void sact_sighandler(int sig, siginfo_t* siginfo, void* data) {
    fprintf(stderr, "!!!!! [survive_crash][thread:%d] "
                    "Executing sact_sighandler, for signo:%d, si_code:%d.\n",
                    my_tid(), sig, siginfo->si_code);

    // TODO carefully analyze the signal code to figure out if to exit process or attempt to kill thread and terminate actor
    // https://www.mkssoftware.com/docs/man5/siginfo_t.5.asp

    // the context:
    ucontext_t *uc = (ucontext_t *)data;

    // invoke our swift-handler, it will schedule the reaper and fail this cell
    shared_fail_cell_cb(current_fail_context,
        current_run_cell, sig, siginfo->si_code);

    // TODO: we could log a bit of a backtrace if we wanted to perhaps as well:
    // http://man7.org/linux/man-pages/man3/backtrace.3.html

    #ifdef __linux__
        uc->uc_mcontext.gregs[REG_RIP] = (greg_t)&complain_and_pause_thread;
    #elif __APPLE__
        uc->uc_mcontext->__ss.__rip = (uint64_t)&complain_and_pause_thread;
    #else
        #error platform unsupported
    #endif
}

void block_thread() {
    fprintf(stderr, "!!!!! [survive_crash][thread:%d] Blocking thread forever to prevent progressing into undefined behavior. "
           "Process remains alive.\n", my_tid());

    int fd[2] = { -1, -1 };

    pipe(fd);
    for (;;) {
        char buf;
        read(fd[0], &buf, 1);
    }
}

void kill_pthread_self() {
    // kill myself, to prevent any damage, actor will be rescheduled with .failed state and die
    pthread_exit(NULL);
}

__attribute__((noinline))
void complain_and_pause_thread(void *ctx) {
    /* manually align the stack to a 16 byte boundary. Please someone
     * knowledgeable tell me what the __attribute__ to do that is ;). */
    __asm__("subq $15, %%rsp\n"
            "movq $0xfffffffffff0, %%rsi\n"
            "andq %%rsi, %%rsp\n" ::: "sp", "si", "cc", "memory");

    block_thread();
    // kill_pthread_self(); // terminates entire process
}

void sact_set_failure_handling_threadlocal_context(void* fail_context, void* cell) {
    fprintf(stderr, "!!!!! [survive_crash][thread:%d] setting cell for handling... %d.\n",
            my_tid(), cell);

    current_fail_context = fail_context;
    current_run_cell = cell;
}

/* returns errno and sets errno appropriately, 0 on success */
int sact_install_swift_crash_handler(FailCellCallback failure_handler_swift_cb) {
//    pthread_mutex_lock(&lock);

    if (atomic_flag_test_and_set(&handler_set) == 0) {
        /* we won the race; we only set the signal handler once */

        shared_fail_cell_cb = failure_handler_swift_cb;

        struct sigaction sa = { 0 };

        sa.sa_flags = SA_ONSTACK | SA_RESTART | SA_SIGINFO;
        sa.sa_sigaction = sact_sighandler;

        int e1 = sigaction(SIGILL, &sa, NULL);
        if (e1) {
            int errno_save = errno;
            errno = errno_save;
            assert(errno_save != 0);
//            pthread_mutex_unlock(&lock);
            return errno_save;
        }

        sa.sa_flags = SA_ONSTACK | SA_RESTART | SA_SIGINFO;
        sa.sa_sigaction = sact_sighandler;

        int e2 = sigaction(SIGABRT, &sa, NULL);
        if (e2) {
            int errno_save = errno;
            errno = errno_save;
            assert(errno_save != 0);
//            pthread_mutex_unlock(&lock);
            return errno_save;
        }

        sa.sa_flags = SA_ONSTACK | SA_RESTART | SA_SIGINFO;
        sa.sa_sigaction = sact_segfault_sighandler;

        sigaction(SIGSEGV, &sa, NULL);

//        pthread_mutex_unlock(&lock);
        return 0;
    } else {
//        pthread_mutex_unlock(&lock);

        errno = EBUSY;
        return errno;
    }
}

int my_tid() {
#ifdef __APPLE__
    int thread_id = pthread_mach_thread_np(pthread_self());
    return thread_id;
#else
    // on linux
    pthread_t thread_id = pthread_self();
    return thread_id;
#endif
}
