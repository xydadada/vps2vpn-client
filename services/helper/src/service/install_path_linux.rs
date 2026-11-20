use anyhow::{bail, Context, Result};
use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path};

pub(super) fn verify(executable: &Path) -> Result<Vec<File>> {
    let relative = executable
        .strip_prefix("/")
        .context("service executable must have an absolute path")?;
    verify_from(Path::new("/"), relative, 0).with_context(|| {
        format!(
            "{} is not a protected service executable; install the system package",
            executable.display()
        )
    })
}

// Every parent is checked before opening its child. Root-only ownership and
// write permissions keep this pathname trustworthy after the handles close.
fn verify_from(root: &Path, relative: &Path, owner: u32) -> Result<Vec<File>> {
    let names = relative
        .components()
        .map(|component| match component {
            Component::Normal(name) => Ok(name),
            _ => anyhow::bail!("service path must not contain traversal components"),
        })
        .collect::<Result<Vec<_>>>()?;
    if names.is_empty() {
        bail!("service executable path is empty");
    }
    let root_file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(root)
        .with_context(|| format!("open {}", root.display()))?;
    check(&root_file, root, owner, true)?;
    let mut handles = vec![root_file];
    let mut current = root.to_path_buf();
    for (index, name) in names.iter().enumerate() {
        current.push(name);
        let name = CString::new(name.as_bytes()).context("NUL in service path")?;
        // SAFETY: the parent fd and NUL-terminated name stay live for openat.
        let fd = unsafe {
            libc::openat(
                handles.last().unwrap().as_raw_fd(),
                name.as_ptr(),
                libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd == -1 {
            return Err(std::io::Error::last_os_error())
                .with_context(|| format!("open {}", current.display()));
        }
        // SAFETY: openat returned an owned descriptor.
        let file = unsafe { File::from_raw_fd(fd) };
        check(&file, &current, owner, index + 1 != names.len())?;
        handles.push(file);
    }
    Ok(handles)
}

fn check(file: &File, path: &Path, owner: u32, directory: bool) -> Result<()> {
    let metadata = file
        .metadata()
        .with_context(|| format!("inspect {}", path.display()))?;
    if metadata.uid() != owner || metadata.mode() & 0o022 != 0 {
        bail!(
            "{} must be owned by UID {owner} and not writable by group or others",
            path.display()
        );
    }
    if (directory && !metadata.is_dir()) || (!directory && !metadata.is_file()) {
        bail!(
            "{} must be a regular {} without symbolic links",
            path.display(),
            if directory { "directory" } else { "file" }
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let root = std::env::temp_dir().join(format!(
                "helper-install-path-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&root).unwrap();
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
            fs::create_dir_all(root.join("ancestor/install")).unwrap();
            fs::write(root.join("ancestor/install/helper"), b"fixture").unwrap();
            for directory in ["ancestor", "ancestor/install"] {
                fs::set_permissions(root.join(directory), fs::Permissions::from_mode(0o755)).unwrap();
            }
            fs::set_permissions(
                root.join("ancestor/install/helper"),
                fs::Permissions::from_mode(0o644),
            )
            .unwrap();
            Self(root)
        }

        fn verify(&self, relative: &str) -> Result<Vec<File>> {
            let owner = fs::metadata(&self.0).unwrap().uid();
            verify_from(&self.0, Path::new(relative), owner)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn accepts_a_protected_regular_file_and_every_ancestor() {
        let fixture = Fixture::new();
        assert_eq!(fixture.verify("ancestor/install/helper").unwrap().len(), 4);
    }

    #[test]
    fn rejects_a_writable_ancestor_above_the_immediate_parent() {
        let fixture = Fixture::new();
        fs::set_permissions(
            fixture.0.join("ancestor"),
            fs::Permissions::from_mode(0o777),
        )
        .unwrap();

        let error = fixture
            .verify("ancestor/install/helper")
            .unwrap_err()
            .to_string();
        assert!(error.contains("ancestor"), "{error}");
        assert!(error.contains("not writable"), "{error}");
    }

    #[test]
    fn rejects_a_writable_executable() {
        let fixture = Fixture::new();
        fs::set_permissions(
            fixture.0.join("ancestor/install/helper"),
            fs::Permissions::from_mode(0o666),
        )
        .unwrap();
        assert!(fixture.verify("ancestor/install/helper").is_err());
    }

    #[test]
    fn refuses_a_different_owner() {
        let fixture = Fixture::new();
        let owner = fs::metadata(&fixture.0).unwrap().uid();
        assert!(verify_from(
            &fixture.0,
            Path::new("ancestor/install/helper"),
            owner.wrapping_add(1)
        )
        .is_err());
    }

    #[test]
    fn refuses_symlinks_in_the_file_and_directory_positions() {
        let fixture = Fixture::new();
        symlink("ancestor/install/helper", fixture.0.join("helper-link")).unwrap();
        symlink("ancestor", fixture.0.join("directory-link")).unwrap();
        assert!(fixture.verify("helper-link").is_err());
        assert!(fixture.verify("directory-link/install/helper").is_err());
    }

    #[test]
    fn refuses_directory_leaves_and_parent_traversal() {
        let fixture = Fixture::new();
        assert!(fixture.verify("ancestor/install").is_err());
        assert!(fixture.verify("ancestor/install/../install/helper").is_err());
        assert!(fixture.verify("").is_err());
    }
}
