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

#ifndef c_run_queue_h
#define c_run_queue_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
    void* crun_queue_create();

    void crun_queue_destroy(void* q);

    void crun_queue_enqueue(void* q, intptr_t item);

    intptr_t crun_queue_dequeue_timed(void* q, int64_t timeout_usec);

    intptr_t crun_queue_dequeue(void* _q);
#ifdef __cplusplus
}
#endif

#endif /* c_run_queue_h */
