<?php
if (!extension_loaded('tensor') || phpversion('tensor') !== getenv('TENSOR_EXPECTED_VERSION')) {
    throw new RuntimeException('The expected Tensor extension must be loaded.');
}
foreach ([
    Tensor\Matrix::class, Tensor\Vector::class, Tensor\ColumnVector::class,
    Tensor\Decompositions\Cholesky::class, Tensor\Decompositions\Eigen::class,
    Tensor\Decompositions\LU::class, Tensor\Decompositions\SVD::class,
    Tensor\Reductions\REF::class, Tensor\Reductions\RREF::class,
] as $class) {
    if (!(new ReflectionClass($class))->isInternal()) {
        throw new RuntimeException("The tests must use the native $class class.");
    }
}
require __DIR__ . '/../tensor-tests/src/constants.php';
spl_autoload_register(static function (string $class): void {
    if (str_starts_with($class, 'Tensor\\')) {
        $file = __DIR__ . '/../tensor-tests/src/' . str_replace('\\', '/', substr($class, 7)) . '.php';
        if (is_file($file)) {
            require $file;
        }
    }
});
