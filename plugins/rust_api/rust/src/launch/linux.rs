use std::fs;
use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

pub fn autostart_enabled(id: &str, _executable: &str) -> bool {
    home()
        .and_then(|home| desktop_file(&home, id))
        .and_then(|file| fs::read_to_string(file).ok())
        .is_some_and(|entry| entry_starts(&entry))
}

/// A session skips an entry marked `Hidden=true` (the XDG spec's "deleted")
/// or, on GNOME, `X-GNOME-Autostart-enabled=false`.
fn entry_starts(entry: &str) -> bool {
    let mut in_entry = false;
    for line in entry.lines().map(str::trim) {
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match (in_entry, key.trim(), value.trim()) {
            (true, "Hidden", "true") | (true, "X-GNOME-Autostart-enabled", "false") => {
                return false;
            }
            _ => {}
        }
    }
    true
}

pub fn set_autostart(id: &str, display_name: &str, executable: &str, enabled: bool) -> bool {
    home().is_some_and(|home| write_autostart(&home, id, display_name, executable, enabled))
}

fn is_valid_id(id: &str) -> bool {
    if id.is_empty() || id.contains(['/', '\\', '\0']) || id.contains("..") {
        return false;
    }
    let mut components = Path::new(id).components();
    matches!(components.next(), Some(Component::Normal(_))) && components.next().is_none()
}

/// `$HOME/.config/autostart`, not `$XDG_CONFIG_HOME`: the path the
/// `launch_at_startup` builds wrote to, so their entry stays ours.
fn desktop_file(home: &Path, id: &str) -> Option<PathBuf> {
    is_valid_id(id).then(|| home.join(".config/autostart").join(format!("{id}.desktop")))
}

fn desktop_string(value: &str) -> String {
    let escaped = value
        .replace('\\', "\\\\")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t");
    let leading_spaces = escaped.bytes().take_while(|&b| b == b' ').count();
    if leading_spaces > 0 {
        let mut out = String::with_capacity(escaped.len() + leading_spaces);
        for _ in 0..leading_spaces {
            out.push_str("\\s");
        }
        out.push_str(&escaped[leading_spaces..]);
        out
    } else {
        escaped
    }
}

fn executable_value(executable: &str) -> Option<String> {
    if executable.is_empty() || executable.contains(['=', '\0']) {
        return None;
    }
    let mut quoted = String::from("\"");
    for ch in executable.chars() {
        if matches!(ch, '"' | '`' | '$' | '\\') {
            quoted.push('\\');
        } else if ch == '%' {
            quoted.push('%');
        }
        quoted.push(ch);
    }
    quoted.push('"');
    Some(desktop_string(&quoted))
}

fn desktop_entry(display_name: &str, executable: &str) -> Option<String> {
    if display_name.contains('\0') {
        return None;
    }
    let display_name = desktop_string(display_name);
    let executable = executable_value(executable)?;
    Some(format!(
        "[Desktop Entry]\n\
         Type=Application\n\
         Name={display_name}\n\
         Comment={display_name} startup script\n\
         Exec={executable}\n\
         StartupNotify=false\n\
         Terminal=false\n"
    ))
}

fn write_atomically(dir: &Path, target: &Path, contents: &[u8]) -> std::io::Result<()> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let pid = std::process::id();
    let (temp_path, mut temp_file) = loop {
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let candidate = dir.join(format!(".autostart.{pid}.{n}.tmp"));
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => break (candidate, file),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    };
    let write_result = temp_file
        .write_all(contents)
        .and_then(|()| temp_file.flush());
    drop(temp_file);
    if let Err(error) = write_result {
        let _ = fs::remove_file(&temp_path);
        return Err(error);
    }
    if let Err(error) = fs::rename(&temp_path, target) {
        let _ = fs::remove_file(&temp_path);
        return Err(error);
    }
    Ok(())
}

