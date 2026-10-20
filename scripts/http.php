<?php
header('Content-Type: application/json');
echo json_encode(array('smoke'=>'ok', 'version'=>PHP_VERSION, 'zts'=>(bool)PHP_ZTS));
