<?php
$iterations = isset($argv[1]) ? max(1, (int) $argv[1]) : 100;
$failures = 0;

for ($i = 1; $i <= $iterations; $i++) {
    $start = hrtime(true);
    try {
        $ie = new com('InternetExplorer.Application');
        $x = 0;
        $y = 0;
        try {
            $ie->clientToWindow($x, $y);
        } catch (com_exception $methodError) {
            printf(
                "METHOD iteration=%d code=%d hex=0x%08X message=%s\n",
                $i,
                $methodError->getCode(),
                $methodError->getCode(),
                $methodError->getMessage()
            );
        }
        $ie->quit();
        unset($ie);
        gc_collect_cycles();
        printf(
            "PASS iteration=%d elapsed_ms=%.3f x=%d y=%d\n",
            $i,
            (hrtime(true) - $start) / 1e6,
            $x,
            $y
        );
    } catch (com_exception $error) {
        $failures++;
        printf(
            "FAIL iteration=%d code=%d hex=0x%08X elapsed_ms=%.3f message=%s\n",
            $i,
            $error->getCode(),
            $error->getCode(),
            (hrtime(true) - $start) / 1e6,
            $error->getMessage()
        );
    }
}

printf("SUMMARY iterations=%d failures=%d\n", $iterations, $failures);
exit($failures > 0 ? 1 : 0);
