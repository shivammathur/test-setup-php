#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cblas.h>
#include <lapacke.h>

typedef char check_blas_integer_width[sizeof(blasint) == 4 ? 1 : -1];
typedef char check_lapack_integer_width[sizeof(lapack_int) == 4 ? 1 : -1];

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); return 1; \
} } while (0)
#define CLOSE(actual, expected) (fabs((actual) - (expected)) < 1e-10)

static int check_parallel_gemm(void)
{
    const int n = 512;
    size_t count = (size_t)n * n;
    double *a = malloc(count * sizeof(*a));
    double *identity = calloc(count, sizeof(*identity));
    double *product = malloc(count * sizeof(*product));
    int i, j;
    CHECK(a && identity && product);
    for (i = 0; i < n; ++i) {
        identity[i * n + i] = 1;
        for (j = 0; j < n; ++j) a[i * n + j] = ((i * 17 + j * 5) % 31 - 15) / 16.0;
    }
    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, n, n, n,
                1, a, n, identity, n, 0, product, n);
    for (i = 0; i < n * n; ++i) CHECK(CLOSE(product[i], a[i]));
    free(a); free(identity); free(product);
    return 0;
}

static int check_numerics(int threads)
{
    const double a[] = {4, 1, 1, 3};
    const double identity[] = {1, 0, 0, 1};
    double product[4] = {0};
    double inverse[4], cholesky[4], svd[4], eigen[4];
    double s[2], u[4], vt[4], wr[2], wi[2], vectors[4];
    double unused[4] = {0};
    lapack_int pivots[2];
    lapack_complex_double za[4] = {{0}}, zb[2] = {{0}};
    lapack_complex_double left[] = {{{1, 2}}, {{3, -1}}};
    lapack_complex_double right[] = {{{2, -1}}, {{-1, 4}}};
    lapack_complex_double dot = {{0}};

    openblas_set_num_threads(threads);
    CHECK(openblas_get_num_threads() == threads);
    CHECK(check_parallel_gemm() == 0);
    cblas_zdotu_sub(2, left, 1, right, 1, &dot);
    CHECK(CLOSE(dot._Val[0], 5) && CLOSE(dot._Val[1], 16));
    cblas_zdotc_sub(2, left, 1, right, 1, &dot);
    CHECK(CLOSE(dot._Val[0], -7) && CLOSE(dot._Val[1], 6));
    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, 2, 2, 2,
                1, a, 2, identity, 2, 0, product, 2);
    CHECK(CLOSE(product[0], 4) && CLOSE(product[1], 1) && CLOSE(product[3], 3));
    CHECK(CLOSE(cblas_ddot(4, a, 1, identity, 1), 7));

    memcpy(inverse, a, sizeof(a));
    CHECK(LAPACKE_dgetrf(LAPACK_ROW_MAJOR, 2, 2, inverse, 2, pivots) == 0);
    CHECK(LAPACKE_dgetri(LAPACK_ROW_MAJOR, 2, inverse, 2, pivots) == 0);
    CHECK(CLOSE(inverse[0], 3.0 / 11) && CLOSE(inverse[1], -1.0 / 11));
    CHECK(CLOSE(inverse[2], -1.0 / 11) && CLOSE(inverse[3], 4.0 / 11));

    memcpy(cholesky, a, sizeof(a));
    CHECK(LAPACKE_dpotrf(LAPACK_ROW_MAJOR, 'L', 2, cholesky, 2) == 0);
    CHECK(CLOSE(cholesky[0], 2) && CLOSE(cholesky[2], 0.5));
    memcpy(svd, a, sizeof(a));
    CHECK(LAPACKE_dgesdd(LAPACK_ROW_MAJOR, 'A', 2, 2, svd, 2, s, u, 2, vt, 2) == 0);
    CHECK(CLOSE(s[0] + s[1], 7) && CLOSE(s[0] * s[1], 11));
    memcpy(eigen, a, sizeof(a));
    CHECK(LAPACKE_dgeev(LAPACK_ROW_MAJOR, 'N', 'V', 2, eigen, 2, wr, wi,
                        unused, 2, vectors, 2) == 0);
    CHECK(CLOSE(wr[0] + wr[1], 7) && CLOSE(wi[0], 0) && CLOSE(wi[1], 0));
    memcpy(eigen, a, sizeof(a));
    CHECK(LAPACKE_dsyev(LAPACK_ROW_MAJOR, 'V', 'U', 2, eigen, 2, wr) == 0);
    CHECK(CLOSE(wr[0] + wr[1], 7) && CLOSE(wr[0] * wr[1], 11));

    /* Exercise the MSVC complex-struct ABI through LAPACKE, not just headers. */
    za[0]._Val[0] = 2; za[3]._Val[0] = 4;
    zb[0]._Val[0] = 2; zb[0]._Val[1] = 4;
    zb[1]._Val[0] = 8; zb[1]._Val[1] = -4;
    CHECK(LAPACKE_zgesv(LAPACK_ROW_MAJOR, 2, 1, za, 2, pivots, zb, 1) == 0);
    CHECK(CLOSE(zb[0]._Val[0], 1) && CLOSE(zb[0]._Val[1], 2));
    CHECK(CLOSE(zb[1]._Val[0], 2) && CLOSE(zb[1]._Val[1], -1));
    return 0;
}

int main(void)
{
    const char *config = openblas_get_config();
    puts(config);
    CHECK(strstr(config, "DYNAMIC_ARCH") != NULL);
    CHECK(strstr(config, "MAX_THREADS=64") != NULL);
    CHECK(strstr(config, "USE64BITINT") == NULL);
    CHECK(openblas_get_parallel() == 1);
    CHECK(check_numerics(1) == 0);
    CHECK(check_numerics(2) == 0);
    puts("PASS: 32-bit BLAS/LAPACK integers; BLAS, LU/inverse, Cholesky, SVD, eigenvalues, complex LAPACKE; one/two threads");
    return 0;
}
