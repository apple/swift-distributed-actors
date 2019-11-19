
#include <xpc/xpc.h>
#include <xpc/connection.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include "stdio.h"

static void connection_handler(xpc_connection_t peer) {
    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
        printf("HELLO I RECEIVED A MESSAGE");

        pid_t pid = getpid();
        int64_t threadId = 0;
        pthread_threadid_np(NULL, &threadId);

        FILE* fp;
        fp = fopen("/tmp/xpc.txt", "a+");
        fprintf(fp, "[SERVICE, pid:%d,tid:%lld] received: %s : %s   (error: %s)\n",
                pid, threadId,
                (xpc_type_get_name(xpc_get_type(event))),
                xpc_dictionary_get_string(event, "M"),
                xpc_dictionary_get_string(event, _xpc_error_key_description)
        );
        fclose(fp);

        // reply
        xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(message, "echo", xpc_dictionary_get_string(event, "M"));
        xpc_connection_send_message(peer, message);
        xpc_release(message);

    });

    xpc_connection_resume(peer);
}

int main(int argc, const char* argv[]) {

    FILE* fp;
    fp = fopen("/tmp/xpc.txt", "a+");
    fprintf(fp, "------------------------------------------------\n");
    fprintf(fp, "STARTED THE SERVICE\n");
    fclose(fp);

    xpc_main(connection_handler);
    exit(EXIT_FAILURE);
}
