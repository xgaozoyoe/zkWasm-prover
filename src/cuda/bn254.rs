use super::bn254_c;
use crate::device::cuda::{to_result, CudaBuffer, CudaDevice, CudaDeviceBufRaw};
use crate::device::Error;
use crate::device::{Device, DeviceResult};
use halo2_proofs::arithmetic::{CurveAffine, FieldExt};
use halo2_proofs::pairing::group::Curve;
use halo2_proofs::pairing::group::Group;

pub(crate) fn extended_prepare(
    device: &CudaDevice,
    s: &CudaDeviceBufRaw,
    coset_powers: &CudaDeviceBufRaw,
    coset_powers_n: usize,
    size: usize,
    extended_size: usize,
) -> Result<(), Error> {
    unsafe {
        device.acitve_ctx()?;
        let err = bn254_c::extended_prepare(
            s.ptr(),
            coset_powers.ptr(),
            coset_powers_n as i32,
            size as i32,
            extended_size as i32,
        );
        to_result((), err, "fail to run extended_prepare")?;
        Ok(())
    }
}

#[derive(Debug, PartialEq)]
pub(crate) enum FieldOp {
    Sum = 0,
    Mul = 1,
    Neg = 2,
    Sub = 3,
}

pub(crate) fn field_op_v2<F: FieldExt>(
    device: &CudaDevice,
    res: &CudaDeviceBufRaw,
    l: Option<&CudaDeviceBufRaw>,
    l_c: Option<F>,
    r: Option<&CudaDeviceBufRaw>,
    r_c: Option<F>,
    size: usize,
    op: FieldOp,
) -> Result<(), Error> {
    field_op(device, res, l, 0, l_c, r, 0, r_c, size, op)
}

pub(crate) fn field_op<F: FieldExt>(
    device: &CudaDevice,
    res: &CudaDeviceBufRaw,
    l: Option<&CudaDeviceBufRaw>,
    l_rot: i32,
    l_c: Option<F>,
    r: Option<&CudaDeviceBufRaw>,
    r_rot: i32,
    r_c: Option<F>,
    size: usize,
    op: FieldOp,
) -> Result<(), Error> {
    let l_c = if l_c.is_none() {
        0usize as *mut _
    } else {
        device
            .alloc_device_buffer_from_slice([l_c.unwrap()].as_slice())?
            .ptr()
    };
    let r_c = if r_c.is_none() {
        0usize as *mut _
    } else {
        device
            .alloc_device_buffer_from_slice([r_c.unwrap()].as_slice())?
            .ptr()
    };
    unsafe {
        device.acitve_ctx()?;
        let err = bn254_c::field_op(
            res.ptr(),
            l.map_or(0usize as *mut _, |x| x.ptr()),
            l_rot,
            l_c,
            r.map_or(0usize as *mut _, |x| x.ptr()),
            r_rot,
            r_c,
            size as i32,
            op as i32,
        );
        to_result((), err, "fail to run field_op")?;
    }
    device.synchronize()?;
    Ok(())
}

pub fn msm<C: CurveAffine>(
    device: &CudaDevice,
    p_buf: &CudaDeviceBufRaw,
    s_buf: &CudaDeviceBufRaw,
    len: usize,
) -> Result<C, Error> {
    msm_with_groups(device, p_buf, s_buf, len, 4)
}

pub fn msm_with_groups<C: CurveAffine>(
    device: &CudaDevice,
    p_buf: &CudaDeviceBufRaw,
    s_buf: &CudaDeviceBufRaw,
    len: usize,
    msm_groups: usize,
) -> Result<C, Error> {
    let threads = 128;
    let windows = 32;
    let windows_bits = 8;
    let mut tmp = vec![C::Curve::identity(); msm_groups * windows];
    let res_buf = device.alloc_device_buffer_from_slice(&tmp[..])?;
    unsafe {
        device.acitve_ctx()?;
        let err = bn254_c::msm(
            msm_groups as i32,
            threads,
            res_buf.ptr(),
            p_buf.ptr(),
            s_buf.ptr(),
            len as i32,
        );
        to_result((), err, "fail to run msm")?;
    }
    device.copy_from_device_to_host(&mut tmp[..], &res_buf)?;

    for i in 0..windows {
        for j in 1..msm_groups {
            tmp[i] = tmp[i] + tmp[i + j * windows];
        }
    }

    let mut msm_res = tmp[windows - 1];
    for i in 0..windows - 1 {
        for _ in 0..windows_bits {
            msm_res = msm_res + msm_res;
        }
        msm_res = msm_res + tmp[windows - 2 - i];
    }

    Ok(msm_res.to_affine())
}

