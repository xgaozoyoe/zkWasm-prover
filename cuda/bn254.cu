#include "cuda_runtime.h"
#include <stdio.h>
#include <assert.h>

#include "bn254.cuh"

__global__ void _msm_mont_unmont(
    Bn254G1Affine *p,
    Bn254FrField *s,
    bool mont,
    int n)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int worker = blockDim.x * gridDim.x;
    int size_per_worker = (n + worker - 1) / worker;
    int start = gid * size_per_worker;
    int end = start + size_per_worker;
    end = end > n ? n : end;

    for (int i = start; i < end; i++)
    {
        if (mont)
        {
            s[i].mont_assign();
        }
        else
        {
            s[i].unmont_assign();
        }
    }
}

__global__ void _msm_core(
    Bn254G1 *res,
    const Bn254G1Affine *p,
    Bn254FrField *s,
    int n)
{
    int group_idx = blockIdx.x;
    int worker = blockDim.x * gridDim.y;
    int size_per_worker = (n + worker - 1) / worker;
    int inner_idx = threadIdx.x;
    int window_idx = inner_idx + blockIdx.y * blockDim.x;
    int start = window_idx * size_per_worker;
    int end = start + size_per_worker;
    end = end > n ? n : end;

    __shared__ Bn254G1 thread_res[128];

    Bn254G1 buckets[256];

    for (int i = start; i < end; i++)
    {
        int v = s[i].get_8bits(group_idx);
        if (v--)
        {
            buckets[v] = buckets[v] + p[i];
        }
    }

    if (end > start)
    {
        Bn254G1 round;
        Bn254G1 acc;
        for (int i = 254; i >= 0; i--)
        {
            round = round + buckets[i];
            acc = acc + round;
        }

        thread_res[inner_idx] = acc;
    }

    __syncthreads();
    if (inner_idx == 0)
    {
        Bn254G1 acc;
        for (int i = 0; i < blockDim.x; i++)
        {
            acc = acc + thread_res[i];
        }
        res[group_idx + blockIdx.y * gridDim.x] = acc;
    }
}

__device__ uint bit_reverse(uint n, uint bits)
{
    uint r = 0;
    for (int i = 0; i < bits; i++)
    {
        r = (r << 1) | (n & 1);
        n >>= 1;
    }
    return r;
}

__device__ Bn254FrField pow_lookup(const Bn254FrField *bases, uint exponent)
{
    Bn254FrField res(1);
    uint i = 0;
    while (exponent > 0)
    {
        if (exponent & 1)
            res = res * bases[i];
        exponent = exponent >> 1;
        i++;
    }
    return res;
}

// Learn from ec-gpu
__global__ void _ntt_core(
    const Bn254FrField *_x,
    Bn254FrField *_y,
    const Bn254FrField *pq,
    const Bn254FrField *omegas,
    uint n,     // Number of elements
    uint log_p, // Log2 of `p` (Read more in the link above)
    uint deg,   // 1=>radix2, 2=>radix4, 3=>radix8, ...
    uint max_deg,
    uint grids) // Maximum degree supported, according to `pq` and `omegas`
{
    uint lid = threadIdx.x;
    uint lsize = blockDim.x;
    uint t = n >> deg;
    uint p = 1 << log_p;

    uint count = 1 << deg;
    uint counth = count >> 1;
    uint counts = count / lsize * lid;
    uint counte = counts + count / lsize;

    const uint pqshift = max_deg - deg;

    for (uint gridIdx = 0; gridIdx < grids; gridIdx++)
    {
        uint index = blockIdx.x + gridIdx * gridDim.x;
        uint k = index & (p - 1);

        const Bn254FrField *x = _x + index;
        Bn254FrField *y = _y + ((index - k) << deg) + k;

        __shared__ Bn254FrField u[512];
        uint base_exp = (n >> log_p >> deg) * k;
        for (uint i = counts; i < counte; i++)
        {
            u[i] = omegas[base_exp * i] * x[i * t];
        }
        __syncthreads();

        for (uint rnd = 0; rnd < deg; rnd++)
        {
            const uint bit = counth >> rnd;
            for (uint i = counts >> 1; i < counte >> 1; i++)
            {
                const uint di = i & (bit - 1);
                const uint i0 = (i << 1) - di;
                const uint i1 = i0 + bit;
                Bn254FrField tmp = u[i0];
                u[i0] += u[i1];
                u[i1] = tmp - u[i1];

                if (di != 0)
                    u[i1] = pq[di << rnd << pqshift] * u[i1];
            }

            __syncthreads();
        }

        for (uint i = counts >> 1; i < counte >> 1; i++)
        {
            y[i * p] = u[bit_reverse(i, deg)];
            y[(i + counth) * p] = u[bit_reverse(i + counth, deg)];
        }
    }
}

