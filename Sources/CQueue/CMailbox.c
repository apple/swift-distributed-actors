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

#include <math.h>
#include <stdio.h>
#include <pthread.h>
#include <execinfo.h>

// TODO: getting better code completion this way... works ok in xcode and friends this way too?
//#include "CMailbox.h"
#include "include/CMailbox.h"
#include "include/itoa.h"

// Implementation notes:
// State should be operated on bitwise; where the specific bits signify states like the following:
//      0 - has system messages
//      1 - currently processing system messages
//   2-61 - user message count
//     62 - terminating (or closed)
//     63 - closed, terminated (for sure)
// Activation count is special in the sense that we use it as follows, it's value being:
// 0 - inactive, not scheduled and no messages to process
// 1 - active without(!) normal messages, only system messages are to be processed
// n - there are (n >> 1) messages to process + system messages if LSB is set
//
// Note that this implementation allows, using one load, to know:
// - if the actor is running right now (so the mailbox size will be decremented shortly),
// - current mailbox size (nr. of enqueued messages, which can be used for scheduling and/or metrics)
// - if we need to schedule it or not since it was scheduled already etc.

#define ACTIVATIONS                 0b0011111111111111111111111111111111111111111111111111111111111111

// Implementation notes about Termination:
// Termination MUST first set TERMINATING and only after add the "final" CLOSED state.
// In other words, the only legal bit states a mailbox should observe are:
//  - 0b00.. alive,
//  -> 0b01.. terminating,
//  -> 0b11.. closed (terminated, dead.)
// Meaning that `10` is NOT legal.
#define TERMINATING                 0b0100000000000000000000000000000000000000000000000000000000000000
#define CLOSED                      0b1000000000000000000000000000000000000000000000000000000000000000
#define HAS_SYSTEM_MESSAGES         0b0000000000000000000000000000000000000000000000000000000000000001
#define PROCESSING_SYSTEM_MESSAGES  0b0000000000000000000000000000000000000000000000000000000000000010

// Mask to use with XOR on the status to unset the 'has system messages' bit
// and set the 'is processing system messages' bit in a single atomic operation
#define BECOME_SYS_MSG_PROCESSING_XOR_MASK 0b11

// user message count is store in bits 2-61, so when incrementing or
// decrementing the message count, we need to add starting at bit 2
#define SINGLE_USER_MESSAGE_MASK 0b100

int64_t increment_status_activations(CMailbox* mailbox);

int64_t decrement_status_activations(CMailbox* mailbox, int64_t n);

int64_t try_activate(CMailbox* mailbox);

int64_t activations(int64_t status);

int64_t message_count(int64_t status);

int64_t set_status_terminating(CMailbox* mailbox);

int64_t set_status_terminated_dead(CMailbox* mailbox);

int64_t set_processing_system_messages(CMailbox* mailbox);


void print_debug_status(CMailbox* mailbox, char* msg);

int64_t get_status(CMailbox* mailbox);

bool has_activations(int64_t status);

bool has_system_messages(int64_t status);

bool is_terminating(int64_t status);
bool is_not_terminating(int64_t status);

bool is_closed(int64_t status);

bool internal_send_message(CMailbox* mailbox, void* envelope, bool is_system_message);

int64_t max(int64_t a, int64_t b);


CMailbox* cmailbox_create(int64_t capacity, int64_t max_run_length) {
    CMailbox* mailbox = calloc(sizeof(CMailbox), 1);
    mailbox->capacity = capacity;
    mailbox->max_run_length = max_run_length;
    mailbox->messages = cmpsc_linked_queue_create();
    mailbox->system_messages = cmpsc_linked_queue_create();

    return mailbox;
}

void cmailbox_destroy(CMailbox* mailbox) {
    free(mailbox);
}

