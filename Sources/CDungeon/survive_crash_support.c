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
//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018 Apple Inc. and the Swift Distributed Actors project authors
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
#include <setjmp.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>
#include <sys/types.h>
#include <sys/ucontext.h>
#include <unistd.h>

#include "include/survive_crash_support.h"
#include "include/crash_support.h"

void sact_complain_and_pause_thread(void* ctx);
/** Return current (p)Thread ID*/
int sact_my_tid();

// we assume that setting the signal handler once for our application does the job.
static atomic_flag handler_set = ATOMIC_FLAG_INIT;

// Thread local containing the ActorCell and failure handling logic, implemented in Swift.
//
// Each executing actor sets this value for the duration of its mailbox run.
// if NULL, it means we captured a signal while NOT in the context of an actor and should NOT attempt to handle it.
static _Thread_local bool tl_fault_handling_enabled = false;

static _Thread_local jmp_buf error_jmp_buf;

static _Thread_local CCrashDetails* crash_details = NULL;

pthread_mutex_t lock;

jmp_buf* sact_get_error_jmp_buf() {
    return &error_jmp_buf;
}

CCrashDetails* sact_get_crash_details() {
    return crash_details;
}

void sact_unrecoverable_sighandler(int sig, siginfo_t* siginfo, void* data) {
    char* sig_name = "";
    if (sig == SIGSEGV) sig_name = "SIGSEGV";
    else if (sig == SIGBUS) sig_name = "SIGBUS";

    fprintf(stderr, "Unrecoverable signal %s(%d) received! Dumping backtrace and terminating process.\n", sig_name, sig);
    sact_dump_backtrace();

    // proceed with causing a core dump
    signal(sig, SIG_DFL);
    kill(getpid(), sig);
}

static void sact_sighandler(int sig, siginfo_t* siginfo, void* data) {
    #ifdef SACT_TRACE_CRASH
    fprintf(stderr, "[SACT_TRACE_CRASH][thread:%d] "
                    "Executing sact_sighandler for signo:%d, si_code:%d.\n",
                    sact_my_tid(), sig, siginfo->si_code);
    #endif

    if (!tl_fault_handling_enabled) {
        // fault happened outside of a fault handling actor, we MUST NOT handle it!
        #ifdef SACT_TRACE_CRASH
        fprintf(stderr, "[SACT_TRACE_CRASH][thread:%d] Thread is not executing an actor. Applying default signal handling.\n", sact_my_tid());
        #endif
        signal(sig, SIG_DFL);
        kill(getpid(), sig);
        return;
    }

    // TODO: carefully analyze the signal code to figure out if to exit process or attempt to kill thread and terminate actor
    // https://www.mkssoftware.com/docs/man5/siginfo_t.5.asp

    char** frames;
    int frame_count = sact_get_backtrace(&frames);

    // TODO(ktoso): safety wise perhaps better to keep some preallocated space for crash details
    crash_details = malloc(sizeof(CCrashDetails));
    crash_details->backtrace = frames;
    crash_details->backtrace_length = frame_count;

    // we are jumping back to the mailbox to properly handle the crash and kill the actor
    siglongjmp(error_jmp_buf, 1);
}

// TODO(ktoso): This is not currently used as we jump to fault handling rather than halting a thread
void block_thread() {
    fprintf(stderr, "[ERROR][SACT_CRASH][thread:%d] Blocking thread forever to prevent progressing into undefined behavior. "
           "Process remains alive.\n", sact_my_tid());

    int fd[2] = { -1, -1 };

    pipe(fd);
    for (;;) {
        char buf;
        read(fd[0], &buf, 1);
    }
}

void sact_kill_pthread_self() {
    // kill myself, to prevent any damage, actor will be rescheduled with .failed state and die
    pthread_exit(NULL);
}

__attribute__((noinline))
void sact_complain_and_pause_thread(void* ctx) {
    /* manually align the stack to a 16 byte boundary. Please someone
     * knowledgeable tell me what the __attribute__ to do that is ;). */
    __asm__("subq $15, %%rsp\n"
            "movq $0xfffffffffff0, %%rsi\n"
            "andq %%rsi, %%rsp\n" ::: "sp", "si", "cc", "memory");

    block_thread();
    // kill_pthread_self(); // terminates entire process
}

void sact_enable_fault_handling() {
    tl_fault_handling_enabled = true;
}

void sact_disable_fault_handling() {
    tl_fault_handling_enabled = false;
}

/* returns errno and sets errno appropriately, 0 on success */
int sact_install_swift_crash_handler() {
    pthread_mutex_lock(&lock); // TODO not really used?

    if (atomic_flag_test_and_set(&handler_set) == 0) {
        /* we won the race; we only set the signal handler once */

        struct sigaction sa = { 0 };

        sa.sa_flags = SA_ONSTACK | SA_RESTART | SA_SIGINFO;
        sa.sa_sigaction = sact_sighandler;

        int e1 = sigaction(SIGILL, &sa, NULL);
        if (e1) {
            int errno_save = errno;
            errno = errno_save;
            assert(errno_save != 0);
            pthread_mutex_unlock(&lock);
            return errno_save;
        }

        sa.sa_flags = SA_ONSTACK | SA_RESTART | SA_SIGINFO;
        sa.sa_sigaction = sact_sighandler;

        int e2 = sigaction(SIGABRT, &sa, NULL);
        if (e2) {
            int errno_save = errno;
            errno = errno_save;
            assert(errno_save != 0);
            pthread_mutex_unlock(&lock);
            return errno_save;
        }

        // handlers for unrecoverable signals, for better stacktraces:
        // TODO provide option to skip installing those

        sa.sa_flags = SA_ONSTACK | SA_RESTART | SA_SIGINFO;
        sa.sa_sigaction = sact_unrecoverable_sighandler;
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS, &sa, NULL);

        pthread_mutex_unlock(&lock);
        return 0;
    } else {
        pthread_mutex_unlock(&lock);

        errno = EBUSY;
        return errno;
    }
}

int sact_my_tid() {
#ifdef __APPLE__
    int thread_id = pthread_mach_thread_np(pthread_self());
    return thread_id;
#else
    // on linux
    pthread_t thread_id = pthread_self();
    return thread_id;
#endif
}
