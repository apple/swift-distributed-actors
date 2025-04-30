//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#include <stdlib.h>
#include <stdio.h>
#include <execinfo.h>

#include "include/backtrace_support.h"

void sact_dump_backtrace() {
    char** strs;
    int frames = sact_get_backtrace(&strs);
    for (int i = 0; i < frames; ++i) {
        fprintf(stderr, "%s\n", strs[i]);
    }
    free(strs);
}

int sact_get_backtrace(char*** strs) {
    void* callstack[128];
    int frames = backtrace(callstack, 128);
    *strs = backtrace_symbols(callstack, frames);
    return frames;
}
