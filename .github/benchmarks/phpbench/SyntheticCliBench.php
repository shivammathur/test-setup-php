<?php

require_once dirname(__DIR__) . DIRECTORY_SEPARATOR . 'support' . DIRECTORY_SEPARATOR . 'synthetic_workload.php';

use function BenchmarkSupport\compositeWorkload;

/**
 * @Iterations(5)
 * @Revs(1)
 * @Warmup(1)
 */
final class SyntheticCliBench
{
	public function benchCompositeWorkload() : void
	{
		compositeWorkload();
	}
}