bool cmailbox_send_message(CMailbox* mailbox, void* envelope) {
    int64_t old_status = increment_status_activations(mailbox);
    int64_t old_activations = activations(old_status);
    CMPSCLinkedQueue* queue = mailbox->messages;
    // printf("[SACT_TRACE_MAILBOX][c] enter send_message; messages in queue: %lu\n", (message_count(old_status)));

    if ((message_count(old_status) >= mailbox->capacity) || is_terminating(old_status)) {
        // If we passed the maximum capacity of the user queue, we can't enqueue more
        // items and have to decrement the activations count again. This is not racy,
        // because we only process messages if the queue actually contains them (does
        // not return NULL), so even if messages get processed concurrently, it's safe
        // to decrement here.
        decrement_status_activations(mailbox, SINGLE_USER_MESSAGE_MASK);
        print_debug_status(mailbox, "cmailbox_send_message dropping... ");
        // TODO: emit the message as ".dropped(msg)"
        return false;
    } else {
        // If the mailbox is not full, we insert it into the queue and return,
        // whether this was the first activation, to signal the need to enqueue
        // this mailbox.
        cmpsc_linked_queue_enqueue(queue, envelope);
        print_debug_status(mailbox, "cmailbox_send_message enqueued ");

        return old_activations == 0;
    }
}

int cmailbox_send_system_message(CMailbox* mailbox, void* envelope) {
    CMPSCLinkedQueue* queue = mailbox->system_messages;
    cmpsc_linked_queue_enqueue(queue, envelope);

    // printf("[SACT_TRACE_MAILBOX][c] send_system_message: \n");

    int64_t old_status = try_activate(mailbox); // only activation matters
    int64_t old_activations = activations(old_status);

    // if (is_terminating(old_status)) {
    if (is_closed(old_status)) {
        // since we are terminated, we are already dropping all messages, including this one!
        // TODO: emit the message as ".dropped(msg)" here (nowadays we handle this in the outside, via the -1 return code here)
        print_debug_status(mailbox, "cmailbox_send_system_message mailbox closed ");
        return -1;
    } else {
        print_debug_status(mailbox, "cmailbox_send_system_message enqueued ");
        return old_activations;
    }
}

