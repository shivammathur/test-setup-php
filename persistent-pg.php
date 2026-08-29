<?php

$connection = pg_pconnect(
    'host=127.0.0.1 port=5432 dbname=postgres user=postgres password=root '
    . 'application_name=php_pr_23227_repro connect_timeout=5'
);
if ($connection === false || pg_query($connection, 'SELECT 1') === false) {
    http_response_code(500);
    exit("PERSISTENT_CONNECTION_FAILED\n");
}

echo "PERSISTENT_CONNECTION_READY\n";
