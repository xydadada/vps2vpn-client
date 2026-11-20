use std::fs;
use std::path::{Path, PathBuf};

pub fn autostart_enabled(id: &str, executable: &str) -> bool {
    home().is_some_and(|home| entry_enabled(&home, id, executable))
}

pub fn set_autostart(id: &str, display_name: &str, executable: &str, enabled: bool) -> bool {
    home().is_some_and(|home| write_autostart(&home, id, display_name, executable, enabled))
}

/// $HOME/.config/autostart is also where launch_at_startup wrote its entries.
fn desktop_file(home: &Path, id: &str) -> PathBuf {
    home.join(".config/autostart").join(format!("{id}.desktop"))
}

fn entry_enabled(home: &Path, id: &str, executable: &str) -> bool {
    fs::read_to_string(desktop_file(home, id)).is_ok_and(|entry| entry_matches(&entry, executable))
}

fn entry_matches(entry: &str, executable: &str) -> bool {
    let Some(expected) = quoted_executable(executable) else {
        return false;
    };
    let mut in_entry = false;
    let mut command = None;
    for line in entry.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim();
        match key.trim() {
            "Exec" => {
                if command.replace(value).is_some() {
                    return false;
                }
            }
            "Hidden" if value == "true" => return false,
            "X-GNOME-Autostart-enabled" if value == "false" => return false,
            _ => {}
        }
    }
    command.is_some_and(|command| {
        command == expected
            // Old entries with a simple unquoted path are still usable.
            || (command == executable && plain_executable(executable))
    })
}

fn plain_executable(executable: &str) -> bool {
    executable.chars().all(|character| {
        !character.is_whitespace()
            && !character.is_control()
            && !"\"'\\><~|&;$*?#()\u{60}%=".contains(character)
    })
}

/// Desktop string escaping is applied after Exec argument quoting. Readers
/// decode the string before parsing the command, so a literal backslash in a
/// quoted path needs four backslashes in the file.
fn escaped_value(value: &str) -> Option<String> {
    let mut escaped = String::new();
    for character in value.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            character if character.is_control() => return None,
            character => escaped.push(character),
        }
    }
    Some(escaped)
}

fn quoted_executable(executable: &str) -> Option<String> {
    // The desktop entry specification forbids "=" in executable names.
    if executable.is_empty() || executable.contains('=') {
        return None;
    }
    let mut quoted = String::from("\"");
    for character in executable.chars() {
        match character {
            '"' | '\\' | '$' | '\u{60}' => {
                quoted.push('\\');
                quoted.push(character);
            }
            '%' => quoted.push_str("%%"),
            character => quoted.push(character),
        }
    }
    quoted.push('"');
    escaped_value(&quoted)
}