// TODO: was boolean for need to schedule, but we need to signal to swift that termination things should now happen
// and we may only do this AFTER the cmailbox has set the status to terminating, otherwise we get races on insertion to queues...
CMailboxRunResult cmailbox_run(CMailbox* mailbox,
                  void* context, void* system_context,
                  void* dead_letter_context, void* dead_letter_system_context,
                  InterpretMessageCallback interpret_message, DropMessageCallback drop_message,
                  jmp_buf* error_jmp_buf) {
    print_debug_status(mailbox, "Entering run");

    int64_t status = set_processing_system_messages(mailbox);

    int64_t processed_activations = has_system_messages(status) ? 0b10 : 0;
    // TODO: more smart scheduling decisions (smart batching), though likely better on dispatcher layer
    int64_t run_length = max(message_count(status), mailbox->max_run_length);

    // printf("[SACT_TRACE_MAILBOX][c] run_length = %lu\n", run_length);

    // only an keep_running actor shall continue running;
    // e.g. once .terminate is received, the actor should drain all messages to the dead letters queue
    bool keep_running = true; // TODO: hijack the run_length, and reformulate it as "fuel", and set it to zero when we need to stop

    if (setjmp(*error_jmp_buf)) {
        printf("++++++======++++++++ ERROROROROROROROOR +++++====++++====");
        void* callstack[128];
        int i, frames = backtrace(callstack, 128);
        char** strs = backtrace_symbols(callstack, frames);
        for (i = 0; i < frames; ++i) {
            fprintf(stderr, "%s\n", strs[i]);
        }
        //exit(-1);
        cmailbox_set_closed(mailbox);
        return -1;
    } else {

        // run system messages ------
        if (has_system_messages(status)) {
            void* system_message = cmpsc_linked_queue_dequeue(mailbox->system_messages);

            while (system_message != NULL && keep_running) {
                // printf("[SACT_TRACE_MAILBOX][c] Processing system message...\n");
                keep_running = interpret_message(system_context, system_message);
                system_message = cmpsc_linked_queue_dequeue(mailbox->system_messages);
            }

            // was our run was interrupted by a system message causing termination?
            if (!keep_running) {

                if (is_not_terminating(status)) { // avoid unnecessarily setting the terminating bit again
                    print_debug_status(mailbox, "before set TERMINATING");
                    set_status_terminating(mailbox);
                    print_debug_status(mailbox, "after set TERMINATING");
                }

                // Since we are terminating, and bailed out from a system run, there may be
                // pending system messages in the queue still; we want to finish this run till they are drained.
                //
                // Never run user messages before draining system messages, system messages must be processed with priority,
                // since they include setting up watch/unwatch as well as the tombstone which should be the last thing we process.
                if (system_message == NULL) {
                    system_message = cmpsc_linked_queue_dequeue(mailbox->system_messages);
                }
                while (system_message != NULL) {
                    print_debug_status(mailbox, "CLOSED, yet pending system messages still made it in... draining...");
                    // drain all messages to dead letters
                    // this is very important since dead letters will handle any posthumous watches for us
                    drop_message(dead_letter_system_context, system_message);

                    system_message = cmpsc_linked_queue_dequeue(mailbox->system_messages);
                }
            }
        }
        // end of system messages run ------

        // while a run shall handle system messages while terminating,
        // it should NOT handle user messages while terminating:
        keep_running = keep_running && !is_terminating(status);

        // run user messages ------

        if (keep_running) {
            void* message = cmpsc_linked_queue_dequeue(mailbox->messages);
            while (message != NULL && keep_running) {
                // we need to add 2 to processed_activations because the user message count is stored
                // shifted by 1 in the status and we use the same field to clear the
                // system message bit
            processed_activations += SINGLE_USER_MESSAGE_MASK;
                // printf("[SACT_TRACE_MAILBOX][c] Processing user message...\n");
                // TODO: fix this dance
                bool still_alive = interpret_message(context, message); // TODO: we can optimize the keep_running into the processed counter?
                keep_running = still_alive;

                // TODO: optimize all this branching into riding on the processed_activations perhaps? we'll see later on -- ktoso
                if (keep_running == false && !is_terminating(status)) {
                    // printf("[SACT_TRACE_MAILBOX][c] STOPPING BASED ON MESSAGE INTERPRETATION\n");
                    set_status_terminating(mailbox);
                    print_debug_status(mailbox, "MARKED TERMINATING");
                    message = NULL; // break out of the loop
                } else if (processed_activations >= run_length) {
                    message = NULL; // break out of the loop
                } else {
                    // dequeue another message, if there are no more messages left, message
                    // will contain NULL and terminate the loop
                    message = cmpsc_linked_queue_dequeue(mailbox->messages);
                }
            }
        } else /* we are terminating and need to drain messages */ {
            // TODO: drain them to dead letters

            // TODO: drainToDeadLetters(mailbox->messages) {
            void* message = cmpsc_linked_queue_dequeue(mailbox->messages);
            while (message != NULL) {
                drop_message(dead_letter_context, message);
            processed_activations += SINGLE_USER_MESSAGE_MASK;
                message = cmpsc_linked_queue_dequeue(mailbox->messages); // keep draining
            }
        }

        // printf("[SACT_TRACE_MAILBOX][c] ProcessedActivations %lu messages...\n", processed_activations);

        int64_t old_status = decrement_status_activations(mailbox, processed_activations);
        int64_t old_activations = activations(old_status);
        // printf("[SACT_TRACE_MAILBOX][c] Old: %lu, processed_activations: %lu\n", old_activations, processed_activations);
        print_debug_status(mailbox, "Run complete...");

        if (old_activations == processed_activations && // processed everything
            cmpsc_linked_queue_non_empty(mailbox->system_messages) && // but pending system messages it seems
            activations(try_activate(mailbox)) == 0) { // need to activate again (mark that we have system messages)
            // If we processed_activations all messages (including system messages) that have been
            // present when we started to process messages and there are new system
            // messages in the queue, but the mailbox has not been re-scheduled yet
            // return true to signal the queue should be re-scheduled
            print_debug_status(mailbox, "Run complete, shouldReschedule:true, pending system messages\n");
            return Reschedule;
        } else if (old_activations > processed_activations) {
            // if we could not process all messages in this run, because we had more
            // messages queued up than the maximum run length, return true to signal
            // the queue should be re-scheduled

            char msg[300];
            snprintf(msg, 300, "Run complete, shouldReschedule:true; %lld > %lld ", old_activations, processed_activations);
            print_debug_status(mailbox, msg);
            return Reschedule;
        } else if (!keep_running) {
            print_debug_status(mailbox, "terminating, notifying swift mailbox...");
            return Close;
        } else {
            print_debug_status(mailbox, "Run complete, shouldReschedule:false ");
            return Done;
        }
    }
}