fn write_autostart(
    home: &Path,
    id: &str,
    display_name: &str,
    executable: &str,
    enabled: bool,
) -> bool {
    let Some(file) = desktop_file(home, id) else {
        return false;
    };
    if enabled {
        let Some(entry) = desktop_entry(display_name, executable) else {
            return false;
        };
        let Some(dir) = file.parent() else {
            return false;
        };
        fs::create_dir_all(dir).is_ok() && write_atomically(dir, &file, entry.as_bytes()).is_ok()
    } else {
        match fs::remove_file(&file) {
            Ok(()) => true,
            Err(error) => error.kind() == std::io::ErrorKind::NotFound,
        }
    }
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|home| !home.is_empty())
        .map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_home(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("rust_api_autostart_{name}_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn writes_the_entry_the_launch_at_startup_builds_wrote() {
        let home = temp_home("write");
        let write =
            |enabled| write_autostart(&home, "FlClash", "FlClash", "/opt/FlClash/FlClash", enabled);
        assert!(write(true));

        let file = home.join(".config/autostart/FlClash.desktop");
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            "[Desktop Entry]\nType=Application\nName=FlClash\n\
             Comment=FlClash startup script\nExec=\"/opt/FlClash/FlClash\"\n\
             StartupNotify=false\nTerminal=false\n",
        );
        assert!(desktop_file(&home, "FlClash").unwrap().exists());

        assert!(write(false));
        assert!(!file.exists());
        assert!(write(false));
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn names_the_file_by_id_and_the_entry_by_display_name() {
        let home = temp_home("display");
        assert!(write_autostart(
            &home, "App id", "App Name", "/opt/app", true
        ));

        let file = home.join(".config/autostart/App id.desktop");
        let entry = fs::read_to_string(&file).unwrap();
        assert!(entry.contains("\nName=App Name\nComment=App Name startup script\n"));
        assert!(!home.join(".config/autostart/App Name.desktop").exists());

        assert!(write_autostart(
            &home, "App id", "App Name", "/opt/app", false
        ));
        assert!(!file.exists());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn quotes_exec_and_escapes_both_desktop_string_layers() {
        assert_eq!(
            executable_value("/opt/My App/app").as_deref(),
            Some(r#""/opt/My App/app""#),
        );
        assert_eq!(
            executable_value(r#"/tmp/a"b`c$d\e%f"#).as_deref(),
            Some(r#""/tmp/a\\"b\\`c\\$d\\\\e%%f""#),
        );
    }

    #[test]
    fn escapes_line_breaks_and_leading_spaces_without_inserting_desktop_keys() {
        let entry = desktop_entry(" App\nHidden=true", "/tmp/a\nb\tapp").unwrap();
        assert!(entry.contains("\nName=\\sApp\\nHidden=true\n"));
        assert!(entry.contains("\nExec=\"/tmp/a\\nb\\tapp\"\n"));
        assert_eq!(entry.lines().count(), 7);
    }

    #[test]
    fn an_entry_the_desktop_hid_does_not_start() {
        let ours = desktop_entry("App", "/opt/app").unwrap();
        assert!(entry_starts(&ours));
        let with = |extra: &str| format!("{ours}{extra}");
        assert!(!entry_starts(&with("Hidden=true")));
        assert!(!entry_starts(&with("X-GNOME-Autostart-enabled = false")));
        assert!(entry_starts(&with("Hidden=false")));
        assert!(entry_starts(&with("[Desktop Action x]\nHidden=true")));

        let home = temp_home("hidden");
        assert!(write_autostart(&home, "App", "App", "/opt/app", true));
        let file = desktop_file(&home, "App").unwrap();
        fs::write(&file, with("Hidden=true")).unwrap();
        assert!(!entry_starts(&fs::read_to_string(&file).unwrap()));
        assert!(write_autostart(&home, "App", "App", "/opt/app", true));
        assert!(entry_starts(&fs::read_to_string(&file).unwrap()));
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn refuses_an_invalid_executable_display_name_or_id() {
        for executable in ["", "/tmp/a=b", "/tmp/a\0b"] {
            assert!(desktop_entry("App", executable).is_none());
        }
        assert!(desktop_entry("Bad\0Name", "/opt/app").is_none());
        let home = temp_home("invalid_id");
        for id in ["", ".", "..", "../escape", "a/b", r"a\b", "a\0b", "a..b"] {
            assert!(desktop_file(&home, id).is_none(), "expected invalid id {id:?}");
            assert!(!write_autostart(&home, id, "App", "/opt/app", true));
        }
    }
}
