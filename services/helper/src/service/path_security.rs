const SYSTEM: &str = "S-1-5-18";
const ADMINISTRATORS: &str = "S-1-5-32-544";
pub(super) const TRUSTED_INSTALLER: &str = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";

pub(super) struct Entry {
    pub(super) kind: u8,
    pub(super) inherit_only: bool,
    pub(super) mask: u32,
    pub(super) sid: String,
}

fn trusted(sid: &str) -> bool {
    matches!(sid, SYSTEM | ADMINISTRATORS | TRUSTED_INSTALLER)
}

pub(super) fn protected(owner: &str, entries: &[Entry], payload_directory_or_file: bool) -> bool {
    const REPLACE: u32 = 0x1000_0000 | 0x4000_0000 | 0x000d_0000 | 0x0000_0150;
    let mutation = REPLACE | if payload_directory_or_file { 0x6 } else { 0 };
    trusted(owner)
        && entries.iter().all(|entry| {
            if entry.inherit_only || entry.kind == 1 {
                return true;
            }
            entry.kind == 0 && (trusted(&entry.sid) || entry.mask & mutation == 0)
        })
}

#[cfg(windows)]
pub use platform::secure_executable;

#[cfg(windows)]
mod platform {
    use super::{protected, Entry};
    use anyhow::{bail, Context, Result};
    use std::fs::{File, OpenOptions};
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
    use std::os::windows::io::AsRawHandle;
    use std::path::{Component, Path, Prefix};
    use std::ptr::null_mut;
    use windows_sys::Win32::Foundation::{LocalFree, HANDLE, PSID};
    use windows_sys::Win32::Security::Authorization::{
        ConvertSidToStringSidW, GetSecurityInfo, SE_FILE_OBJECT,
    };
    use windows_sys::Win32::Security::{
        GetAce, IsValidAcl, IsValidSid, ACCESS_ALLOWED_ACE, ACE_HEADER, DACL_SECURITY_INFORMATION,
        OWNER_SECURITY_INFORMATION,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        GetFinalPathNameByHandleW, FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS,
        FILE_FLAG_OPEN_REPARSE_POINT, FILE_LIST_DIRECTORY, FILE_READ_ATTRIBUTES, FILE_READ_DATA,
        FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, READ_CONTROL,
    };