int64_t cmailbox_message_count(CMailbox* mailbox) {
    return message_count(get_status(mailbox));
}

void print_debug_status(CMailbox* mailbox, char* msg) {
    #ifdef SACT_TRACE_MAILBOX
    int64_t status = atomic_load_explicit(&mailbox->status, memory_order_acquire);

    char buffer[33];
    itoa(status, buffer, 2);

    #ifdef __APPLE__
    int thread_id = pthread_mach_thread_np(pthread_self());
    #else
    // on linux
    pthread_t thread_id = pthread_self();
    #endif

    printf("[SACT_TRACE_MAILBOX][c]"
           "[thread:%d] "
           "%s "
           "Status now: [%lld, bin:%s], "
           "has_sys_msgs:%s, "
           "msgs:%lld, "
           "terminating:%s, "
           "closed:%s"
           "\n",
           thread_id,
           msg,
           status, buffer,
           has_system_messages(status) ? "Y" : "N",
           message_count(status),
           is_terminating(status) ? "Y" : "N",
           is_closed(status) ? "Y" : "N"
    );
    #endif
}

int64_t get_status(CMailbox* mailbox) {
    return atomic_load_explicit(&mailbox->status, memory_order_acquire);
}

int64_t try_activate(CMailbox* mailbox) {
    return atomic_fetch_or_explicit(&mailbox->status, 1, memory_order_acq_rel);
}

// TODO: this is more like increment message count
int64_t increment_status_activations(CMailbox* mailbox) {
    return atomic_fetch_add_explicit(&mailbox->status, SINGLE_USER_MESSAGE_MASK, memory_order_acq_rel);
}

int64_t decrement_status_activations(CMailbox* mailbox, int64_t n) {
    return atomic_fetch_sub_explicit(&mailbox->status, n, memory_order_acq_rel);
}

int64_t set_status_terminating(CMailbox* mailbox) {
    // printf("[SACT_TRACE_MAILBOX][c] Setting TERMINATING marker.\n");
    return atomic_fetch_or_explicit(&mailbox->status, TERMINATING, memory_order_acq_rel);
}

int64_t set_status_closed(CMailbox* mailbox) {
     return atomic_fetch_or_explicit(&mailbox->status, CLOSED, memory_order_acq_rel);
}

// Checks if the 'has system messages' bit is set and if it is, unsets it and
// sets the 'is processing system messages' bit in one atomic operation. This is
// necessary to not race between unsetting the bit at the end of a run while
// another thread is enqueueing a new system message.
int64_t set_processing_system_messages(CMailbox* mailbox) {
    int64_t status = atomic_load_explicit(&mailbox->status, memory_order_acquire);
    if (has_system_messages(status)) {
        status = atomic_fetch_xor_explicit(&mailbox->status, BECOME_SYS_MSG_PROCESSING_XOR_MASK, memory_order_acq_rel);
    }

    return status;
}

bool has_system_messages(int64_t status) {
    return (status & HAS_SYSTEM_MESSAGES) == HAS_SYSTEM_MESSAGES;
}

bool has_activations(int64_t status) {
    return (status & ACTIVATIONS) != 0;
}

int64_t activations(int64_t status) {
    return status & ACTIVATIONS;
}

int64_t message_count(int64_t status) {
    int64_t count = activations(status) >> 2;
    return count > 0 ? count : 0;
}

bool cmailbox_is_closed(CMailbox* mailbox) {
    int64_t status = atomic_load_explicit(&mailbox->status, memory_order_acquire);
    return is_terminating(status);
}

void cmailbox_set_closed(CMailbox* mailbox) {
    set_status_closed(mailbox);
}

// can be invoked by the cell itself if it fails
void cmailbox_set_terminating(CMailbox* mailbox) {
    set_status_terminating(mailbox);
}

bool is_terminating(int64_t status) {
    return (status & TERMINATING) != 0;
}
bool is_not_terminating(int64_t status) {
    return (status & TERMINATING) == 0;
}

bool is_closed(int64_t status) {
    return (status & CLOSED) != 0;
}

int64_t max(int64_t a, int64_t b) {
    return a > b ? b : a;
}
