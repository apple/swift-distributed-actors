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

#define ACTIVATIONS 0b00111111111111111111111111111111
#define TERMINATING 0b01000000000000000000000000000000
#define TERMINATED 0b10000000000000000000000000000000

int64_t increment_status_activations(CMailbox* mailbox);
int64_t decrement_status_activations(CMailbox* mailbox, int64_t n);
bool is_active(int64_t status);
bool has_any_messages(int64_t status);
int64_t activations(int64_t status);
int64_t message_count(int64_t status);
bool is_terminating(int64_t status);
bool is_terminated(int64_t status);
bool internal_send_message(CMailbox* mailbox, void* envelope, bool is_system_message);
bool try_activate(CMailbox* mailbox);

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
    decrement_status_activations(mailbox, 2);
    return false;
  } else {
    cmpsc_linked_queue_enqueue(queue, envelope);
    return old_activations == 0;
  }
}

bool cmailbox_run(CMailbox* mailbox, void* context, void* system_context, RunMessageCallback callback) {
  int64_t status = atomic_load_explicit(&mailbox->status, memory_order_acquire);

  if (!is_active(status)) {
    return false;
  }

  int64_t processed = 0;
  int64_t max_process = message_count(status);
  if (max_process > 100) {
    max_process = 100;
  }

  void* system_message = cmpsc_linked_queue_dequeue(mailbox->system_messages);
  while (system_message != NULL) {
    //printf("Procesing system message...\n");
    callback(system_context, system_message);
    system_message = cmpsc_linked_queue_dequeue(mailbox->system_messages);
  }

  void* message = cmpsc_linked_queue_dequeue(mailbox->messages);
  while (message != NULL) {
    processed += 1;
    //printf("Procesing user message...\n");
    callback(context, message);
    if (processed >= max_process) {
      message = NULL;
    } else {
      message = cmpsc_linked_queue_dequeue(mailbox->messages);
    }
  }

  //printf("Processed %lld messages...\n", processed);

  int64_t old_status = decrement_status_activations(mailbox, processed);

  int64_t old_count = message_count(old_status);
  //printf("Old: %lld, processed: %lld\n", old_count, processed);
  if (old_count > processed || !cmpsc_linked_queue_is_empty(mailbox->system_messages)) {
    //printf("More messages, enqueuing again...\n");
    return true;
  }

  //printf("Done processing...\n");
  return false;
}

bool try_activate(CMailbox* mailbox) {
  int old = atomic_fetch_or_explicit(&mailbox->status, 1, memory_order_acq_rel);
  return (old & 1) == 0;
}

int64_t increment_status_activations(CMailbox* mailbox) {
  return atomic_fetch_add_explicit(&mailbox->status, 2, memory_order_acq_rel);
}

int64_t decrement_status_activations(CMailbox* mailbox, int64_t n) {
  return atomic_fetch_sub_explicit(&mailbox->status, (n << 1) | 0x1, memory_order_acq_rel);
}

bool is_active(int64_t status) {
  return (status & ACTIVATIONS) != 0;
}

bool has_any_messages(int64_t status) {
  return (status & ACTIVATIONS) > 0;
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