__global__ void _field_sum(
    Bn254FrField *res,
    Bn254FrField **v,
    Bn254FrField **v_c,
    int *v_rot,
    Bn254FrField *omegas,
    int v_n,
    int n)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int worker = blockDim.x * gridDim.x;
    int size_per_worker = (n + worker - 1) / worker;
    int start = gid * size_per_worker;
    int end = start + size_per_worker;
    end = end > n ? n : end;

    for (int i = start; i < end; i++)
    {
        Bn254FrField fl(0), fr;
        for (int j = 0; j < v_n; j++)
        {
            int v_i = i;

            int omega_exp = ((n + v_rot[j]) * i) & (n - 1);

            fr = v[j][v_i] * omegas[omega_exp];

            if (v_c[j])
            {
                fr = fr * *v_c[j];
            }

            if (j == 0)
            {
                fl = fr;
            }
            else
            {
                fl += fr;
            }
        }

        res[i] = fl;
    }
}

__global__ void _field_op_batch_mul_sum(
    Bn254FrField *res,
    Bn254FrField **v, // coeff0, a00, a01, null, coeff1, a10, a11, null,
    int *rot,
    int n_v,
    int n)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int i = gid;

    Bn254FrField fl(0), fr;
    int v_idx = 0;
    int rot_idx = 0;
    while (v_idx < n_v)
    {
        fr = *v[v_idx++]; // first one is coeff
        while (v[v_idx])
        {
            int idx;
            idx = (n + i + rot[rot_idx]) & (n - 1);
            fr = fr * v[v_idx][idx];
            v_idx++;
            rot_idx++;
        }

        fl += fr;
        v_idx++;
    }

    res[i] += fl;
}

__global__ void _field_op(
    Bn254FrField *res,
    Bn254FrField *l,
    int l_rot,
    Bn254FrField *l_c,
    Bn254FrField *r,
    int r_rot,
    Bn254FrField *r_c,
    int n,
    int op)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int worker = blockDim.x * gridDim.x;
    int size_per_worker = (n + worker - 1) / worker;
    int start = gid * size_per_worker;
    int end = start + size_per_worker;
    end = end > n ? n : end;

    Bn254FrField fl, fr;

    for (int i = start; i < end; i++)
    {
        if (l)
            if (l_c)
                fl = l[(i + l_rot) & (n - 1)] * l_c[0];
            else
                fl = l[(i + l_rot) & (n - 1)];
        else
            fl = l_c[0];

        if (r)
            if (r_c)
                fr = r[(i + r_rot) & (n - 1)] * r_c[0];
            else
                fr = r[(i + r_rot) & (n - 1)];
        else
            fr = r_c[0];

        // add
        if (op == 0)
        {
            res[i] = fl + fr;
        }
        // mul
        else if (op == 1)
        {
            res[i] = fl * fr;
        }
        // neg
        else if (op == 2)
        {
            res[i] = -fl;
        }
        // sub
        else if (op == 3)
        {
            res[i] = fl - fr;
        }
        else
        {
            assert(0);
        }
    }
}

__global__ void _extended_prepare(
    Bn254FrField *s,
    Bn254FrField *coset_powers,
    uint coset_powers_n,
    int n)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int worker = blockDim.x * gridDim.x;
    int size_per_worker = (n + worker - 1) / worker;
    int start = gid * size_per_worker;
    int end = start + size_per_worker;
    end = end > n ? n : end;

    for (int i = start; i < end; i++)
    {
        int index = i % coset_powers_n;
        if (index != 0)
        {
            s[i] = s[i] * coset_powers[index - 1];
        }
    }
}

__global__ void _permutation_eval_h_p1(
    Bn254FrField *res,
    const Bn254FrField *first_set,
    const Bn254FrField *last_set,
    const Bn254FrField *l0,
    const Bn254FrField *l_last,
    const Bn254FrField *y,
    int n)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int worker = blockDim.x * gridDim.x;
    int size_per_worker = (n + worker - 1) / worker;
    int start = gid * size_per_worker;
    int end = start + size_per_worker;
    end = end > n ? n : end;

    Bn254FrField t1, t2;

    for (int i = start; i < end; i++)
    {
        t1 = res[i];

        // l_0(X) * (1 - z_0(X)) = 0
        t1 = t1 * y[0];
        t2 = Bn254FrField(1);
        t2 -= first_set[i];
        t2 = t2 * l0[i];
        t1 += t2;

        // l_last(X) * (z_l(X)^2 - z_l(X)) = 0
        t1 = t1 * y[0];
        t2 = last_set[i].sqr();
        t2 -= last_set[i];
        t2 = t2 * l_last[i];
        t1 += t2;

        res[i] = t1;
    }
}