    pub fn secure_executable(path: &Path) -> Result<Vec<File>> {
        if !path.is_absolute()
            || !matches!(
                path.components().next(),
                Some(Component::Prefix(prefix))
                    if matches!(prefix.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_))
            )
        {
            bail!("helper must use an absolute local drive path");
        }
        for component in path.components() {
            match component {
                Component::Normal(name) => {
                    let name = name.to_str().context("helper path is not Unicode")?;
                    if name.contains(':') || name.ends_with(['.', ' ']) {
                        bail!("helper path contains an ambiguous component");
                    }
                }
                Component::ParentDir | Component::CurDir => bail!("helper path is not normalized"),
                _ => {}
            }
        }
        let mut ancestors: Vec<_> = path.ancestors().collect();
        ancestors.reverse();
        let mut held = Vec::new();
        for ancestor in ancestors {
            let is_executable = ancestor == path;
            let (access, share) = if is_executable {
                (
                    FILE_READ_DATA | READ_CONTROL | FILE_READ_ATTRIBUTES,
                    FILE_SHARE_READ,
                )
            } else {
                (
                    FILE_LIST_DIRECTORY | READ_CONTROL | FILE_READ_ATTRIBUTES,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                )
            };
            let handle = OpenOptions::new()
                .access_mode(access)
                .share_mode(share)
                .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
                .open(ancestor)
                .with_context(|| format!("open protected helper path {}", ancestor.display()))?;
            let metadata = handle.metadata()?;
            if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
                || metadata.is_dir() == is_executable
            {
                bail!("helper path contains a reparse point or unexpected object type");
            }
            let raw = handle.as_raw_handle() as HANDLE;
            let mut final_name = vec![0u16; 32768];
            let count = unsafe {
                GetFinalPathNameByHandleW(raw, final_name.as_mut_ptr(), final_name.len() as u32, 0)
            } as usize;
            if count == 0 || count >= final_name.len() {
                bail!("cannot resolve the protected helper handle");
            }
            let final_name = String::from_utf16(&final_name[..count])?;
            let requested = ancestor.to_str().context("helper path is not Unicode")?;
            if !final_name
                .trim_start_matches(r"\\?\")
                .eq_ignore_ascii_case(requested.trim_start_matches(r"\\?\"))
            {
                bail!("helper path resolves through a drive alias");
            }
            let payload = is_executable || Some(ancestor) == path.parent();
            unsafe { check_security(raw, payload) }
                .with_context(|| format!("unprotected helper path {}", ancestor.display()))?;
            held.push(handle);
        }
        Ok(held)
    }

    struct SecurityDescriptor(*mut core::ffi::c_void);

    impl Drop for SecurityDescriptor {
        fn drop(&mut self) {
            unsafe { LocalFree(self.0 as _) };
        }
    }

    unsafe fn check_security(handle: HANDLE, payload: bool) -> Result<()> {
        let mut owner = null_mut();
        let mut dacl = null_mut();
        let mut descriptor = null_mut();
        let status = GetSecurityInfo(
            handle,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            null_mut(),
            &mut dacl,
            null_mut(),
            &mut descriptor,
        );
        if status != 0 {
            bail!("read helper security descriptor: {status}");
        }
        let _descriptor = SecurityDescriptor(descriptor);
        if dacl.is_null() || IsValidAcl(dacl) == 0 {
            bail!("helper path has no valid restrictive DACL");
        }
        let owner = sid_string(owner)?;
        let mut entries = Vec::new();
        for index in 0..(*dacl).AceCount {
            let mut ace = null_mut();
            if GetAce(dacl, u32::from(index), &mut ace) == 0 || ace.is_null() {
                bail!("cannot inspect a helper path ACE");
            }
            let header = &*ace.cast::<ACE_HEADER>();
            if header.AceFlags & 8 != 0 || header.AceType == 1 {
                continue;
            }
            if header.AceType != 0 || usize::from(header.AceSize) < 16 {
                bail!("helper path uses an unsupported effective ACE");
            }
            let allowed = &*ace.cast::<ACCESS_ALLOWED_ACE>();
            entries.push(Entry {
                kind: header.AceType,
                inherit_only: false,
                mask: allowed.Mask,
                sid: sid_string((&allowed.SidStart as *const u32).cast_mut().cast())?,
            });
        }
        if !protected(&owner, &entries, payload) {
            bail!("helper path is mutable by a non-system owner or trustee; use a protected installation");
        }
        Ok(())
    }

    unsafe fn sid_string(sid: PSID) -> Result<String> {
        if sid.is_null() || IsValidSid(sid) == 0 {
            bail!("invalid helper path SID");
        }
        let mut text = null_mut();
        if ConvertSidToStringSidW(sid, &mut text) == 0 {
            bail!("cannot read helper path SID");
        }
        let mut len = 0;
        while *text.add(len) != 0 {
            len += 1;
        }
        let result = String::from_utf16_lossy(std::slice::from_raw_parts(text, len));
        LocalFree(text as _);
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn allow(sid: &str, mask: u32) -> Entry {
        Entry {
            kind: 0,
            inherit_only: false,
            mask,
            sid: sid.into(),
        }
    }

    #[test]
    fn accepts_system_administrator_and_installer_control() {
        for sid in [SYSTEM, ADMINISTRATORS, TRUSTED_INSTALLER] {
            assert!(protected(sid, &[allow(sid, u32::MAX)], true));
        }
    }

    #[test]
    fn rejects_user_owner_even_when_the_dacl_is_read_only() {
        assert!(!protected("S-1-5-21-1", &[], true));
    }

    #[test]
    fn rejects_mutable_payload_and_replaceable_ancestors() {
        for mask in [
            0x2, 0x4, 0x10, 0x100, 0x40, 0x10000, 0x40000, 0x80000, 0x10000000, 0x40000000,
        ] {
            assert!(!protected(SYSTEM, &[allow("S-1-1-0", mask)], true));
        }
        for mask in [0x40, 0x10000, 0x40000, 0x80000] {
            assert!(!protected(SYSTEM, &[allow("S-1-1-0", mask)], false));
        }
        assert!(protected(SYSTEM, &[allow("S-1-1-0", 0x120089)], true));
        assert!(protected(SYSTEM, &[allow("S-1-1-0", 0x4)], false));
    }

    #[test]
    fn inherit_only_does_not_grant_access_to_this_object() {
        let mut entry = allow("S-1-3-0", u32::MAX);
        entry.inherit_only = true;
        assert!(protected(SYSTEM, &[entry], true));
    }

    #[test]
    fn unsupported_effective_aces_fail_closed() {
        let mut entry = allow(SYSTEM, 0);
        entry.kind = 9;
        assert!(!protected(SYSTEM, &[entry], true));
    }
}
