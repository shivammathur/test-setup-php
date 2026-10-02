#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <amqp.h>
#include <amqp_ssl_socket.h>

int main(int argc, char **argv)
{
    amqp_connection_state_t conn;
    amqp_socket_t *socket;
    int status, expect_success;
    if (argc != 5) return 2;
    if (strcmp(amqp_version(), "0.18.0") != 0) {
        fprintf(stderr, "Unexpected rabbitmq version: %s\n", amqp_version()); return 2;
    }
    expect_success = strcmp(argv[4], "success") == 0;
    conn = amqp_new_connection();
    if (!conn) return 2;
    socket = amqp_ssl_socket_new(conn);
    if (!socket) return 2;
    amqp_ssl_socket_set_verify_peer(socket, 1);
    amqp_ssl_socket_set_verify_hostname(socket, 1);
    status = amqp_ssl_socket_set_cacert(socket, argv[3]);
    if (status != AMQP_STATUS_OK) return 2;
    status = amqp_socket_open(socket, argv[1], atoi(argv[2]));
    printf("RabbitMQ %s: socket status=%d (%s)\n", amqp_version(), status,
           amqp_error_string2(status));
    amqp_destroy_connection(conn);
    return expect_success ? (status != AMQP_STATUS_OK) :
        (status != AMQP_STATUS_SSL_PEER_VERIFY_FAILED && status != AMQP_STATUS_SSL_HOSTNAME_VERIFY_FAILED);
}
