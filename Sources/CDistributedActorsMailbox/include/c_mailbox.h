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
SWIFT_CLOSED_ENUM(MailboxRunPhase) {
    MailboxRunPhase_ProcessingSystemMessages,
    MailboxRunPhase_ProcessingUserMessages,
} MailboxRunPhase;

typedef struct {
            uint32_t  capacity;
            uint32_t  max_run_length;
    _Atomic int64_t   status;
    CMPSCLinkedQueue* system_messages;
    CMPSCLinkedQueue* messages;
} CMailbox;

/** Result of mailbox run, instructs swift part of code to perform follow up actions */
SWIFT_CLOSED_ENUM(MailboxRunResult) {
    MailboxRunResult_Close            = 0,
    MailboxRunResult_Done             = 1,
    MailboxRunResult_Reschedule       = 2,
    // failure and supervision:
    MailboxRunResult_FailureTerminate = 3,
    MailboxRunResult_FailureRestart   = 4,
    // closed status reached, never run again.
    MailboxRunResult_Closed           = 5,
} MailboxRunResult;

SWIFT_CLOSED_ENUM(MailboxEnqueueResult) {
    MailboxEnqueueResult_needsScheduling    = 0,
    MailboxEnqueueResult_alreadyScheduled   = 1,
    MailboxEnqueueResult_mailboxTerminating = 2,
    MailboxEnqueueResult_mailboxClosed      = 3,
    MailboxEnqueueResult_mailboxFull        = 4,
} MailboxEnqueueResult;

SWIFT_CLOSED_ENUM(ActorRunResult) {
    ActorRunResult_continueRunning = 0,
    ActorRunResult_shouldSuspend   = 1,
    ActorRunResult_shouldStop      = 2,
    ActorRunResult_closed          = 3,
} ActorRunResult;


typedef void InterpretMessageClosureContext;
typedef void InterpretSystemMessageClosureContext;
typedef void DropMessageClosureContext;
typedef void SupervisionClosureContext;

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
typedef ActorRunResult (*InterpretMessageCallback)(DropMessageClosureContext*, void*, void*, MailboxRunPhase);

/*
 * Callback for Swift interop.
 *
 * Drop message, when draining mailbox into dead letters.
 */
typedef void (*DropMessageCallback)(DropMessageClosureContext*, void*); // TODO rename, deadletters

/*
 * Callback for Swift interop.
 *
 * Accepts pointer to message which caused the failure.
 *
 * Invokes supervision, which may mutate the cell's behavior and return if we are to proceed with `Failure` or `FailureRestart`.
 */
typedef MailboxRunResult (*InvokeSupervisionCallback)(SupervisionClosureContext*, MailboxRunPhase, void*);

CMailbox* cmailbox_create(uint32_t capacity, uint32_t max_run_length);

/*
 * Destroy and deallocate passed in mailbox.
 */
void cmailbox_destroy(CMailbox* mailbox);

/* Returns if the actor should be scheduled for execution (or if it is already being scheduled) */
MailboxEnqueueResult cmailbox_send_message(CMailbox* mailbox, void* envelope);

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
MailboxEnqueueResult cmailbox_send_system_message(CMailbox* mailbox, void* sys_msg);

/*
 * Invoke only from a synchronously aborted or completed run.
 * The actor MUST only call this method once it can guarantee that no other messages are being enqueued to it,
 * since the tombstone MUST be the last system message an actor ever processes. This is guaranteed by first
 * entering the Terminating mailbox state.
 *
 * This call MUST be followed by scheduling this actor for execution.
 */
MailboxEnqueueResult cmailbox_send_system_tombstone(CMailbox* mailbox, void* tombstone);

/*
 * Performs a "mailbox run", during which system and user messages are reduced and applied to the current actor behavior.
 */
MailboxRunResult cmailbox_run(
    CMailbox* mailbox,
    void* cell,
    // message processing:
    InterpretMessageClosureContext* context, InterpretSystemMessageClosureContext* system_context,
    DropMessageClosureContext* dead_letter_context, DropMessageClosureContext* dead_letter_system_context,
    InterpretMessageCallback interpret_message, DropMessageCallback drop_message,
    // fault handling:
    jmp_buf* error_jmp_buf,
    SupervisionClosureContext* supervision_context, InvokeSupervisionCallback supervision_invoke,
    void** failed_message,
    MailboxRunPhase* run_phase
    );

uint32_t cmailbox_message_count(CMailbox* mailbox);

/* Sets the final CLOSED state. Should only be invoked just before finishing termination, and only while TERMINATING */
void cmailbox_set_closed(CMailbox* mailbox);

/* Sets the TERMINATING state. Should only be invoked when the actor has failed. */
void cmailbox_set_terminating(CMailbox* mailbox); // TODO naming...

int64_t sact_pthread_self();

#endif /* CMailbox_h */
