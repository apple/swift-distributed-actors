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
// This source file is part of the DistributedActors open source project
//
// Copyright (c) 2018 Apple Inc. and the DistributedActors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of DistributedActors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#include <stdlib.h>
#include "CMPSCLinkedQueue.h"

// This queue is based on the algorithm presented in:
// http://www.1024cores.net/home/lock-free-algorithms/queues/non-intrusive-mpsc-node-based-queue

CMPSCLinkedQueue* cmpsc_linked_queue_create() {
    CMPSCLinkedQueue* q = malloc(sizeof(CMPSCLinkedQueue));
    Node* node = calloc(sizeof(Node), 1);
    atomic_store_explicit(&q->producer, node, memory_order_release);
    q->consumer = node;
    return q;
}

void cmpsc_linked_queue_destroy(CMPSCLinkedQueue* q) {
    void* item;
    while ((item = cmpsc_linked_queue_dequeue(q)) != NULL) {
        free(item);
    }
    free(q->producer);
    free(q);
}

void cmpsc_linked_queue_enqueue(CMPSCLinkedQueue* q, void* item) {
    Node* node = calloc(sizeof(Node), 1);
    node->item = item;
    Node* old_node = atomic_exchange_explicit(&q->producer, node, memory_order_acq_rel);
    atomic_store_explicit(&old_node->next, node, memory_order_release);
}

void* cmpsc_linked_queue_dequeue(CMPSCLinkedQueue* q) {
    Node* node = atomic_load_explicit(&q->consumer->next, memory_order_acquire);
    if (node == NULL) {
        if (q->consumer == atomic_load_explicit(&q->producer, memory_order_acquire)) {
            return NULL;
        }

        do {
            node = atomic_load_explicit(&q->consumer->next, memory_order_acquire);
        } while (node == NULL);
    }

    atomic_store_explicit(&q->consumer->next, NULL, memory_order_release);
    void* item = node->item;
    free(q->consumer);
    q->consumer = node;
    return item;
}

int cmpsc_linked_queue_is_empty(CMPSCLinkedQueue* q) {
    return atomic_load_explicit(&q->consumer->next, memory_order_consume) == NULL
           && atomic_load_explicit(&q->producer, memory_order_consume) == q->consumer;
}
