--TEST--
PDO_OCI: Statement garbage collection after the connection is freed
--EXTENSIONS--
pdo
pdo_oci
--SKIPIF--
<?php
require(getenv('PDO_TEST_DIR').'/pdo_test.inc');
PDOTest::skip();
?>
--FILE--
<?php
require_once(getenv('PDO_TEST_DIR').'/pdo_test.inc');

class GCRow {
    public PDOStatement $stmt;
}

$dsn = preg_replace('/;charset=[^;]*/i', '', getenv('PDOTEST_DSN'));
foreach (['private' => false, 'shared' => false, 'persistent' => true] as $mode => $persistent) {
    foreach (['prepared', 'executed', 'clob', 'failed lob bind'] as $case) {
        $db = new PDO(
            $dsn . ($mode === 'shared' ? '' : ';charset=AL32UTF8'),
            getenv('PDOTEST_USER'),
            getenv('PDOTEST_PASS'),
            [PDO::ATTR_PERSISTENT => $persistent],
        );
        $sql = match ($case) {
            'clob' => "SELECT TO_CLOB('value') FROM dual",
            'failed lob bind' => 'SELECT :value FROM pdo_oci_gc_missing_table',
            default => 'SELECT 1 FROM dual',
        };
        $stmt = $db->prepare($sql);
        if ($case === 'failed lob bind') {
            $db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_SILENT);
            $stmt->bindValue(':value', '', PDO::PARAM_LOB);
            if ($stmt->execute() !== false) {
                throw new Exception('Expected execution to fail');
            }
        } elseif ($case !== 'prepared') {
            $stmt->execute();
        }

        // Keep the statement in a cycle so GC can free the connection first.
        $row = new GCRow();
        $row->stmt = $stmt;
        $stmt->setFetchMode(PDO::FETCH_INTO, $row);
        $dbRef = WeakReference::create($db);
        $stmtRef = WeakReference::create($stmt);
        unset($db, $stmt, $row);
        gc_collect_cycles();

        echo "$mode $case: ";
        var_dump($dbRef->get() === null && $stmtRef->get() === null);
    }
}
?>
--EXPECT--
private prepared: bool(true)
private executed: bool(true)
private clob: bool(true)
private failed lob bind: bool(true)
shared prepared: bool(true)
shared executed: bool(true)
shared clob: bool(true)
shared failed lob bind: bool(true)
persistent prepared: bool(true)
persistent executed: bool(true)
persistent clob: bool(true)
persistent failed lob bind: bool(true)
