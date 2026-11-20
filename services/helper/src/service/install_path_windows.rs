use anyhow::{bail, Context, Result};
use std::ffi::c_void;
use std::fs::{File, OpenOptions};
use std::mem::{offset_of, size_of};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::os::windows::io::AsRawHandle;
use std::path::{Component, Path, Prefix};
use std::ptr::{addr_of, null_mut};

use windows_sys::Win32::Foundation::{LocalFree, ERROR_SUCCESS, HANDLE, PSID};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, GetSecurityInfo, SE_FILE_OBJECT,
};
use windows_sys::Win32::Security::{
    GetAce, GetSecurityDescriptorDacl, GetSecurityDescriptorOwner, IsValidAcl, IsValidSid,
    IsWellKnownSid, MapGenericMask, WinBuiltinAdministratorsSid, WinLocalSystemSid,
    ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, DACL_SECURITY_INFORMATION, GENERIC_MAPPING,
    INHERIT_ONLY_ACE, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR,
};
use windows_sys::Win32::Storage::FileSystem::{
    DELETE, FILE_ALL_ACCESS, FILE_APPEND_DATA, FILE_ATTRIBUTE_REPARSE_POINT, FILE_DELETE_CHILD,
    FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_GENERIC_EXECUTE,
    FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
    FILE_SHARE_WRITE, FILE_WRITE_ATTRIBUTES, FILE_WRITE_DATA, READ_CONTROL, WRITE_DAC, WRITE_OWNER,
};

const TRUSTED_INSTALLER: &str =
    "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";
const ALLOW_ACE: u8 = 0;
const DENY_ACE: u8 = 1;

#[derive(Clone, Copy)]
enum Part {
    Ancestor,
    Directory,
    Executable,
}

pub(super) fn verify(executable: &Path) -> Result<Vec<File>> {
    verify_path(executable).with_context(|| {
        format!(
            "{} is not a protected service executable; install with the Windows installer in a protected directory",
            executable.display()
        )
    })
}

fn verify_path(executable: &Path) -> Result<Vec<File>> {
    let mut components = executable.components();
    if !executable.is_absolute()
        || !matches!(
            components.next(),
            Some(Component::Prefix(prefix))
                if matches!(prefix.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_))
        )
        || components.any(|part| matches!(part, Component::ParentDir))
    {
        bail!("the service executable must have a local absolute path without traversal");
    }
    let mut paths = executable.ancestors().collect::<Vec<_>>();
    paths.reverse();
    if paths.len() < 2 {
        bail!("service executable path has no file");
    }
    let mut handles = Vec::with_capacity(paths.len());
    for (index, path) in paths.iter().enumerate() {
        let part = if index + 1 == paths.len() {
            Part::Executable
        } else if index + 2 == paths.len() {
            Part::Directory
        } else {
            Part::Ancestor
        };
        let file = OpenOptions::new()
            .access_mode(READ_CONTROL | FILE_READ_ATTRIBUTES)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .open(path)
            .with_context(|| format!("open {}", path.display()))?;
        let metadata = file
            .metadata()
            .with_context(|| format!("inspect {}", path.display()))?;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            bail!("{} must not be a reparse point", path.display());
        }
        let directory = !matches!(part, Part::Executable);
        if (directory && !metadata.is_dir()) || (!directory && !metadata.is_file()) {
            bail!("{} has the wrong file type", path.display());
        }
        check_file(&file, part).with_context(|| format!("secure {}", path.display()))?;
        handles.push(file);
    }
    Ok(handles)
}

struct LocalMemory(*mut c_void);

impl Drop for LocalMemory {
    fn drop(&mut self) {
        // SAFETY: the Windows security APIs allocated this buffer with LocalAlloc.
        unsafe { LocalFree(self.0) };
    }
}

