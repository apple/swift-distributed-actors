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

typedef enum {
    UNSET = 0,
    SETTING = 1,
    SET = 2,
} SignalHandlerStatus;

// we assume that setting the signal handler once for our application does the job.
static _Atomic SignalHandlerStatus handler_status = ATOMIC_VAR_INIT(UNSET);


// Each executing actor sets this value for the duration of its mailbox run.
// If `false`, it means we captured a signal while NOT in the context of an actor and should NOT attempt to handle it.
static _Thread_local bool tl_fault_handling_enabled = false;

static _Thread_local jmp_buf error_jmp_buf;

static _Thread_local CSActCrashDetails* tl_crash_details = NULL;

jmp_buf* sact_get_error_jmp_buf() {
    return &error_jmp_buf;
}

CSActCrashDetails* sact_get_crash_details() {
    return tl_crash_details;
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

        // Only print backtrace when we are on APPLE platform, or running
        // a release build. On Linux in debug mode a backtrace will
        // already be printed by the runtime
        #if !defined(DEBUG) || defined(__APPLE__)
        sact_dump_backtrace();
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
    tl_crash_details = malloc(sizeof(CSActCrashDetails));
    tl_crash_details->backtrace = frames;
    tl_crash_details->backtrace_length = frame_count;
    // crash_details->run_phase = ; // TODO have to set it right here

    // we are jumping back to the mailbox to properly handle the crash and kill the actor
    siglongjmp(error_jmp_buf, 1);
}

void sact_enable_fault_handling() {
    tl_fault_handling_enabled = true;
}

void sact_disable_fault_handling() {
    if (tl_crash_details) {
        free(tl_crash_details->backtrace);
        free(tl_crash_details);
        tl_crash_details = NULL;
    }
    tl_fault_handling_enabled = false;
}

/* returns errno and sets errno appropriately, 0 on success */
int sact_install_swift_crash_handler() {
    SignalHandlerStatus status = UNSET;
    if (atomic_compare_exchange_strong(&handler_status, &status, SETTING)) {
        /* we won the race; we only set the signal handler once */

        struct sigaction sa = { 0 };

        sa.sa_flags = SA_ONSTACK | SA_RESTART | SA_SIGINFO;
        sa.sa_sigaction = sact_sighandler;

        int e1 = sigaction(SIGILL, &sa, NULL);
        if (e1) {
            int errno_save = errno;
            errno = errno_save;
            assert(errno_save != 0);
            return errno_save;
        }

        sa.sa_flags = SA_ONSTACK | SA_RESTART | SA_SIGINFO;
        sa.sa_sigaction = sact_sighandler;

        int e2 = sigaction(SIGABRT, &sa, NULL);
        if (e2) {
            int errno_save = errno;
            errno = errno_save;
            assert(errno_save != 0);
            return errno_save;
        }

        // handlers for unrecoverable signals, for better stacktraces:
        // TODO provide option to skip installing those

        sa.sa_flags = SA_ONSTACK | SA_RESTART | SA_SIGINFO;
        sa.sa_sigaction = sact_unrecoverable_sighandler;
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS, &sa, NULL);
        atomic_store_explicit(&handler_status, SET, memory_order_release);
    } else {
        while (status != SET) {
            status = atomic_load_explicit(&handler_status, memory_order_acquire);
            // wait for handler to be set
        }
    }

    return 0;
}
