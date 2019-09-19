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

#include <stdlib.h>
#include "c_mpsc_linked_queue.h"

// This queue is based on the algorithm presented in:
// http://www.1024cores.net/home/lock-free-algorithms/queues/non-intrusive-mpsc-node-based-queue

CSActMPSCLinkedQueue* c_sact_mpsc_linked_queue_create() {
    CSActMPSCLinkedQueue* q = malloc(sizeof(CSActMPSCLinkedQueue));
    CSActMPSCLinkedQueueNode* node = calloc(sizeof(CSActMPSCLinkedQueueNode), 1);
    atomic_store_explicit(&q->producer, node, memory_order_release);
    q->consumer = node;
    return q;
}

void c_sact_mpsc_linked_queue_destroy(CSActMPSCLinkedQueue* q) {
    void* item;
    while ((item = c_sact_mpsc_linked_queue_dequeue(q)) != NULL) {
        free(item);
    }
    free(q->producer);
    free(q);
}

void c_sact_mpsc_linked_queue_enqueue(CSActMPSCLinkedQueue* q, void* item) {
    CSActMPSCLinkedQueueNode* node = calloc(sizeof(CSActMPSCLinkedQueueNode), 1);
    node->item = item;
    CSActMPSCLinkedQueueNode* old_node = atomic_exchange_explicit(&q->producer, node, memory_order_acq_rel);
    atomic_store_explicit(&old_node->next, node, memory_order_release);
}

void* c_sact_mpsc_linked_queue_dequeue(CSActMPSCLinkedQueue* q) {
    CSActMPSCLinkedQueueNode* node = atomic_load_explicit(&q->consumer->next, memory_order_acquire);
    if (node == NULL) {
        return NULL;
    }

    atomic_store_explicit(&q->consumer->next, NULL, memory_order_release);
    void* item = node->item;
    free(q->consumer);
    q->consumer = node;
    return item;
}
