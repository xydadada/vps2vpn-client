use interprocess::local_socket::tokio::{prelude::*, Stream};
use interprocess::local_socket::ListenerOptions;
use std::io;

/// Linux carries an `fchmod` on the unbound socket over to the file `bind`
/// creates; other Unixes reject it and get `restrict_socket` after `bind`.
pub fn owner_only(options: ListenerOptions<'_>) -> ListenerOptions<'_> {
    #[cfg(target_os = "linux")]
    {
        use interprocess::os::unix::local_socket::ListenerOptionsExt as _;

        options.mode(0o600)
    }
    #[cfg(windows)]
    {
        use interprocess::os::windows::local_socket::ListenerOptionsExt as _;

        match pipe_acl::descriptor() {
            Some(descriptor) => options.security_descriptor(descriptor),
            // The default descriptor still limits writes to this user and SYSTEM.
            None => options,
        }
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        options
    }
}

/// The default pipe descriptor lets every account read, and hold the one slot;
/// only this user and SYSTEM (the Helper's Core) get in, from medium up.
#[cfg(windows)]
pub(crate) mod pipe_acl {
    use interprocess::os::windows::security_descriptor::SecurityDescriptor;
    use std::ffi::c_void;
    use std::ptr::null_mut;
    use widestring::U16CString;
    use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, HANDLE};
    use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
    use windows_sys::Win32::Security::{GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    pub fn sddl(user_sid: &str) -> String {
        format!("D:P(A;;GA;;;SY)(A;;GA;;;{user_sid})S:(ML;;NWNR;;;ME)")
    }

    pub fn descriptor() -> Option<SecurityDescriptor> {
        let sid = current_user_sid()?;
        let text = U16CString::from_str(sddl(&sid)).ok()?;
        SecurityDescriptor::deserialize(&text).ok()
    }

    pub fn current_user_sid() -> Option<String> {
        // SAFETY: Win32 calls on our own token into buffers that outlive them.
        unsafe {
            let mut token: HANDLE = null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return None;
            }
            let mut length = 0u32;
            GetTokenInformation(token, TokenUser, null_mut(), 0, &mut length);
            if (length as usize) < size_of::<TOKEN_USER>() {
                CloseHandle(token);
                return None;
            }
            let mut buffer = vec![0u64; (length as usize).div_ceil(8)];
            let read = GetTokenInformation(
                token,
                TokenUser,
                buffer.as_mut_ptr().cast::<c_void>(),
                length,
                &mut length,
            );
            CloseHandle(token);
            if read == 0 {
                return None;
            }
            let user = &*(buffer.as_ptr() as *const TOKEN_USER);
            let mut text = null_mut();
            if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 || text.is_null() {
                return None;
            }
            let mut len = 0;
            while *text.add(len) != 0 {
                len += 1;
            }
            let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, len));
            LocalFree(text.cast());
            sid.starts_with("S-1-").then_some(sid)
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn reads_this_users_sid() {
            let sid = current_user_sid().expect("own SID");
            assert!(sid.starts_with("S-1-5-"), "{sid}");
        }

        #[test]
        fn the_descriptor_parses_and_names_only_system_and_the_user() {
            let text = sddl("S-1-5-21-1-2-3-1001");
            assert_eq!(
                text,
                "D:P(A;;GA;;;SY)(A;;GA;;;S-1-5-21-1-2-3-1001)S:(ML;;NWNR;;;ME)"
            );
            assert!(descriptor().is_some());
        }

        #[test]
        fn a_pipe_with_the_descriptor_takes_this_users_connection() {
            use interprocess::local_socket::prelude::*;
            use interprocess::local_socket::{GenericNamespaced, ListenerOptions, Stream};
            use std::io::{Read, Write};

            let name = format!("vps2vpn-acl-test-{}", std::process::id());
            let listener = super::super::owner_only(
                ListenerOptions::new().name(name.clone().to_ns_name::<GenericNamespaced>().unwrap()),
            )
            .create_sync()
            .expect("pipe with the narrowed descriptor");
            let client = std::thread::spawn(move || {
                let mut stream =
                    Stream::connect(name.to_ns_name::<GenericNamespaced>().unwrap()).unwrap();
                stream.write_all(b"hi").unwrap();
            });
            let mut peer = listener.accept().expect("own process admitted");
            let mut got = [0u8; 2];
            peer.read_exact(&mut got).unwrap();
            assert_eq!(&got, b"hi");
            client.join().unwrap();
        }
    }
}

pub fn restrict_socket(path: &str) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    #[cfg(windows)]
    {
        let _ = path;
    }
    Ok(())
}

/// Reports the admitted peer's process ID where the platform knows it.
pub fn admit(stream: &Stream) -> io::Result<Option<u32>> {
    let credentials = stream.peer_creds()?;
    #[cfg(unix)]
    {
        let peer_uid = credentials
            .euid()
            .ok_or_else(|| denied("peer user ID is unavailable".into()))?;
        // SAFETY: geteuid() takes no arguments and cannot fail.
        let own_uid = unsafe { libc::geteuid() };
        if !is_permitted_uid(peer_uid, own_uid) {
            return Err(denied(format!(
                "peer uid {peer_uid} is neither {own_uid} nor root"
            )));
        }
    }
    #[allow(clippy::useless_conversion)]
    Ok(credentials.pid().and_then(|pid| u32::try_from(pid).ok()))
}

#[cfg(unix)]
fn denied(reason: String) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, reason)
}

#[cfg(unix)]
fn is_permitted_uid(peer_uid: libc::uid_t, own_uid: libc::uid_t) -> bool {
    peer_uid == own_uid || peer_uid == 0
}

#[cfg(all(test, unix))]
mod tests {
    use super::is_permitted_uid;

    #[test]
    fn admits_the_socket_owner() {
        assert!(is_permitted_uid(501, 501));
    }

    #[test]
    fn admits_root_because_the_core_runs_privileged_for_tun() {
        assert!(is_permitted_uid(0, 501));
    }

    #[test]
    fn rejects_every_other_user() {
        assert!(!is_permitted_uid(502, 501));
        assert!(!is_permitted_uid(501, 0));
    }
}
