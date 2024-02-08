#include "cuda_runtime.h"
#include <stdio.h>
#include <assert.h>

#include "bn254.cuh"

__global__ void _msm_step1(
    Bn254G1Affine *p,
    Bn254FrField *s,
    int n)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int worker = blockDim.x * gridDim.x;
    int size_per_worker = n / worker;
    int start = gid * size_per_worker;
    int end = start + size_per_worker;

    for (int i = start; i < end; i++)
    {
        /*
        if (s[i].get_bit(253))
        {
            p[i].ec_neg_assign();
            s[i].neg_assign();
        }
        assert(!s[i].get_bit(253));
        */
        s[i].unmont_assign();
    }
}

__global__ void _msm_step2(
    Bn254G1 *res,
    const Bn254G1Affine *p,
    Bn254FrField *s,
    int n)
{
    int idx = threadIdx.x;
    Bn254G1 buckets[255];

    for (int i = 0; i < n; i++)
    {
        int v = s[i].unmont().get_8bits(idx);
        if (v != 0)
        {
            buckets[v - 1] = buckets[v - 1] + p[i];
        }
    }

    Bn254G1 round;
    Bn254G1 acc;
    for (int i = 254; i >= 0; i--)
    {
        round = round + buckets[i];
        acc = acc + round;
    }

    res[idx] = acc;
}

extern "C"
{
    cudaError_t msm(
        Bn254G1 *res,
        Bn254G1Affine *p,
        Bn254FrField *s,
        int n)
    {
        /*
        int blocks = n / 32;
        _msm_step1<<<blocks, 32>>>(p, s, n);
        */
        _msm_step2<<<1, 32>>>(res, p, s, n);
        return cudaGetLastError();
    }
}
// Tests

__global__ void _test_bn254_ec(
    const Bn254G1Affine *a,
    const Bn254G1Affine *b,
    Bn254G1Affine *add,
    Bn254G1Affine *sub,
    Bn254G1Affine *_double,
    int n)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int worker = blockDim.x * gridDim.x;
    int size_per_worker = n / worker;
    int start = gid * size_per_worker;
    int end = start + size_per_worker;

    for (int i = start; i < end; i++)
    {
        Bn254G1 zero;
        Bn254G1 _a(a[i]);
        Bn254G1 _b(b[i]);

        add[i] = _a + _b;
        assert(add[i] == _a + b[i]);
        assert(zero + a[i] + b[i] == add[i]);
        sub[i] = _a - _b;
        _double[i] = _a + _a;
        assert(_double[i] == _a.ec_double());
        assert(a[i] == _a + Bn254G1::identity());
        assert(a[i] == _a + Bn254G1Affine::identity());
        assert(a[i] == Bn254G1::identity() + _a);
        assert(a[i] == Bn254G1::identity() + _a);
        assert(_a - a[i] == Bn254G1::identity());
    }
}

/*
__global__ void _test_bn254_fr_field(
    const Bn254FrField *a,
    const Bn254FrField *b,
    const ulong *exp,
    Bn254FrField *add,
    Bn254FrField *sub,
    Bn254FrField *mul,
    Bn254FrField *sqr,
    Bn254FrField *inv,
    Bn254FrField *pow,
    Bn254FrField *unmont,
    bool *compare,
    int n)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int worker = blockDim.x * gridDim.x;
    int size_per_worker = n / worker;
    int start = gid * size_per_worker;
    int end = start + size_per_worker;

    for (int i = start; i < end; i++)
    {
        add[i] = Bn254FrField::add(&a[i], &b[i]);
        sub[i] = Bn254FrField::sub(&a[i], &b[i]);
        mul[i] = Bn254FrField::mul(&a[i], &b[i]);
        sqr[i] = Bn254FrField::sqr(&a[i]);
        inv[i] = Bn254FrField::inv(&a[i]);
        pow[i] = Bn254FrField::pow(&a[i], exp[i]);

        {
            unmont[i] = a[i];
            Bn254FrField::unmont(&unmont[i]);
        }

        {
            Bn254FrField t = unmont[i];
            Bn254FrField::mont(&t);
            assert(Bn254FrField::eq(&t, &a[i]));
        }

        {
            Bn254FrField l = a[i];
            Bn254FrField r = b[i];
            Bn254FrField::unmont(&l);
            Bn254FrField::unmont(&r);
            compare[i] = Bn254FrField::gte(&l, &r);
        }
    }
}

__global__ void _test_bn254_fp_field(
    const Bn254FpField *a,
    const Bn254FpField *b,
    const ulong *exp,
    Bn254FpField *add,
    Bn254FpField *sub,
    Bn254FpField *mul,
    Bn254FpField *sqr,
    Bn254FpField *inv,
    Bn254FpField *pow,
    Bn254FpField *unmont,
    bool *compare,
    int n)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int worker = blockDim.x * gridDim.x;
    int size_per_worker = n / worker;
    int start = gid * size_per_worker;
    int end = start + size_per_worker;

    for (int i = start; i < end; i++)
    {
        add[i] = Bn254FpField::add(&a[i], &b[i]);
        sub[i] = Bn254FpField::sub(&a[i], &b[i]);
        mul[i] = Bn254FpField::mul(&a[i], &b[i]);
        sqr[i] = Bn254FpField::sqr(&a[i]);
        inv[i] = Bn254FpField::inv(&a[i]);
        pow[i] = Bn254FpField::pow(&a[i], exp[i]);

        {
            unmont[i] = a[i];
            Bn254FpField::unmont(&unmont[i]);
        }

        {
            Bn254FpField t = unmont[i];
            Bn254FpField::mont(&t);
            assert(Bn254FpField::eq(&t, &a[i]));
        }

        {
            Bn254FpField l = a[i];
            Bn254FpField r = b[i];
            Bn254FpField::unmont(&l);
            Bn254FpField::unmont(&r);
            compare[i] = Bn254FpField::gte(&l, &r);
        }
    }
}
*/

extern "C"
{
    /*
    cudaError_t test_bn254_fr_field(
        int blocks, int threads,
        const Bn254FrField *a,
        const Bn254FrField *b,
        const ulong *exp,
        Bn254FrField *add,
        Bn254FrField *sub,
        Bn254FrField *mul,
        Bn254FrField *sqr,
        Bn254FrField *inv,
        Bn254FrField *pow,
        Bn254FrField *unmont,
        bool *compare,
        int n)
    {
        _test_bn254_fr_field<<<blocks, threads>>>(a, b, exp, add, sub, mul, sqr, inv, pow, unmont, compare, n);
        return cudaGetLastError();
    }

    cudaError_t test_bn254_fp_field(
        int blocks, int threads,
        const Bn254FpField *a,
        const Bn254FpField *b,
        const ulong *exp,
        Bn254FpField *add,
        Bn254FpField *sub,
        Bn254FpField *mul,
        Bn254FpField *sqr,
        Bn254FpField *inv,
        Bn254FpField *pow,
        Bn254FpField *unmont,
        bool *compare,
        int n)
    {
        _test_bn254_fp_field<<<blocks, threads>>>(a, b, exp, add, sub, mul, sqr, inv, pow, unmont, compare, n);
        return cudaGetLastError();
    }
    */

    cudaError_t test_bn254_ec(
        int blocks, int threads,
        const Bn254G1Affine *a,
        const Bn254G1Affine *b,
        Bn254G1Affine *add,
        Bn254G1Affine *sub,
        Bn254G1Affine *_double,
        int n)
    {
        _test_bn254_ec<<<blocks, threads>>>(a, b, add, sub, _double, n);
        return cudaGetLastError();
    }
}