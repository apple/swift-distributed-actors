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

#include <math.h>
#include <stdio.h>

#include "CMailbox.h"

// Implementation notes:
// State should be operated on bitwise; where the specific bits signify states like the following:
// 0 - 29 - activation count
//     30 - terminating (or terminated)
//     31 - terminated (for sure)
// Activation count is special in the sense that we use it as follows, it's value being:
// 0 - inactive, not scheduled and no messages to process
// 1 - active without(!) normal messages, only system messages are to be processed
// n - there are (n >> 1) messages to process + system messages if LSB is set
//
// Note that this implementation allows, using one load, to know: if the actor is running right now (so
// the mailbox size will be decremented shortly), if we need to schedule it or not since it was scheduled already etc.

#define ACTIVATIONS 0b00111111111111111111111111111111
#define TERMINATING 0b01000000000000000000000000000000
#define TERMINATED  0b10000000000000000000000000000000

int64_t increment_status_activations(CMailbox* mailbox);
int64_t decrement_status_activations(CMailbox* mailbox, int64_t n);
int64_t try_activate(CMailbox* mailbox);
int64_t activations(int64_t status);
int64_t message_count(int64_t status);
bool is_active(int64_t status);
bool has_system_messages(int64_t status);
bool is_terminating(int64_t status);
bool is_terminated(int64_t status);
bool internal_send_message(CMailbox* mailbox, void* envelope, bool is_system_message);

CMailbox* cmailbox_create(int64_t capacity) {
  CMailbox* mailbox = calloc(sizeof(CMailbox), 1);
  mailbox->capacity = capacity;
  mailbox->messages = cmpsc_linked_queue_create();
  mailbox->system_messages = cmpsc_linked_queue_create();

  return mailbox;
}

void cmailbox_destroy(CMailbox* mailbox) {
  free(mailbox);
}

bool cmailbox_send_message(CMailbox* mailbox, void* envelope) {
  return internal_send_message(mailbox, envelope, false);
}

bool cmailbox_send_system_message(CMailbox* mailbox, void* envelope) {
  return internal_send_message(mailbox, envelope, true);
}

bool internal_send_message(CMailbox* mailbox, void* envelope, bool is_system_message) {
  int old_status = is_system_message ? try_activate(mailbox) : increment_status_activations(mailbox);
  int old_activations = activations(old_status);
  CMPSCLinkedQueue* queue = is_system_message ? mailbox->system_messages : mailbox->messages;

  if ((!is_system_message && (old_activations > mailbox->capacity)) || is_terminating(old_status)) {
    // If we passed the maximum capacity of the user queue, we can't enqueue more
    // items and have to decrement the activations count again. This is not racy,
    // because we only process messages if the queue actually contains them (does
    // not return NULL), so even if messages get processed concurrently, it's safe
    // to decrement here.
    decrement_status_activations(mailbox, 2);
    return false;
  } else {
    // If the mailbox is not full, or we enqueue a system message, we insert it
    // into the queue and return whether this was the first activation, to signal
    // the need to enqueue this mailbox.
    cmpsc_linked_queue_enqueue(queue, envelope);
    return old_activations == 0;
  }
}

bool cmailbox_run(CMailbox* mailbox, void* context, void* system_context, InterpretMessageCallback interpret_message) {
  int64_t status = atomic_load_explicit(&mailbox->status, memory_order_acquire);

  if (!is_active(status)) {
    return false;
  }

  //printf("Processing...\n");

  int64_t processed = 0;
  // TODO: pass maximum in as parameter to allow for more elaborate,
  // metrics based scheduling decisions
  int64_t max_run_length = message_count(status);
  if (max_run_length > 1) {
    max_run_length = 1;
  }

  if (has_system_messages(status)) {
    //printf("Has system message\n");
    processed = 1;
    void* system_message = cmpsc_linked_queue_dequeue(mailbox->system_messages);
    while (system_message != NULL) {
      //printf("Procesing system message...\n");
      interpret_message(system_context, system_message);
      system_message = cmpsc_linked_queue_dequeue(mailbox->system_messages);
    }
  }

  void* message = cmpsc_linked_queue_dequeue(mailbox->messages);
  while (message != NULL) {
    // we need to add 2 to processed because the user message count is stored
    // shifted by 1 in the status and we use the same field to clear the
    // system message bit
    processed += 2;
    //printf("Procesing user message...\n");
    interpret_message(context, message);

    if (processed >= max_run_length) {
      // if the maximum run length is reached, set message to
      // NULL to break out of the loop
      message = NULL;
    } else {
      // dequeue another message, if there are no more messages left, message
      // will contain NULL and terminate the loop
      message = cmpsc_linked_queue_dequeue(mailbox->messages);
    }
  }

  //printf("Processed %lld messages...\n", processed);

  int64_t old_status = decrement_status_activations(mailbox, processed);

  int64_t old_activations = activations(old_status);
  //printf("Old: %lld, processed: %lld\n", old_activations, processed);

  if (old_activations == processed &&
      !cmpsc_linked_queue_is_empty(mailbox->system_messages) &&
      activations(try_activate(mailbox)) == 0) {
    // If we processed all messages (including system messages) that have been
    // present when we started to process messages and there are new system
    // messages in the queue, but the mailbox has not been re-scheduled yet
    // return true to signal the queue should be re-scheduled
    return true;
  } else if (old_activations > processed) {
    // if we could not process all messages in this run, because we had more
    // messages queued up than the maximum run length, return true to signal
    // the queue should be re-scheduled

    //printf("More messages, enqueuing again...\n");
    return true;
  }

  //printf("Done processing...\n");
  return false;
}

int64_t try_activate(CMailbox* mailbox) {
  return atomic_fetch_or_explicit(&mailbox->status, 1, memory_order_acq_rel);
}

int64_t increment_status_activations(CMailbox* mailbox) {
  return atomic_fetch_add_explicit(&mailbox->status, 2, memory_order_acq_rel);
}

int64_t decrement_status_activations(CMailbox* mailbox, int64_t n) {
  return atomic_fetch_sub_explicit(&mailbox->status, n, memory_order_acq_rel);
}

bool has_system_messages(int64_t status) {
  return (status & 1) == 1;
}

bool is_active(int64_t status) {
  return (status & ACTIVATIONS) != 0;
}

int64_t activations(int64_t status) {
  return status & ACTIVATIONS;
}

int64_t message_count(int64_t status) {
  int count = activations(status) >> 1;
  return count > 0 ? count : 0;
}

bool is_terminating(int64_t status) {
  return (status & TERMINATING) == TERMINATING;
}

bool is_terminated(int64_t status) {
  return (status & TERMINATED) == TERMINATED;
}
