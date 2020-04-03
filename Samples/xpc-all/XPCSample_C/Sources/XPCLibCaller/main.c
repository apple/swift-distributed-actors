
#include <xpc/xpc.h>
#include <xpc/connection.h>
#include <unistd.h>
#include <dispatch/dispatch.h>
#include <pthread.h>

//static void sact_xpc_connection_handler(xpc_object_t *event) {
//    printf("I GOT A REPLY:");
//}

int main(int argc, const char* argv[]) {

    printf("[CLIENT C] SENDING HELLO\n");

    xpc_connection_t c = xpc_connection_create("com.apple.actors.XPCLibService", dispatch_get_main_queue());
    xpc_connection_set_event_handler(c, ^(xpc_object_t event) {
        printf("[CLIENT C] I GOT A REPLY: %s", event);

        pid_t pid = getpid();
        int64_t threadId = 0;
        pthread_threadid_np(NULL, &threadId);

        FILE* fp;
        fp = fopen("/tmp/xpc.txt", "a+");
        fprintf(fp, "[CLIENT, pid:%d,tid:%lld] Received: %s: echo=%s    [event: %s]\n",
                pid, threadId,
                (xpc_type_get_name(xpc_get_type(event))),
                xpc_dictionary_get_string(event, "echo"),
                xpc_dictionary_get_string(event, _xpc_error_key_description)
        );
        fclose(fp);
    });
    xpc_connection_set_target_queue(c, dispatch_get_main_queue());
    xpc_connection_resume(c);

    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "M", "hello-hello-hello");
    xpc_connection_send_message(c, message);
    printf("[CLIENT] sent dictionary: foo=%s\n", xpc_dictionary_get_string(message, "M"));
    xpc_release(message);

    xpc_object_t message2 = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message2, "M", "two-two-two");
    xpc_connection_send_message(c, message2);
    printf("[CLIENT] sent dictionary: foo=%s\n", xpc_dictionary_get_string(message2, "M"));
    xpc_release(message2);

    dispatch_main();
}