fn desktop_entry(display_name: &str, executable: &str) -> Option<String> {
    let display_name = escaped_value(display_name)?;
    let executable = quoted_executable(executable)?;
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

fn write_autostart(
    home: &Path,
    id: &str,
    display_name: &str,
    executable: &str,
    enabled: bool,
) -> bool {
    let file = desktop_file(home, id);
    if enabled {
        let Some(entry) = desktop_entry(display_name, executable) else {
            return false;
        };
        file.parent()
            .is_some_and(|dir| fs::create_dir_all(dir).is_ok())
            && fs::write(&file, entry).is_ok()
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
        assert!(entry_enabled(&home, "FlClash", "/opt/FlClash/FlClash"));

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
    fn quotes_spaces_and_escapes_both_desktop_and_command_layers() {
        assert_eq!(
            quoted_executable("/opt/App Files/app").unwrap(),
            r#""/opt/App Files/app""#
        );
        assert_eq!(
            quoted_executable(r#"/opt/a"b\c/$name"#).unwrap(),
            r#""/opt/a\\"b\\\\c/\\$name""#
        );
        assert_eq!(
            quoted_executable("/opt/a\u{60}b/100%/%f").unwrap(),
            "\"/opt/a\\\\\u{60}b/100%%/%%f\""
        );
    }

    #[test]
    fn line_breaks_stay_inside_values_instead_of_injecting_entries() {
        let executable = "/opt/line\nbreak\rwith\ttab";
        let entry = desktop_entry("App\nExec=other", executable).unwrap();
        assert_eq!(entry.lines().count(), 7);
        assert!(entry.contains("Name=App\\nExec=other\n"));
        assert!(entry.contains("Exec=\"/opt/line\\nbreak\\rwith\\ttab\"\n"));
        assert!(entry_matches(&entry, executable));
    }

    #[test]
    fn reads_simple_legacy_entries_and_rejects_broken_old_commands() {
        assert!(entry_matches(
            "[Desktop Entry]\nType=Application\nExec=/opt/app\n",
            "/opt/app"
        ));
        for executable in [
            "/opt/App Files/app",
            "/opt/100%/app",
            r"/opt/back\slash/app",
        ] {
            let old = format!("[Desktop Entry]\nExec={executable}\n");
            assert!(!entry_matches(&old, executable), "{executable}");
            assert!(entry_matches(
                &desktop_entry("App", executable).unwrap(),
                executable
            ));
        }
    }

    #[test]
    fn repairs_legacy_entries_without_changing_their_location() {
        let home = temp_home("legacy");
        let file = desktop_file(&home, "App");
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, "[Desktop Entry]\nExec=/opt/App Files/app\n").unwrap();
        assert!(!entry_enabled(&home, "App", "/opt/App Files/app"));
        assert!(write_autostart(
            &home,
            "App",
            "App",
            "/opt/App Files/app",
            true
        ));
        assert!(entry_enabled(&home, "App", "/opt/App Files/app"));
        assert!(write_autostart(&home, "App", "", "", false));
        assert!(!file.exists());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn disabled_or_ambiguous_entries_are_not_reported_as_enabled() {
        let command = "Exec=\"/opt/app\"\n";
        for suffix in [
            "Hidden=true\n",
            "X-GNOME-Autostart-enabled=false\n",
            command,
        ] {
            let entry = format!("[Desktop Entry]\n{command}{suffix}");
            assert!(!entry_matches(&entry, "/opt/app"));
        }
        assert!(!entry_matches(
            "[Desktop Action Other]\nExec=\"/opt/app\"\n",
            "/opt/app"
        ));
    }

    #[test]
    fn invalid_exec_values_do_not_replace_the_previous_entry() {
        let home = temp_home("invalid");
        assert!(write_autostart(&home, "App", "App", "/opt/app", true));
        let file = desktop_file(&home, "App");
        let previous = fs::read(&file).unwrap();
        for executable in ["", "/opt/invalid=path", "/opt/nul\0path", "/opt/\u{7}"] {
            assert!(!write_autostart(&home, "App", "App", executable, true));
            assert_eq!(fs::read(&file).unwrap(), previous);
        }
        assert!(write_autostart(&home, "App", "", "", false));
        fs::remove_dir_all(home).unwrap();
    }

    #[cfg(target_os = "linux")]
    fn glib_arguments(entry: &str) -> Vec<String> {
        use std::ffi::{CStr, CString};
        use std::ptr::null_mut;

        let data = CString::new(entry).unwrap();
        let group = CString::new("Desktop Entry").unwrap();
        let key = CString::new("Exec").unwrap();
        // SAFETY: all inputs are live NUL-terminated strings. GLib-owned
        // strings and vectors are freed after copying; no command is executed.
        unsafe {
            let file = glib_sys::g_key_file_new();
            assert!(!file.is_null());
            let loaded = glib_sys::g_key_file_load_from_data(
                file,
                data.as_ptr(),
                entry.len(),
                glib_sys::G_KEY_FILE_NONE,
                null_mut(),
            );
            if loaded == 0 {
                glib_sys::g_key_file_unref(file);
                panic!("GLib rejected the desktop file");
            }
            let command =
                glib_sys::g_key_file_get_string(file, group.as_ptr(), key.as_ptr(), null_mut());
            glib_sys::g_key_file_unref(file);
            assert!(!command.is_null(), "GLib rejected the Exec string escapes");
            let mut count = 0;
            let mut arguments = null_mut();
            let parsed =
                glib_sys::g_shell_parse_argv(command, &mut count, &mut arguments, null_mut());
            glib_sys::g_free(command.cast());
            assert_ne!(parsed, 0, "GLib rejected the command quoting");
            let result = (0..count as usize)
                .map(|index| {
                    CStr::from_ptr(*arguments.add(index))
                        .to_string_lossy()
                        .into_owned()
                })
                .collect();
            glib_sys::g_strfreev(arguments);
            result
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn glib_decodes_the_entry_to_one_literal_executable_argument() {
        for executable in [
            "/opt/App Files/app",
            r#"/opt/a"quoted"directory/app"#,
            r"/opt/back\slash/app",
            "/opt/$variable/\u{60}command\u{60}/app",
            "/opt/line\nbreak\rwith\ttab/app",
            "/opt/名字/app",
        ] {
            let entry = desktop_entry("App", executable).unwrap();
            assert_eq!(glib_arguments(&entry), vec![executable]);
        }
        // Field-code expansion follows argument parsing; %% must still be
        // present at this stage, including where the filename contains "%f".
        let entry = desktop_entry("App", "/opt/100%/%f/app").unwrap();
        assert_eq!(glib_arguments(&entry), vec!["/opt/100%%/%%f/app"]);
    }
    #[test]
    fn quotes_exec_and_escapes_both_desktop_string_layers() {
        assert_eq!(
            quoted_executable("/opt/My App/app").as_deref(),
            Some(r#""/opt/My App/app""#),
        );
        assert_eq!(
            quoted_executable(r#"/tmp/a"b`c$d\e%f"#).as_deref(),
            Some(r#""/tmp/a\\"b\\`c\\$d\\\\e%%f""#),
        );
    }

    #[test]
    fn escapes_line_breaks_without_inserting_desktop_keys() {
        let entry = desktop_entry("App\nHidden=true", "/tmp/a\nb\tapp").unwrap();
        assert!(entry.contains("\nName=App\\nHidden=true\n"));
        assert!(entry.contains("\nExec=\"/tmp/a\\nb\\tapp\"\n"));
        assert_eq!(entry.lines().count(), 7);
    }

    #[test]
    fn refuses_an_invalid_executable_without_a_desktop_entry() {
        for executable in ["", "/tmp/a=b", "/tmp/a\0b"] {
            assert!(desktop_entry("App", executable).is_none());
        }
    }
}
