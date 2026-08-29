use std::ffi::OsStr;
use std::ffi::OsString;

#[cfg(unix)]
use std::os::unix::ffi::OsStrExt as OsStrExtUnix;

#[cfg(unix)]
use std::os::unix::ffi::OsStringExt as OsStringExtUnix;

#[cfg(target_os = "wasi")]
use std::os::wasi::ffi::OsStrExt as OsStrExtUnix;

#[cfg(target_os = "wasi")]
use std::os::wasi::ffi::OsStringExt as OsStringExtUnix;

pub trait OsStrExt {
    fn as_bytes(&self) -> &[u8];
    fn from_bytes(slice: &[u8]) -> &Self;
}

#[cfg(any(unix, target_os = "wasi"))]
impl OsStrExt for OsStr {
    fn as_bytes(&self) -> &[u8] {
        OsStrExtUnix::as_bytes(self)
    }

    fn from_bytes(slice: &[u8]) -> &Self {
        OsStrExtUnix::from_bytes(slice)
    }
}

#[cfg(windows)]
impl OsStrExt for OsStr {
    fn as_bytes(&self) -> &[u8] {
        self.to_str().unwrap().as_bytes()
    }

    fn from_bytes(slice: &[u8]) -> &Self {
        let string = std::str::from_utf8(slice).unwrap();
        OsStr::new(string)
    }
}

pub trait OsStringExt {
    fn from_vec(vec: Vec<u8>) -> Self;
}

#[cfg(any(unix, target_os = "wasi"))]
impl OsStringExt for OsString {
    fn from_vec(vec: Vec<u8>) -> Self {
        OsStringExtUnix::from_vec(vec)
    }
}

#[cfg(windows)]
impl OsStringExt for OsString {
    fn from_vec(vec: Vec<u8>) -> Self {
        OsStr::from_bytes(vec.as_slice()).into()
    }
}