__global__ void _permutation_eval_h_p2(
    Bn254FrField *res,
    const Bn254FrField **set,
    const Bn254FrField *l0,
    const Bn254FrField *l_last,
    const Bn254FrField *y,
    int n_set,
    int rot,
    int n)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int worker = blockDim.x * gridDim.x;
    int size_per_worker = (n + worker - 1) / worker;
    int start = gid * size_per_worker;
    int end = start + size_per_worker;
    end = end > n ? n : end;

    Bn254FrField t1, t2;

    for (int i = start; i < end; i++)
    {
        int r_prev = (i + n + rot) & (n - 1);
        t1 = res[i];

        for (int j = 1; j < n_set; j++)
        {
            // l_0(X) * (z_i(X) - z_{i-1}(\omega^(last) X)) = 0
            t1 = t1 * y[0];
            t2 = set[j][i] - set[j - 1][r_prev];
            t2 = t2 * l0[i];
            t1 += t2;
        }
    }
}

__global__ void _permutation_eval_h_l(
    Bn254FrField *res,
    const Bn254FrField *beta,
    const Bn254FrField *gamma,
    const Bn254FrField *p,
    int n)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int worker = blockDim.x * gridDim.x;
    int size_per_worker = (n + worker - 1) / worker;
    int start = gid * size_per_worker;
    int end = start + size_per_worker;
    end = end > n ? n : end;

    for (int i = start; i < end; i++)
    {
        Bn254FrField t = p[i];
        t = t * beta[0];
        if (i == 0)
        {
            t += gamma[0];
        }
        res[i] += t;
    }
}

__global__ void _permutation_eval_h_r(
    Bn254FrField *res,
    const Bn254FrField *delta,
    const Bn254FrField *gamma,
    const Bn254FrField *value,
    int n)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int worker = blockDim.x * gridDim.x;
    int size_per_worker = (n + worker - 1) / worker;
    int start = gid * size_per_worker;
    int end = start + size_per_worker;
    end = end > n ? n : end;

    for (int i = start; i < end; i++)
    {
        Bn254FrField t = value[i];
        if (i == 0)
        {
            t += gamma[0];
        }

        if (i == 1)
        {
            t += delta[0];
        }

        res[i] = t;
    }
}

