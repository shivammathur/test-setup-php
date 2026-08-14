--TEST--
External static library is linked through the extra configure paths
--FILE--
<?php
var_dump(extra_path_fixture_add(20, 22));
?>
--EXPECT--
int(42)
