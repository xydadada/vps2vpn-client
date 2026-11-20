const SYSTEM: &str = "S-1-5-18";
const ADMINISTRATORS: &str = "S-1-5-32-544";
pub(super) const TRUSTED_INSTALLER: &str =
    "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";

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