extern "C"
{
    cudaError_t field_sum(
        Bn254FrField *res,
        Bn254FrField **v,
        Bn254FrField **v_c,
        int *v_rot,
        Bn254FrField *omegas,
        int v_n,
        int n)
    {
        int threads = n >= 64 ? 64 : 1;
        int blocks = n / threads;
        _field_sum<<<blocks, threads>>>(res, v, v_c, v_rot, omegas, v_n, n);
        return cudaGetLastError();
    }

    cudaError_t extended_prepare(
        Bn254FrField *s,
        Bn254FrField *coset_powers,
        uint coset_powers_n,
        int size,
        int extended_size)
    {
        int threads = size >= 64 ? 64 : 1;
        int blocks = size / threads;
        _extended_prepare<<<blocks, threads>>>(s, coset_powers, coset_powers_n, extended_size);
        cudaMemset(&s[size], 0, (extended_size - size) * sizeof(Bn254FrField));
        return cudaGetLastError();
    }

    cudaError_t field_op_batch_mul_sum(
        Bn254FrField *res,
        Bn254FrField **v, // coeff0, a00, a01, null, coeff1, a10, a11, null,
        int *rot,
        int n_v,
        int n)
    {
        int threads = n >= 64 ? 64 : 1;
        int blocks = n / threads;
        _field_op_batch_mul_sum<<<blocks, threads>>>(res, v, rot, n_v, n);
        return cudaGetLastError();
    }

    cudaError_t field_op(
        Bn254FrField *res,
        Bn254FrField *l,
        int l_rot,
        Bn254FrField *l_c,
        Bn254FrField *r,
        int r_rot,
        Bn254FrField *r_c,
        int n,
        int op)
    {
        int threads = n >= 64 ? 64 : 1;
        int blocks = n / threads;
        _field_op<<<blocks, threads>>>(res, l, l_rot, l_c, r, r_rot, r_c, n, op);
        return cudaGetLastError();
    }

    cudaError_t permutation_eval_h_p1(
        Bn254FrField *res,
        const Bn254FrField *first_set,
        const Bn254FrField *last_set,
        const Bn254FrField *l0,
        const Bn254FrField *l_last,
        const Bn254FrField *y,
        int n)
    {
        int threads = n >= 64 ? 64 : 1;
        int blocks = n / threads;
        _permutation_eval_h_p1<<<blocks, threads>>>(res, first_set, last_set, l0, l_last, y, n);
        return cudaGetLastError();
    }

    cudaError_t permutation_eval_h_p2(
        Bn254FrField *res,
        const Bn254FrField **set,
        const Bn254FrField *l0,
        const Bn254FrField *l_last,
        const Bn254FrField *y,
        int n_set,
        int rot,
        int n)
    {
        int threads = n >= 64 ? 64 : 1;
        int blocks = n / threads;
        _permutation_eval_h_p2<<<blocks, threads>>>(res, set, l0, l_last, y, n_set, rot, n);
        return cudaGetLastError();
    }

    cudaError_t permutation_eval_h_l(
        Bn254FrField *res,
        const Bn254FrField *beta,
        const Bn254FrField *gamma,
        const Bn254FrField *p,
        int n)
    {
        int threads = n >= 64 ? 64 : 1;
        int blocks = n / threads;
        _permutation_eval_h_l<<<blocks, threads>>>(res, beta, gamma, p, n);
        return cudaGetLastError();
    }

    cudaError_t permutation_eval_h_r(
        Bn254FrField *res,
        const Bn254FrField *delta,
        const Bn254FrField *gamma,
        const Bn254FrField *p,
        int n)
    {
        _permutation_eval_h_r<<<1, 2>>>(res, delta, gamma, p, n);
        return cudaGetLastError();
    }

    cudaError_t ntt(
        Bn254FrField *buf,
        Bn254FrField *tmp,
        const Bn254FrField *pq,
        const Bn254FrField *omegas,
        int log_n,
        int max_deg,
        bool *swap)
    {
        int p = 0;

        Bn254FrField *src = buf;
        Bn254FrField *dst = tmp;
        int len = 1 << log_n;
        int total = 1 << (log_n - 1);
        while (p < log_n)
        {
            int res = log_n - p;
            int round = (res + max_deg - 1) / max_deg;
            int deg = (res + round - 1) / round;

            int threads = 1 << (deg - 1);
            int blocks = total >> (deg - 1);
            blocks = blocks > 65536 ? 65536 : blocks;
            int grids = (total / blocks) >> (deg - 1);
            _ntt_core<<<blocks, threads>>>(src, dst, pq, omegas, len, p, deg, max_deg, grids);

            Bn254FrField *t = src;
            src = dst;
            dst = t;
            p += deg;
            *swap = !*swap;
        }
        return cudaGetLastError();
    }

    cudaError_t msm(
        int msm_blocks,
        int max_msm_threads,
        Bn254G1 *res,
        Bn254G1Affine *p,
        Bn254FrField *s,
        int n)
    {
        int threads = n >= max_msm_threads ? max_msm_threads : 1;
        int blocks = (n + threads - 1) / threads;
        _msm_mont_unmont<<<blocks, threads>>>(p, s, false, n);
        _msm_core<<<dim3(32, msm_blocks), threads>>>(res, p, s, n);
        _msm_mont_unmont<<<blocks, threads>>>(p, s, true, n);
        return cudaGetLastError();
    }
}
// Tests

__global__ void _test_bn254_ec(
    const Bn254FrField *a,
    const Bn254FrField *b,
    const Bn254FrField **x,
    Bn254FrField *add,
    Bn254FrField *sub,
    Bn254FrField *_double,
    int n)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    int worker = blockDim.x * gridDim.x;
    int size_per_worker = n / worker;
    int start = gid * size_per_worker;
    int end = start + size_per_worker;

    for (int i = start; i < end; i++)
    {
        Bn254FrField t = a[i] + b[i] + sub[i];

        int j = 0;
        while (x[j]) {
            t = t * x[j][i];
            j++;
        }

        add[i] = t;

        /*
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
        */
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
        const Bn254FrField *a,
        const Bn254FrField *b,
        const Bn254FrField **x,
        Bn254FrField *add,
        Bn254FrField *sub,
        Bn254FrField *_double,
        int n)
    {
        _test_bn254_ec<<<blocks, threads>>>(a, b, x, add, sub, _double, n);
        return cudaGetLastError();
    }
}