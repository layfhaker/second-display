//! Single-instance guard: a named mutex, like the C# `SingleInstance`.

use windows::core::w;
use windows::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, HANDLE};
use windows::Win32::System::Threading::CreateMutexW;

pub struct SingleInstance {
    handle: HANDLE,
}

impl SingleInstance {
    /// Returns `None` if another instance already holds the mutex.
    pub fn acquire() -> Option<Self> {
        unsafe {
            let handle = CreateMutexW(None, true, w!("Global\\SecondDisplayHost")).ok()?;
            if GetLastError() == ERROR_ALREADY_EXISTS {
                let _ = CloseHandle(handle);
                return None;
            }
            Some(Self { handle })
        }
    }
}

impl Drop for SingleInstance {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.handle);
        }
    }
}
