
/// Bounded gestures for a remote human: duration, hold before/after, or a double tap.
/// Keeps one HID connection open for the whole gesture so two taps are not separated
/// by the 500 ms service flush used by the upstream single-tap helper.
///
/// # Safety
/// Handles must be valid and belong to this library. Call serially with other probes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_glasses_gesture(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    x1: u16, y1: u16, x2: u16, y2: u16,
    duration_ms: u64, before_ms: u64, after_ms: u64, taps: u8,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() || duration_ms > 2000
        || before_ms > 2000 || after_ms > 2000 || !(1..=2).contains(&taps) {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let res = run_sync_local(async move {
        let (a, h) = unsafe { (&mut (*adapter).0, &mut (*handshake).0) };
        let gate = open_gate(a, h).await;
        let mut hid = UniversalHidServiceClient::connect_rsd(a, h).await?;
        let ts = || Some(unsafe { libc::mach_absolute_time() });
        for tap in 0..taps {
            hid.send_touchscreen(TOUCH_CONTACT, x1, y1, ts()).await?;
            if (x1, y1) == (x2, y2) {
                tokio::time::sleep(Duration::from_millis(before_ms.max(60))).await;
            } else {
                if before_ms > 0 { tokio::time::sleep(Duration::from_millis(before_ms)).await; }
                let steps = (duration_ms / 10).clamp(5, 200);
                for i in 1..=steps {
                    tokio::time::sleep(Duration::from_millis(duration_ms.max(50) / steps)).await;
                    let t = i as f64 / steps as f64;
                    let x = (x1 as f64 + (x2 as f64 - x1 as f64) * t).round() as u16;
                    let y = (y1 as f64 + (y2 as f64 - y1 as f64) * t).round() as u16;
                    hid.send_touchscreen(TOUCH_CONTACT, x, y, ts()).await?;
                }
            }
            if after_ms > 0 { tokio::time::sleep(Duration::from_millis(after_ms)).await; }
            hid.send_touchscreen(TOUCH_RELEASE, x2, y2, ts()).await?;
            hid.send_touchscreen(TOUCH_RELEASE, x2, y2, ts()).await?;
            if tap + 1 < taps { tokio::time::sleep(Duration::from_millis(100)).await; }
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
        close_gate(gate).await;
        Ok::<(), IdeviceError>(())
    });
    match res { Ok(()) => null_mut(), Err(e) => ffi_err!(e) }
}
