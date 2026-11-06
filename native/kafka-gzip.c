#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <librdkafka/rdkafka.h>
#include <librdkafka/rdkafka_mock.h>

static void set(rd_kafka_conf_t *conf, const char *key, const char *value) {
    char error[512];
    if (rd_kafka_conf_set(conf, key, value, error, sizeof(error)) != RD_KAFKA_CONF_OK) {
        fprintf(stderr, "%s: %s\n", key, error); exit(1);
    }
}
int main(void) {
    rd_kafka_conf_t *conf = rd_kafka_conf_new();
    rd_kafka_t *producer, *consumer;
    rd_kafka_topic_t *ptopic, *ctopic;
    rd_kafka_mock_cluster_t *mock;
    char error[512], payload[65536];
    int i, count = 0;
    set(conf, "builtin.features", "gzip,ssl,zstd");
    set(conf, "compression.codec", "gzip");
    set(conf, "message.timeout.ms", "15000");
    producer = rd_kafka_new(RD_KAFKA_PRODUCER, conf, error, sizeof(error));
    if (!producer) { fprintf(stderr, "%s\n", error); return 2; }
    mock = rd_kafka_mock_cluster_new(producer, 1);
    if (!mock || rd_kafka_mock_topic_create(mock, "zlib-qa", 1, 1)) return 3;
    if (!rd_kafka_brokers_add(producer, rd_kafka_mock_cluster_bootstraps(mock))) return 4;
    ptopic = rd_kafka_topic_new(producer, "zlib-qa", NULL);
    if (!ptopic) return 5;
    for (i = 0; i < (int)sizeof(payload); ++i) payload[i] = (char)('a' + i % 23);
    for (i = 0; i < 32; ++i) {
        if (rd_kafka_produce(ptopic, 0, RD_KAFKA_MSG_F_COPY, payload, sizeof(payload), NULL, 0, NULL)) return 6;
    }
    if (rd_kafka_flush(producer, 20000)) return 7;
    conf = rd_kafka_conf_new();
    set(conf, "bootstrap.servers", rd_kafka_mock_cluster_bootstraps(mock));
    set(conf, "enable.auto.commit", "false");
    consumer = rd_kafka_new(RD_KAFKA_CONSUMER, conf, error, sizeof(error));
    if (!consumer) { fprintf(stderr, "%s\n", error); return 8; }
    ctopic = rd_kafka_topic_new(consumer, "zlib-qa", NULL);
    if (!ctopic || rd_kafka_consume_start(ctopic, 0, RD_KAFKA_OFFSET_BEGINNING)) return 9;
    for (i = 0; i < 60 && count < 32; ++i) {
        rd_kafka_message_t *message = rd_kafka_consume(ctopic, 0, 500);
        if (!message) continue;
        if (message->err) { rd_kafka_message_destroy(message); continue; }
        if (message->len != sizeof(payload) || memcmp(message->payload, payload, sizeof(payload))) return 10;
        ++count;
        rd_kafka_message_destroy(message);
    }
    rd_kafka_consume_stop(ctopic, 0);
    rd_kafka_topic_destroy(ctopic);
    rd_kafka_destroy(consumer);
    rd_kafka_topic_destroy(ptopic);
    rd_kafka_mock_cluster_destroy(mock);
    rd_kafka_destroy(producer);
    if (count != 32 || rd_kafka_wait_destroyed(5000)) return 11;
    printf("librdkafka %s: 32 gzip messages produced and consumed with exact payloads\n", rd_kafka_version_str());
    return 0;
}
