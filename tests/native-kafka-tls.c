#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <librdkafka/rdkafka.h>

static int ssl_errors;
static void error_cb(rd_kafka_t *rk, int err, const char *reason, void *opaque)
{
    (void)rk; (void)opaque;
    fprintf(stderr, "Kafka error %d: %s\n", err, reason);
    if (err == RD_KAFKA_RESP_ERR__SSL) ssl_errors++;
}
static void set(rd_kafka_conf_t *conf, const char *key, const char *value)
{
    char error[512];
    if (rd_kafka_conf_set(conf, key, value, error, sizeof(error)) != RD_KAFKA_CONF_OK) {
        fprintf(stderr, "%s: %s\n", key, error); exit(2);
    }
}
int main(int argc, char **argv)
{
    char brokers[256], error[512];
    char features[1024];
    size_t features_size = sizeof(features);
    rd_kafka_conf_t *conf;
    rd_kafka_t *rk;
    ULONGLONG until;
    int expect_success;
    if (argc != 5) return 2;
    if (strcmp(rd_kafka_version_str(), "2.15.1") != 0) {
        fprintf(stderr, "Unexpected kafka version: %s\n", rd_kafka_version_str()); return 2;
    }
    expect_success = strcmp(argv[4], "success") == 0;
    snprintf(brokers, sizeof(brokers), "%s:%s", argv[1], argv[2]);
    conf = rd_kafka_conf_new();
    if (rd_kafka_conf_get(conf, "builtin.features", features, &features_size) != RD_KAFKA_CONF_OK) {
        fprintf(stderr, "Could not read Kafka's compiled features\n"); return 2;
    }
    printf("Kafka built-in features: %s\n", features);
    set(conf, "bootstrap.servers", brokers);
    set(conf, "security.protocol", "ssl");
    set(conf, "broker.address.family", "v4");
    set(conf, "ssl.ca.location", argv[3]);
    set(conf, "enable.ssl.certificate.verification", "true");
    set(conf, "ssl.endpoint.identification.algorithm", "https");
    set(conf, "reconnect.backoff.ms", "100");
    set(conf, "socket.connection.setup.timeout.ms", "1000");
    rd_kafka_conf_set_error_cb(conf, error_cb);
    rk = rd_kafka_new(RD_KAFKA_PRODUCER, conf, error, sizeof(error));
    if (!rk) { fprintf(stderr, "%s\n", error); return 2; }
    until = GetTickCount64() + 2500;
    while (GetTickCount64() < until) rd_kafka_poll(rk, 100);
    rd_kafka_destroy(rk);
    printf("Kafka %s: SSL errors=%d\n", rd_kafka_version_str(), ssl_errors);
    if (rd_kafka_wait_destroyed(5000) != 0) return 3;
    return expect_success ? (ssl_errors != 0) : (ssl_errors == 0);
}
