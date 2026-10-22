<?php

use PHPUnit\Framework\Attributes\Depends;
use PHPUnit\Framework\TestCase;

final class OutcomesTest extends TestCase
{
    public function testPlainFailure(): void
    {
        self::assertTrue(false);
    }

    public function testCustomFailure(): void
    {
        self::assertTrue(false, 'PR1138 custom assertion message');
    }

    public function testExplicitFailure(): void
    {
        self::fail('PR1138 explicit failure');
    }

    public function testException(): void
    {
        throw new RuntimeException('PR1138 unexpected exception');
    }

    public function testRisky(): void
    {
        // Deliberately no assertions.
    }

    public function testSkippedReason(): void
    {
        self::markTestSkipped('PR1138 skipped with reason');
    }

    public function testSkippedNoReason(): void
    {
        self::markTestSkipped();
    }

    /** @depends testSkippedReason */
    #[Depends('testSkippedReason')]
    public function testSkippedDependency(): void
    {
        self::assertTrue(true);
    }

    public function testCustomMessageEndingInLocation(): void
    {
        self::assertTrue(false, 'PR1138 invalid attribute in template.php:42');
    }

    public function testMultilineCustomMessage(): void
    {
        self::assertTrue(false, "PR1138 multiline assertion message\nSecond detail line");
    }

    public function testDiffFailure(): void
    {
        self::assertSame('expected', 'actual', 'PR1138 assertion with diff');
    }

    public function testIncomplete(): void
    {
        self::markTestIncomplete('PR1138 incomplete test');
    }
}
