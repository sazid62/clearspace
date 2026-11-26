//! A process's current folder, read from the kernel so it works without any shell setup.

#[cfg(target_os = "macos")]
pub fn of(pid: u32) -> Option<String> {
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    let read = unsafe {
        libc::proc_pidinfo(pid as libc::c_int, libc::PROC_PIDVNODEPATHINFO, 0, &mut info as *mut _ as *mut libc::c_void, size)
    };
    if read != size {
        return None;
    }
    let raw = info.pvi_cdir.vip_path.as_flattened();
    let bytes: Vec<u8> = raw.iter().take_while(|&&c| c != 0).map(|&c| c as u8).collect();
    let path = String::from_utf8_lossy(&bytes).into_owned();
    (!path.is_empty()).then_some(path)
}

#[cfg(target_os = "linux")]
pub fn of(pid: u32) -> Option<String> {
    std::fs::read_link(format!("/proc/{pid}/cwd")).ok().map(|p| p.to_string_lossy().into_owned())
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub fn of(_pid: u32) -> Option<String> {
    None
}

#[cfg(all(test, unix))]
mod tests {
    #[test]
    fn reads_own_folder() {
        let expected = std::env::current_dir().unwrap().canonicalize().unwrap();
        let got = super::of(std::process::id()).expect("cwd");
        assert_eq!(std::path::PathBuf::from(got).canonicalize().unwrap(), expected);
    }
}
