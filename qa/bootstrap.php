<?php
if (!extension_loaded('tensor') || !(new ReflectionClass(Tensor\Matrix::class))->isInternal()) {
    throw new RuntimeException('The tests must exercise the native Tensor extension.');
}
require __DIR__ . '/../tensor-tests/src/constants.php';
spl_autoload_register(static function (string $class): void {
    if (str_starts_with($class, 'Tensor\\')) {
        $path = __DIR__ . '/../tensor-tests/src/' . str_replace('\\', '/', substr($class, 7)) . '.php';
        if (is_file($path)) {
            require $path;
        }
    }
});
