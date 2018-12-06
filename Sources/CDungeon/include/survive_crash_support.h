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

#ifndef SACT_SURVIVE_CRASH_SUPPORT_H
#define SACT_SURVIVE_CRASH_SUPPORT_H

typedef void (* FailCellCallback)(void* failingCell, int sig, int sicode);

void sact_set_failure_handling_threadlocal_context(void* fail_context);
void* sact_clear_failure_handling_threadlocal_context();

int sact_install_swift_crash_handler(FailCellCallback failure_handler_swift_cb);


#endif