pub const MAX_DEG: usize = 8;

pub fn ntt_prepare<F: FieldExt>(
    device: &CudaDevice,
    omega: F,
    len_log: usize,
) -> DeviceResult<(CudaDeviceBufRaw, CudaDeviceBufRaw)> {
    let len = 1 << len_log;
    let mut omegas = vec![F::one()];
    for _ in 1..len {
        omegas.push(*omegas.last().unwrap() * omega);
    }

    let max_deg = MAX_DEG.min(len_log);
    let mut pq = vec![F::zero(); 1 << max_deg >> 1];
    let twiddle = omega.pow_vartime([(len >> max_deg) as u64]);
    pq[0] = F::one();
    if max_deg > 1 {
        pq[1] = twiddle;
        for i in 2..(1 << max_deg >> 1) {
            pq[i] = pq[i - 1];
            pq[i].mul_assign(&twiddle);
        }
    }

    let omegas_buf = device.alloc_device_buffer_from_slice(&omegas[..])?;
    let pq_buf = device.alloc_device_buffer_from_slice(&pq[..])?;

    Ok((omegas_buf, pq_buf))
}

pub fn ntt_raw(
    device: &CudaDevice,
    s_buf: &mut CudaDeviceBufRaw,
    tmp_buf: &mut CudaDeviceBufRaw,
    pq_buf: &CudaDeviceBufRaw,
    omegas_buf: &CudaDeviceBufRaw,
    len_log: usize,
) -> Result<(), Error> {
    let mut swap = false;
    unsafe {
        device.acitve_ctx()?;
        let err = crate::cuda::bn254::bn254_c::ntt(
            s_buf.ptr(),
            tmp_buf.ptr(),
            pq_buf.ptr(),
            omegas_buf.ptr(),
            len_log as i32,
            MAX_DEG as i32,
            &mut swap as *mut _ as _,
        );
        to_result((), err, "fail to run ntt")?;
    }
    if swap {
        std::mem::swap(s_buf, tmp_buf);
    }
    Ok(())
}

pub fn intt_raw(
    device: &CudaDevice,
    s_buf: &mut CudaDeviceBufRaw,
    tmp_buf: &mut CudaDeviceBufRaw,
    pq_buf: &CudaDeviceBufRaw,
    omegas_buf: &CudaDeviceBufRaw,
    divisor: &CudaDeviceBufRaw,
    len_log: usize,
) -> Result<(), Error> {
    ntt_raw(device, s_buf, tmp_buf, pq_buf, omegas_buf, len_log)?;
    unsafe {
        let err = bn254_c::field_op(
            s_buf.ptr(),
            s_buf.ptr(),
            0,
            0usize as *mut _,
            0usize as *mut _,
            0,
            divisor.ptr(),
            (1 << len_log) as i32,
            FieldOp::Mul as i32,
        );
        to_result((), err, "fail to run field_op in intt_raw")?;
    }
    Ok(())
}

pub fn ntt<F: FieldExt>(
    device: &CudaDevice,
    s_buf: &mut CudaDeviceBufRaw,
    tmp_buf: &mut CudaDeviceBufRaw,
    pq_buf: &CudaDeviceBufRaw,
    omegas_buf: &CudaDeviceBufRaw,
    result: &mut [F],
    len_log: usize,
) -> Result<(), Error> {
    ntt_raw(device, s_buf, tmp_buf, pq_buf, omegas_buf, len_log)?;
    device.copy_from_device_to_host(result, s_buf)?;
    Ok(())
}