fn check_file(file: &File, part: Part) -> Result<()> {
    let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
    // SAFETY: file owns a live handle with READ_CONTROL; outputs live until freed.
    let status = unsafe {
        GetSecurityInfo(
            file.as_raw_handle() as HANDLE,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            null_mut(),
            null_mut(),
            &mut descriptor,
        )
    };
    if status != ERROR_SUCCESS {
        return Err(std::io::Error::from_raw_os_error(status as i32).into());
    }
    let descriptor = LocalMemory(descriptor);
    check_descriptor(descriptor.0, part)
}

fn check_descriptor(descriptor: PSECURITY_DESCRIPTOR, part: Part) -> Result<()> {
    let mut owner: PSID = null_mut();
    let mut defaulted = 0;
    let mut present = 0;
    let mut acl: *mut ACL = null_mut();
    // SAFETY: descriptor is owned by a live Windows-allocated LocalMemory.
    unsafe {
        if GetSecurityDescriptorOwner(descriptor, &mut owner, &mut defaulted) == 0
            || GetSecurityDescriptorDacl(descriptor, &mut present, &mut acl, &mut defaulted) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        if !trusted_sid(owner)? {
            bail!("file owner can change its permissions and is not a trusted service owner");
        }
        if present == 0 || acl.is_null() || IsValidAcl(acl) == 0 {
            bail!("service path must have a valid non-null DACL");
        }
        for index in 0..u32::from((*acl).AceCount) {
            let mut ace: *mut c_void = null_mut();
            if GetAce(acl, index, &mut ace) == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            let header = &*(ace as *const ACE_HEADER);
            if u32::from(header.AceFlags) & INHERIT_ONLY_ACE != 0 || header.AceType == DENY_ACE {
                continue;
            }
            if header.AceType != ALLOW_ACE {
                bail!("unsupported access rule in service path DACL");
            }
            let offset = offset_of!(ACCESS_ALLOWED_ACE, SidStart);
            let ace_size = usize::from(header.AceSize);
            if ace_size < offset + 8 || ace_size < size_of::<ACCESS_ALLOWED_ACE>() {
                bail!("invalid service path access rule");
            }
            let allowed = &*(ace as *const ACCESS_ALLOWED_ACE);
            let sid = addr_of!(allowed.SidStart) as *mut u8;
            let sid_size = 8 + usize::from(*sid.add(1)) * 4;
            if offset + sid_size > ace_size || IsValidSid(sid.cast()) == 0 {
                bail!("invalid service path access rule SID");
            }
            let mut mask = allowed.Mask;
            MapGenericMask(
                &mut mask,
                &GENERIC_MAPPING {
                    GenericRead: FILE_GENERIC_READ,
                    GenericWrite: FILE_GENERIC_WRITE,
                    GenericExecute: FILE_GENERIC_EXECUTE,
                    GenericAll: FILE_ALL_ACCESS,
                },
            );
            if mask & mutation_rights(part) != 0 && !trusted_sid(sid.cast())? {
                bail!("service path grants modification or replacement rights to an untrusted account");
            }
        }
    }
    Ok(())
}

fn mutation_rights(part: Part) -> u32 {
    let common = DELETE | WRITE_DAC | WRITE_OWNER | FILE_WRITE_ATTRIBUTES;
    match part {
        Part::Ancestor => common | FILE_DELETE_CHILD,
        Part::Directory => common | FILE_DELETE_CHILD | FILE_WRITE_DATA | FILE_APPEND_DATA,
        Part::Executable => common | FILE_WRITE_DATA | FILE_APPEND_DATA,
    }
}

