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

#ifndef CMailbox_h
#define CMailbox_h

#include <setjmp.h>
#include <stdatomic.h>
#include <stdbool.h>

#include "swift_interop.h"
#include "c_mpsc_linked_queue.h"

// Implementation note regarding Swift-and-C inter-op for the enums:
// By defining the cases using such prefix they get imported as `.close` into Swift,
// without the prefix they end up as `.Close`. The prefix also avoids name collisions in C.

/** Used to mark in which phase of a mailbox run we are currently in. */
SWIFT_CLOSED_ENUM(SActMailboxRunPhase) {
    SActMailboxRunPhase_ProcessingSystemMessages,
    SActMailboxRunPhase_ProcessingUserMessages,
} SActMailboxRunPhase;

typedef struct {
            uint32_t      capacity;
            uint32_t      max_run_length;
    _Atomic int64_t       status;
    CSActMPSCLinkedQueue* system_messages;
    CSActMPSCLinkedQueue* messages;
} CSActMailbox;

/** Result of mailbox run, instructs swift part of code to perform follow up actions */
SWIFT_CLOSED_ENUM(SActMailboxRunResult) {
    SActMailboxRunResult_Close            = 0,
    SActMailboxRunResult_Done             = 1,
    SActMailboxRunResult_Reschedule       = 2,
    // failure and supervision:
    SActMailboxRunResult_FailureTerminate = 3,
    SActMailboxRunResult_FailureRestart   = 4,
    // closed status reached, never run again.
    SActMailboxRunResult_Closed           = 5,
} SActMailboxRunResult;

SWIFT_CLOSED_ENUM(SActMailboxEnqueueResult) {
    SActMailboxEnqueueResult_needsScheduling    = 0,
    SActMailboxEnqueueResult_alreadyScheduled   = 1,
    SActMailboxEnqueueResult_mailboxTerminating = 2,
    SActMailboxEnqueueResult_mailboxClosed      = 3,
    SActMailboxEnqueueResult_mailboxFull        = 4,
} SActMailboxEnqueueResult;

SWIFT_CLOSED_ENUM(SActActorRunResult) {
    SActActorRunResult_continueRunning = 0,
    SActActorRunResult_shouldSuspend   = 1,
    SActActorRunResult_shouldStop      = 2,
    SActActorRunResult_closed          = 3,
} SActActorRunResult;


typedef void *SActInterpretMessageClosureContext;
typedef void *SActInterpretSystemMessageClosureContext;
typedef void *SActDropMessageClosureContext;
typedef void *SActSupervisionClosureContext;

/*
 * Callback for Swift interop.
 *
 * Accepts a context and message pointer.
 *
 * Returns `true` while the resulting behavior is not terminating,
 * once a message interpretation returns `false` it should be assumed
 * that the actor is terminating, and messages should be drained into
 * deadLetters.
 */
typedef SActActorRunResult (*SActInterpretMessageCallback)(SActDropMessageClosureContext, void*, void*, SActMailboxRunPhase);

/*
 * Callback for Swift interop.
 *
 * Drop message, when draining mailbox into dead letters.
 */
typedef void (*SActDropMessageCallback)(SActDropMessageClosureContext, void*); // TODO rename, deadletters

CSActMailbox* cmailbox_create(uint32_t capacity, uint32_t max_run_length);

/*
 * Destroy and deallocate passed in mailbox.
 */
void cmailbox_destroy(CSActMailbox* mailbox);

/* Returns if the actor should be scheduled for execution (or if it is already being scheduled) */
SActMailboxEnqueueResult cmailbox_send_message(CSActMailbox* mailbox, void* envelope);

/*
 * Returns if the actor should be scheduled for execution (or if it is already being scheduled)
 *
 * System messages MUST NEVER be "dropped" yet they may be piped to dead letters (though with great care).
 *
 * The system queue will ONLY reject enqueueing if the enclosing mailbox is CLOSED.
 * Even a Terminating mailbox will still accept enqueues to its system queue -- this is in order to support,
 * enqueueing the `tombstone` system message, which is used as terminal marker that all system messages are either
 * properly processed OR piped directly to dead letters.
 */
SActMailboxEnqueueResult cmailbox_send_system_message(CSActMailbox* mailbox, void* sys_msg);

/*
 * Invoke only from a synchronously aborted or completed run.
 * The actor MUST only call this method once it can guarantee that no other messages are being enqueued to it,
 * since the tombstone MUST be the last system message an actor ever processes. This is guaranteed by first
 * entering the Terminating mailbox state.
 *
 * This call MUST be followed by scheduling this actor for execution.
 */
SActMailboxEnqueueResult cmailbox_send_system_tombstone(CSActMailbox* mailbox, void* tombstone);

/*
 * Performs a "mailbox run", during which system and user messages are reduced and applied to the current actor behavior.
 */
SActMailboxRunResult cmailbox_run(
    CSActMailbox* mailbox,
    void* cell,
    // message processing:
    SActInterpretMessageClosureContext context, SActInterpretSystemMessageClosureContext system_context,
    SActDropMessageClosureContext dead_letter_context, SActDropMessageClosureContext dead_letter_system_context,
    SActInterpretMessageCallback interpret_message, SActDropMessageCallback drop_message,
    SActMailboxRunPhase* run_phase
    );

uint32_t cmailbox_message_count(CSActMailbox* mailbox);

/* Sets the final CLOSED state. Should only be invoked just before finishing termination, and only while TERMINATING */
void cmailbox_set_closed(CSActMailbox* mailbox);

/* Sets the TERMINATING state. Should only be invoked when the actor has failed. */
void cmailbox_set_terminating(CSActMailbox* mailbox); // TODO naming...

int64_t sact_pthread_self();

#endif /* CMailbox_h */