// plonk permutation
pub fn permutation_eval_h_p1(
    device: &CudaDevice,
    res: &CudaDeviceBufRaw,
    first_set: &CudaDeviceBufRaw,
    last_set: &CudaDeviceBufRaw,
    l0: &CudaDeviceBufRaw,
    l_last: &CudaDeviceBufRaw,
    y: &CudaDeviceBufRaw,
    n: usize,
) -> Result<(), Error> {
    unsafe {
        device.acitve_ctx()?;
        let err = bn254_c::permutation_eval_h_p1(
            res.ptr(),
            first_set.ptr(),
            last_set.ptr(),
            l0.ptr(),
            l_last.ptr(),
            y.ptr(),
            n as i32,
        );
        to_result((), err, "fail to run permutation_eval_h_p1")?;
        device.synchronize()?;
    }
    Ok(())
}

pub fn permutation_eval_h_p2(
    device: &CudaDevice,
    res: &CudaDeviceBufRaw,
    set: &[CudaDeviceBufRaw],
    l0: &CudaDeviceBufRaw,
    l_last: &CudaDeviceBufRaw,
    y: &CudaDeviceBufRaw,
    rot: usize,
    n: usize,
) -> Result<(), Error> {
    unsafe {
        device.acitve_ctx()?;
        let sets = device
            .alloc_device_buffer_from_slice(&set.iter().map(|x| x.ptr()).collect::<Vec<_>>()[..])?;
        let err = bn254_c::permutation_eval_h_p2(
            res.ptr(),
            sets.ptr(),
            l0.ptr(),
            l_last.ptr(),
            y.ptr(),
            set.len() as i32,
            rot as i32,
            n as i32,
        );
        to_result((), err, "fail to run permutation_eval_h_p2")?;
        device.synchronize()?;
    }
    Ok(())
}

pub fn permutation_eval_h_l(
    device: &CudaDevice,
    res: &CudaDeviceBufRaw,
    beta: &CudaDeviceBufRaw,
    gamma: &CudaDeviceBufRaw,
    p: &CudaDeviceBufRaw,
    n: usize,
) -> Result<(), Error> {
    unsafe {
        device.acitve_ctx()?;
        let err =
            bn254_c::permutation_eval_h_l(res.ptr(), beta.ptr(), gamma.ptr(), p.ptr(), n as i32);
        to_result((), err, "fail to run permutation_eval_h_l")?;
        device.synchronize()?;
    }
    Ok(())
}

pub fn permutation_eval_h_r(
    device: &CudaDevice,
    res: &CudaDeviceBufRaw,
    delta: &CudaDeviceBufRaw,
    gamma: &CudaDeviceBufRaw,
    value: &CudaDeviceBufRaw,
) -> Result<(), Error> {
    unsafe {
        device.acitve_ctx()?;
        let err = bn254_c::permutation_eval_h_r(
            res.ptr(),
            delta.ptr(),
            gamma.ptr(),
            value.ptr(),
            2,
        );
        to_result((), err, "fail to run permutation_eval_h_r")?;
        device.synchronize()?;
    }
    Ok(())
}

pub fn buffer_copy_with_shift<F: FieldExt>(
    device: &CudaDevice,
    dst: &CudaDeviceBufRaw,
    src: &CudaDeviceBufRaw,
    rot: isize,
    size: usize,
) -> Result<(), Error> {
    if rot == 0 {
        device.copy_from_device_to_device::<F>(&dst, 0, src, 0, size)?;
        device.synchronize()?;
    } else if rot > 0 {
        let rot = rot as usize;
        let len = size - rot as usize;
        device.copy_from_device_to_device::<F>(&dst, 0, src, rot as usize, len)?;
        device.synchronize()?;
        device.copy_from_device_to_device::<F>(&dst, len, src, 0, rot as usize)?;
        device.synchronize()?;
    } else {
        let rot = -rot as usize;
        let len = size - rot;
        device.copy_from_device_to_device::<F>(&dst, 0, src, rot, len)?;
        device.synchronize()?;
        device.copy_from_device_to_device::<F>(&dst, len, src, 0, rot)?;
        device.synchronize()?;
    }
    Ok(())
}