unsafe fn trusted_sid(sid: PSID) -> Result<bool> {
    if sid.is_null() || IsValidSid(sid) == 0 {
        return Ok(false);
    }
    if IsWellKnownSid(sid, WinLocalSystemSid) != 0
        || IsWellKnownSid(sid, WinBuiltinAdministratorsSid) != 0
    {
        return Ok(true);
    }
    let mut text: *mut u16 = null_mut();
    if ConvertSidToStringSidW(sid, &mut text) == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let _text = LocalMemory(text.cast());
    let mut length = 0;
    while *text.add(length) != 0 {
        length += 1;
    }
    Ok(String::from_utf16_lossy(std::slice::from_raw_parts(text, length)) == TRUSTED_INSTALLER)
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows_sys::Win32::Security::Authorization::{
        ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
    };

    fn validate(sddl: &str, part: Part) -> Result<()> {
        let wide = sddl.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
        let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
        let parsed = unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                wide.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                null_mut(),
            )
        };
        assert_ne!(parsed, 0, "invalid fixture {sddl}: {}", std::io::Error::last_os_error());
        let descriptor = LocalMemory(descriptor);
        check_descriptor(descriptor.0, part)
    }

    #[test]
    fn allows_system_admin_and_read_only_users() {
        let sddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;BU)";
        for part in [Part::Ancestor, Part::Directory, Part::Executable] {
            validate(sddl, part).unwrap();
        }
    }

    #[test]
    fn allows_trusted_installer_as_owner() {
        let sddl = format!("O:{TRUSTED_INSTALLER}G:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;BU)");
        validate(&sddl, Part::Executable).unwrap();
    }

    #[test]
    fn rejects_user_owned_objects_even_with_a_read_only_dacl() {
        assert!(validate(
            "O:S-1-5-21-1-2-3-1001G:BAD:P(A;;FRFX;;;BU)(A;;FA;;;SY)(A;;FA;;;BA)",
            Part::Executable
        )
        .is_err());
    }

    #[test]
    fn rejects_null_or_missing_dacls() {
        assert!(validate("O:BAG:BAD:NO_ACCESS_CONTROL", Part::Executable).is_err());
        assert!(validate("O:BAG:BA", Part::Executable).is_err());
    }

    #[test]
    fn rejects_untrusted_write_delete_and_permission_changes() {
        for rights in ["GW", "GA", "SD", "WD", "WO", "0x2", "0x4", "0x100"] {
            let sddl = format!("O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;{rights};;;BU)");
            assert!(validate(&sddl, Part::Executable).is_err(), "{rights}");
        }
    }

    #[test]
    fn rejects_attribute_changes_on_ancestor_directories() {
        let sddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x100;;;AU)";
        assert!(validate(sddl, Part::Ancestor).is_err());
        assert!(validate(sddl, Part::Directory).is_err());
    }

    #[test]
    fn rejects_delete_child_on_any_directory() {
        let sddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x40;;;AU)";
        assert!(validate(sddl, Part::Ancestor).is_err());
        assert!(validate(sddl, Part::Directory).is_err());
    }

    #[test]
    fn creating_an_unrelated_ancestor_entry_does_not_replace_the_existing_path() {
        let sddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x4;;;AU)";
        validate(sddl, Part::Ancestor).unwrap();
        assert!(validate(sddl, Part::Directory).is_err());
        assert!(validate(sddl, Part::Executable).is_err());
    }

    #[test]
    fn inherit_only_rules_do_not_grant_access_to_the_existing_object() {
        let sddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;OICIIO;GA;;;CO)(A;;FRFX;;;BU)";
        validate(sddl, Part::Directory).unwrap();
    }

    #[test]
    fn an_unknown_allow_rule_is_not_assumed_safe() {
        let sddl = "O:BAG:BAD:P(A;;FA;;;SY)(XA;;FA;;;BU;(@User.Title == \"Writer\"))";
        assert!(validate(sddl, Part::Executable).is_err());
    }

    #[test]
    fn a_system_executable_with_default_windows_permissions_is_accepted() {
        let root = std::env::var_os("SystemRoot").expect("Windows sets SystemRoot");
        let executable = Path::new(&root).join("System32").join("svchost.exe");
        verify(&executable).unwrap();
    }
}
