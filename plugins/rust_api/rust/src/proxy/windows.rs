use std::collections::HashMap;
use std::ffi::c_void;
use std::mem::{size_of, zeroed};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, Once};
use std::time::Duration;

use windows_sys::core::PWSTR;
use windows_sys::Win32::Foundation::{
    GlobalFree, ERROR_INSUFFICIENT_BUFFER, ERROR_NOT_SUPPORTED, ERROR_NO_DATA, ERROR_SUCCESS, HWND,
    LPARAM, LRESULT, NO_ERROR, WPARAM,
};
use windows_sys::Win32::NetworkManagement::IpHelper::{
    GetExtendedTcpTable, MIB_TCP6ROW_OWNER_PID, MIB_TCPROW_OWNER_PID, TCP_TABLE_OWNER_PID_LISTENER,
};
use windows_sys::Win32::NetworkManagement::Rras::{
    RasEnumEntriesW, ERROR_BUFFER_TOO_SMALL, RASENTRYNAMEW,
};
use windows_sys::Win32::Networking::WinInet::{
    InternetQueryOptionW, InternetSetOptionW, INTERNET_OPTION_PER_CONNECTION_OPTION,
    INTERNET_OPTION_REFRESH, INTERNET_OPTION_SETTINGS_CHANGED, INTERNET_PER_CONN_AUTOCONFIG_URL,
    INTERNET_PER_CONN_FLAGS, INTERNET_PER_CONN_OPTIONW, INTERNET_PER_CONN_OPTIONW_0,
    INTERNET_PER_CONN_OPTION_LISTW, INTERNET_PER_CONN_PROXY_BYPASS, INTERNET_PER_CONN_PROXY_SERVER,
    PROXY_TYPE_AUTO_PROXY_URL, PROXY_TYPE_DIRECT, PROXY_TYPE_PROXY,
};
use windows_sys::Win32::Networking::WinSock::{AF_INET, AF_INET6};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, RegisterClassW,
    TranslateMessage, MSG, WM_ENDSESSION, WNDCLASSW,
};

use super::wininet::{bypass_list, local_pac_port, local_proxy_port};
use super::{Target, PROXY_HOST};

static APPLIED: AtomicBool = AtomicBool::new(false);
static SETTINGS: Mutex<Option<Restore>> = Mutex::new(None);

#[derive(Debug, Clone, PartialEq, Eq)]
struct Settings {
    flags: u32,
    server: String,
    bypass: String,
    pac: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Ours {
    Server(String),
    Pac(String),
}

impl Settings {
    fn is(&self, ours: &Ours) -> bool {
        match ours {
            Ours::Server(server) => self.flags & PROXY_TYPE_PROXY != 0 && &self.server == server,
            Ours::Pac(url) => self.flags & PROXY_TYPE_AUTO_PROXY_URL != 0 && &self.pac == url,
        }
    }
}

struct Restore {
    ours: Ours,
    saved: Vec<(Option<String>, Settings)>,
}

pub fn start(target: &Target) -> bool {
    watch_session_end();
    let mut state = lock_settings();
    // A start that reports failure can still have written the setting.
    APPLIED.store(true, Ordering::SeqCst);
    let ours = match target {
        Target::Manual { port, .. } => Ours::Server(format!("{PROXY_HOST}:{port}")),
        Target::Pac { url } => Ours::Pac(url.clone()),
    };
    match state.as_mut() {
        Some(restore) => restore.ours = ours,
        None => {
            let saved = snapshot(&ours);
            *state = Some(Restore { ours, saved });
        }
    }
    match target {
        Target::Manual {
            port,
            bypass_domain,
        } => {
            let mut server = wide(&format!("{PROXY_HOST}:{port}"));
            let mut bypass = wide(&bypass_list(bypass_domain));
            apply_to_connections(&mut [
                flags_option(PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY),
                string_option(INTERNET_PER_CONN_PROXY_SERVER, server.as_mut_ptr()),
                string_option(INTERNET_PER_CONN_PROXY_BYPASS, bypass.as_mut_ptr()),
            ])
        }
        Target::Pac { url } => {
            let mut url = wide(url);
            apply_to_connections(&mut [
                flags_option(PROXY_TYPE_DIRECT | PROXY_TYPE_AUTO_PROXY_URL),
                string_option(INTERNET_PER_CONN_AUTOCONFIG_URL, url.as_mut_ptr()),
            ])
        }
    }
}

pub fn stop() -> bool {
    let mut state = lock_settings();
    stop_locked(&mut state)
}

fn stop_locked(state: &mut Option<Restore>) -> bool {
    let stopped = match state.take() {
        None => apply_to_connections(&mut [flags_option(PROXY_TYPE_DIRECT)]),
        Some(restore) => {
            let restored = restore_connections(&restore);
            if !restored {
                *state = Some(restore);
            }
            restored
        }
    };
    if stopped {
        APPLIED.store(false, Ordering::SeqCst);
    }
    stopped
}

fn snapshot(ours: &Ours) -> Vec<(Option<String>, Settings)> {
    let mut saved = Vec::new();
    for_each_connection(|connection| {
        if let Some(mut settings) = read_settings(connection) {
            // Left by an earlier run of this app: nothing to go back to.
            if settings.is(ours) {
                settings.flags = PROXY_TYPE_DIRECT;
            }
            saved.push((connection_name(connection), settings));
        }
        true
    });
    saved
}

fn restore_connections(restore: &Restore) -> bool {
    let mut changed = false;
    let restored = for_each_connection(|connection| {
        let Some(current) = read_settings(connection) else {
            return false;
        };
        let name = connection_name(connection);
        let saved = restore
            .saved
            .iter()
            .find(|(saved_name, _)| *saved_name == name)
            .map(|(_, settings)| settings);
        match restored_settings(&current, &restore.ours, saved, |port| {
            !is_port_listening(port)
        }) {
            Some(target) if target != current => {
                changed = true;
                write_settings(connection, &target)
            }
            _ => true,
        }
    });
    let notified = !changed || notify_settings_changed();
    restored && notified
}

/// What a stop writes back: `None` leaves a connection someone else changed
/// since this run's start alone. A saved local proxy or PAC whose port no
/// longer listens (the app the takeover closed) is not brought back.
fn restored_settings(
    current: &Settings,
    ours: &Ours,
    saved: Option<&Settings>,
    mut is_released: impl FnMut(u16) -> bool,
) -> Option<Settings> {
    if !current.is(ours) {
        return None;
    }
    let Some(saved) = saved else {
        return Some(Settings {
            flags: PROXY_TYPE_DIRECT,
            ..current.clone()
        });
    };
    let mut flags = saved.flags | PROXY_TYPE_DIRECT;
    if flags & PROXY_TYPE_PROXY != 0
        && local_proxy_port(&saved.server).is_some_and(&mut is_released)
    {
        flags &= !PROXY_TYPE_PROXY;
    }
    if flags & PROXY_TYPE_AUTO_PROXY_URL != 0
        && local_url_port(&saved.pac).is_some_and(&mut is_released)
    {
        flags &= !PROXY_TYPE_AUTO_PROXY_URL;
    }
    Some(Settings {
        flags,
        ..saved.clone()
    })
}

/// The port of any loopback `http://<host>:<port>/...` URL, another app's
/// PAC too, however the scheme and host are cased.
fn local_url_port(url: &str) -> Option<u16> {
    if !url.get(..7)?.eq_ignore_ascii_case("http://") {
        return None;
    }
    let authority = url[7..].split(['/', '?', '#']).next()?;
    let (host, port) = authority.rsplit_once(':')?;
    if !["127.0.0.1", "localhost", "[::1]"]
        .iter()
        .any(|local| host.eq_ignore_ascii_case(local))
    {
        return None;
    }
    local_proxy_port(&format!("{PROXY_HOST}:{port}"))
}

fn connection_name(connection: PWSTR) -> Option<String> {
    (!connection.is_null()).then(|| unsafe { read_wide_string(connection) })
}

fn read_settings(connection: PWSTR) -> Option<Settings> {
    let mut options = [
        flags_option(0),
        string_option(INTERNET_PER_CONN_PROXY_SERVER, null_mut()),
        string_option(INTERNET_PER_CONN_PROXY_BYPASS, null_mut()),
        string_option(INTERNET_PER_CONN_AUTOCONFIG_URL, null_mut()),
    ];
    let mut list = option_list(connection, &mut options);
    let mut size = size_of::<INTERNET_PER_CONN_OPTION_LISTW>() as u32;
    let queried = unsafe {
        InternetQueryOptionW(
            null(),
            INTERNET_OPTION_PER_CONNECTION_OPTION,
            (&mut list as *mut INTERNET_PER_CONN_OPTION_LISTW).cast(),
            &mut size,
        ) != 0
    };
    let [server, bypass, pac] =
        [1, 2, 3].map(|i| unsafe { take_global_string(options[i].Value.pszValue) });
    queried.then(|| Settings {
        flags: unsafe { options[0].Value.dwValue },
        server,
        bypass,
        pac,
    })
}

fn write_settings(connection: PWSTR, settings: &Settings) -> bool {
    let mut server = wide(&settings.server);
    let mut bypass = wide(&settings.bypass);
    let mut pac = wide(&settings.pac);
    set_options(
        connection,
        &mut [
            flags_option(settings.flags),
            string_option(INTERNET_PER_CONN_PROXY_SERVER, server.as_mut_ptr()),
            string_option(INTERNET_PER_CONN_PROXY_BYPASS, bypass.as_mut_ptr()),
            string_option(INTERNET_PER_CONN_AUTOCONFIG_URL, pac.as_mut_ptr()),
        ],
    )
}

/// Clears a `127.0.0.1:<port>` proxy or PAC URL that nothing listens behind. The
/// installer and uninstaller call it after killing the app, whose exit path is
/// what normally turns the system proxy off.
fn clear_stale() -> Result<usize, ()> {
    let _settings = lock_settings();
    // This process set it: the startup sweep runs on its own thread and can
    // come after a connect made before the Core listens. Only another run's
    // leftover is stale.
    if APPLIED.load(Ordering::SeqCst) {
        return Ok(0);
    }
    let mut released = HashMap::new();
    let mut count = 0;
    let cleared = for_each_connection(|connection| {
        clear_stale_for_connection(connection, &mut released, &mut count)
    });
    let notified = count == 0 || notify_settings_changed();
    if cleared && notified {
        Ok(count)
    } else {
        Err(())
    }
}

#[no_mangle]
pub extern "C" fn flclash_clear_stale_proxy() -> bool {
    clear_stale().is_ok()
}

#[no_mangle]
pub extern "C" fn flclash_clear_stale_proxy_count() -> i32 {
    clear_stale().map_or(-1, |count| count as i32)
}

fn lock_settings() -> MutexGuard<'static, Option<Restore>> {
    SETTINGS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn wide(value: &str) -> Vec<u16> {
    value
        .encode_utf16()
        .filter(|&unit| unit != 0)
        .chain(std::iter::once(0))
        .collect()
}

fn flags_option(flags: u32) -> INTERNET_PER_CONN_OPTIONW {
    INTERNET_PER_CONN_OPTIONW {
        dwOption: INTERNET_PER_CONN_FLAGS,
        Value: INTERNET_PER_CONN_OPTIONW_0 { dwValue: flags },
    }
}

fn string_option(kind: u32, value: PWSTR) -> INTERNET_PER_CONN_OPTIONW {
    INTERNET_PER_CONN_OPTIONW {
        dwOption: kind,
        Value: INTERNET_PER_CONN_OPTIONW_0 { pszValue: value },
    }
}

fn option_list(
    connection: PWSTR,
    options: &mut [INTERNET_PER_CONN_OPTIONW],
) -> INTERNET_PER_CONN_OPTION_LISTW {
    INTERNET_PER_CONN_OPTION_LISTW {
        dwSize: size_of::<INTERNET_PER_CONN_OPTION_LISTW>() as u32,
        pszConnection: connection,
        dwOptionCount: options.len() as u32,
        dwOptionError: 0,
        pOptions: options.as_mut_ptr(),
    }
}

fn set_options(connection: PWSTR, options: &mut [INTERNET_PER_CONN_OPTIONW]) -> bool {
    let list = option_list(connection, options);
    unsafe {
        InternetSetOptionW(
            null(),
            INTERNET_OPTION_PER_CONNECTION_OPTION,
            (&list as *const INTERNET_PER_CONN_OPTION_LISTW).cast(),
            size_of::<INTERNET_PER_CONN_OPTION_LISTW>() as u32,
        ) != 0
    }
}

fn apply_to_connections(options: &mut [INTERNET_PER_CONN_OPTIONW]) -> bool {
    let mut changed = false;
    let applied = for_each_connection(|connection| {
        if options_match(connection, options) {
            return true;
        }
        changed = true;
        set_options(connection, options)
    });
    let notified = !changed || notify_settings_changed();
    applied && notified
}

fn options_match(connection: PWSTR, expected: &[INTERNET_PER_CONN_OPTIONW]) -> bool {
    let mut actual: Vec<_> = expected
        .iter()
        .map(|option| string_option(option.dwOption, null_mut()))
        .collect();
    let mut list = option_list(connection, &mut actual);
    let mut size = size_of::<INTERNET_PER_CONN_OPTION_LISTW>() as u32;
    let queried = unsafe {
        InternetQueryOptionW(
            null(),
            INTERNET_OPTION_PER_CONNECTION_OPTION,
            (&mut list as *mut INTERNET_PER_CONN_OPTION_LISTW).cast(),
            &mut size,
        ) != 0
    };
    let mut matches = queried;
    for (actual, expected) in actual.iter().zip(expected) {
        if actual.dwOption == INTERNET_PER_CONN_FLAGS {
            matches &= unsafe { actual.Value.dwValue == expected.Value.dwValue };
        } else {
            let value = unsafe { take_global_string(actual.Value.pszValue) };
            matches &= value == unsafe { read_wide_string(expected.Value.pszValue) };
        }
    }
    matches
}

fn notify_settings_changed() -> bool {
    let changed =
        unsafe { InternetSetOptionW(null(), INTERNET_OPTION_SETTINGS_CHANGED, null(), 0) != 0 };
    let refreshed = unsafe { InternetSetOptionW(null(), INTERNET_OPTION_REFRESH, null(), 0) != 0 };
    changed && refreshed
}

/// The LAN settings, then every dial-up and VPN entry, each of which keeps
/// its own proxy configuration.
fn for_each_connection(mut visit: impl FnMut(PWSTR) -> bool) -> bool {
    let mut success = visit(null_mut());
    let entry_size = size_of::<RASENTRYNAMEW>();
    let mut entries: Vec<RASENTRYNAMEW> = Vec::new();
    let mut size = 0u32;
    let mut count = 0u32;
    let mut ret = ERROR_BUFFER_TOO_SMALL;
    for _ in 0..3 {
        let ptr = if entries.is_empty() {
            null_mut()
        } else {
            entries.as_mut_ptr()
        };
        ret = unsafe { RasEnumEntriesW(null(), null(), ptr, &mut size, &mut count) };
        if ret != ERROR_BUFFER_TOO_SMALL || size == 0 {
            break;
        }
        let len = (count as usize)
            .max((size as usize).div_ceil(entry_size))
            .max(1);
        entries.clear();
        entries.resize(
            len,
            RASENTRYNAMEW {
                dwSize: entry_size as u32,
                ..Default::default()
            },
        );
        size = (len * entry_size) as u32;
    }
    if ret == ERROR_SUCCESS {
        let valid_count = (count as usize).min(entries.len());
        for entry in entries.iter_mut().take(valid_count) {
            success = visit(entry.szEntryName.as_mut_ptr()) && success;
        }
    } else {
        success = false;
    }
    success
}

fn clear_stale_for_connection(
    connection: PWSTR,
    released: &mut HashMap<u16, bool>,
    count: &mut usize,
) -> bool {
    let mut options = [
        flags_option(0),
        string_option(INTERNET_PER_CONN_PROXY_SERVER, null_mut()),
        string_option(INTERNET_PER_CONN_AUTOCONFIG_URL, null_mut()),
    ];
    let mut list = option_list(connection, &mut options);
    let mut size = size_of::<INTERNET_PER_CONN_OPTION_LISTW>() as u32;
    let queried = unsafe {
        InternetQueryOptionW(
            null(),
            INTERNET_OPTION_PER_CONNECTION_OPTION,
            (&mut list as *mut INTERNET_PER_CONN_OPTION_LISTW).cast(),
            &mut size,
        ) != 0
    };
    if !queried {
        unsafe {
            for option in &options[1..] {
                if !option.Value.pszValue.is_null() {
                    GlobalFree(option.Value.pszValue.cast());
                }
            }
        }
        return false;
    }
    let flags = unsafe { options[0].Value.dwValue };
    let server = unsafe { take_global_string(options[1].Value.pszValue) };
    let pac_url = unsafe { take_global_string(options[2].Value.pszValue) };
    let cleared = stale_cleared_flags(flags, &server, &pac_url, |port: u16| {
        *released
            .entry(port)
            .or_insert_with(|| is_port_released(port))
    });
    if cleared == flags {
        return true;
    }
    let changed = set_options(connection, &mut [flags_option(cleared | PROXY_TYPE_DIRECT)]);
    if changed {
        *count += 1;
    }
    changed
}

/// The flags a connection keeps once a `127.0.0.1:<port>` proxy or PAC URL
/// that nothing listens behind is dropped. Any other proxy, and a local one
/// whose port is in use, stays as it is.
fn stale_cleared_flags(
    flags: u32,
    server: &str,
    pac_url: &str,
    mut is_released: impl FnMut(u16) -> bool,
) -> u32 {
    let mut cleared = flags;
    if flags & PROXY_TYPE_PROXY != 0 && local_proxy_port(server).is_some_and(&mut is_released) {
        cleared &= !PROXY_TYPE_PROXY;
    }
    if flags & PROXY_TYPE_AUTO_PROXY_URL != 0
        && local_pac_port(pac_url).is_some_and(&mut is_released)
    {
        cleared &= !PROXY_TYPE_AUTO_PROXY_URL;
    }
    cleared
}

unsafe fn take_global_string(value: PWSTR) -> String {
    let text = read_wide_string(value);
    if !value.is_null() {
        GlobalFree(value.cast());
    }
    text
}

unsafe fn read_wide_string(value: PWSTR) -> String {
    if value.is_null() {
        return String::new();
    }
    let mut len = 0;
    while *value.add(len) != 0 {
        len += 1;
    }
    String::from_utf16_lossy(std::slice::from_raw_parts(value, len))
}

/// `taskkill /f` returns once TerminateProcess has been issued, which is
/// before the killed Core has released its listening socket.
fn is_port_released(port: u16) -> bool {
    for _ in 0..20 {
        if !is_port_listening(port) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    false
}

/// A lookup that fails counts as listening, so a live proxy is never cleared.
fn is_port_listening(port: u16) -> bool {
    [AF_INET, AF_INET6]
        .into_iter()
        .any(|family| has_listener(u32::from(family), port).unwrap_or(true))
}

fn has_listener(family: u32, port: u16) -> Option<bool> {
    // u32 words keep the table's rows aligned.
    let mut buffer: Vec<u32> = Vec::new();
    let mut size = 0u32;
    let mut result = ERROR_INSUFFICIENT_BUFFER;
    for _ in 0..3 {
        if result != ERROR_INSUFFICIENT_BUFFER {
            break;
        }
        buffer.resize((size as usize).div_ceil(size_of::<u32>()), 0);
        let table = if buffer.is_empty() {
            null_mut()
        } else {
            buffer.as_mut_ptr().cast::<c_void>()
        };
        result = unsafe {
            GetExtendedTcpTable(table, &mut size, 0, family, TCP_TABLE_OWNER_PID_LISTENER, 0)
        };
    }
    if result == NO_ERROR && size == 0 {
        return Some(false);
    }
    if family == u32::from(AF_INET6)
        && (result == ERROR_NOT_SUPPORTED || result == ERROR_NO_DATA)
    {
        return Some(false);
    }
    if result != NO_ERROR || buffer.is_empty() {
        return None;
    }
    let found = unsafe {
        if family == u32::from(AF_INET) {
            rows::<MIB_TCPROW_OWNER_PID>(&buffer)?.any(|row| {
                local_port(row.dwLocalPort) == port && is_local_v4(row.dwLocalAddr)
            })
        } else {
            rows::<MIB_TCP6ROW_OWNER_PID>(&buffer)?.any(|row| {
                local_port(row.dwLocalPort) == port && is_local_v6(row.ucLocalAddr)
            })
        }
    };
    Some(found)
}

unsafe fn rows<Row>(table: &[u32]) -> Option<std::slice::Iter<'_, Row>> {
    let &count = table.first()?;
    let count = count as usize;
    let byte_len = table.len() * size_of::<u32>();
    let required = count
        .checked_mul(size_of::<Row>())
        .and_then(|bytes| size_of::<u32>().checked_add(bytes))?;
    if required > byte_len {
        return None;
    }
    if count == 0 {
        return Some([].iter());
    }
    let ptr = table.as_ptr().add(1).cast::<Row>();
    if !ptr.is_aligned() {
        return None;
    }
    Some(std::slice::from_raw_parts(ptr, count).iter())
}

fn is_local_v4(address: u32) -> bool {
    let addr = Ipv4Addr::from(address.to_ne_bytes());
    addr == Ipv4Addr::LOCALHOST || addr == Ipv4Addr::UNSPECIFIED
}

fn is_local_v6(address: [u8; 16]) -> bool {
    let addr = Ipv6Addr::from(address);
    addr == Ipv6Addr::LOCALHOST || addr == Ipv6Addr::UNSPECIFIED
}

fn local_port(value: u32) -> u16 {
    u16::from_be(value as u16)
}

/// Shutting Windows down kills the process without running the Dart exit
/// path, so the setting would survive into a boot with nothing listening
/// behind it. Every top-level window hears `WM_ENDSESSION`, hidden ones too,
/// so this one needs nothing from the Flutter window.
fn watch_session_end() {
    static WATCH: Once = Once::new();
    WATCH.call_once(|| {
        let _ = std::thread::Builder::new()
            .name("system-proxy-session".into())
            .spawn(run_session_window);
    });
}

fn run_session_window() {
    unsafe {
        let instance = GetModuleHandleW(null());
        let class = wide("vps2vpnSystemProxySession");
        let window_class = WNDCLASSW {
            lpfnWndProc: Some(session_window_proc),
            hInstance: instance,
            lpszClassName: class.as_ptr(),
            ..zeroed()
        };
        if RegisterClassW(&window_class) == 0 {
            return;
        }
        let window = CreateWindowExW(
            0,
            class.as_ptr(),
            null(),
            0,
            0,
            0,
            0,
            0,
            null_mut(),
            null_mut(),
            instance,
            null(),
        );
        if window.is_null() {
            return;
        }
        let mut message: MSG = zeroed();
        while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
}

unsafe extern "system" fn session_window_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_ENDSESSION && wparam != 0 && APPLIED.load(Ordering::SeqCst) {
        let mut settings = lock_settings();
        stop_locked(&mut settings);
        return 0;
    }
    DefWindowProcW(window, message, wparam, lparam)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MANUAL: u32 = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;
    const PAC: u32 = PROXY_TYPE_DIRECT | PROXY_TYPE_AUTO_PROXY_URL;

    #[test]
    fn drops_a_local_proxy_nothing_listens_behind() {
        let cleared = stale_cleared_flags(MANUAL, "127.0.0.1:7890", "", |port| port == 7890);
        assert_eq!(cleared, PROXY_TYPE_DIRECT);
    }

    #[test]
    fn keeps_a_local_proxy_another_app_listens_behind() {
        let cleared = stale_cleared_flags(MANUAL, "127.0.0.1:7897", "", |_| false);
        assert_eq!(cleared, MANUAL);
    }

    #[test]
    fn never_looks_at_a_proxy_this_app_does_not_write() {
        for server in ["10.0.0.1:7890", "http=127.0.0.1:7890", "localhost:7890", ""] {
            let cleared = stale_cleared_flags(MANUAL, server, "", |_| {
                panic!("checked the port of {server:?}")
            });
            assert_eq!(cleared, MANUAL, "{server}");
        }
    }

    #[test]
    fn leaves_a_server_alone_while_the_proxy_is_switched_off() {
        let cleared = stale_cleared_flags(PROXY_TYPE_DIRECT, "127.0.0.1:7890", "", |_| true);
        assert_eq!(cleared, PROXY_TYPE_DIRECT);
    }

    fn settings(flags: u32, server: &str, pac: &str) -> Settings {
        Settings {
            flags,
            server: server.into(),
            bypass: "<local>".into(),
            pac: pac.into(),
        }
    }

    fn ours() -> Ours {
        Ours::Server("127.0.0.1:7890".into())
    }

    #[test]
    fn a_stop_puts_back_the_proxy_that_was_there_before() {
        let current = settings(MANUAL, "127.0.0.1:7890", "");
        for before in [
            settings(MANUAL, "proxy.corp.example:8080", ""),
            settings(MANUAL, "127.0.0.1:10808", ""),
            settings(PAC, "", "http://127.0.0.1:10810/pac/proxy.js"),
            settings(PROXY_TYPE_DIRECT, "old:1", ""),
        ] {
            let restored = restored_settings(&current, &ours(), Some(&before), |_| false);
            assert_eq!(restored, Some(before.clone()), "{before:?}");
        }
    }

    #[test]
    fn a_stop_does_not_bring_back_a_local_proxy_whose_app_is_gone() {
        let current = settings(MANUAL, "127.0.0.1:7890", "");
        let pac = "http://127.0.0.1:33331/commands/pac";
        let before = settings(MANUAL | PAC, "127.0.0.1:7897", pac);
        let restored = restored_settings(&current, &ours(), Some(&before), |port| port == 7897);
        assert_eq!(restored, Some(settings(PAC, "127.0.0.1:7897", pac)));
        let restored = restored_settings(&current, &ours(), Some(&before), |_| true);
        assert_eq!(restored.unwrap().flags, PROXY_TYPE_DIRECT);
    }

    #[test]
    fn a_stop_leaves_a_proxy_someone_set_after_this_run() {
        let before = settings(MANUAL, "proxy.corp.example:8080", "");
        for current in [
            settings(MANUAL, "127.0.0.1:10808", ""),
            settings(PROXY_TYPE_DIRECT, "127.0.0.1:7890", ""),
            settings(PAC, "127.0.0.1:7890", "http://127.0.0.1:10810/pac/"),
        ] {
            let restored = restored_settings(&current, &ours(), Some(&before), |_| true);
            assert_eq!(restored, None, "{current:?}");
        }
    }

    #[test]
    fn a_stop_with_nothing_saved_turns_the_proxy_off() {
        let current = settings(MANUAL, "127.0.0.1:7890", "");
        let restored = restored_settings(&current, &ours(), None, |_| false).unwrap();
        assert_eq!(restored.flags, PROXY_TYPE_DIRECT);
        let pac = Ours::Pac("http://127.0.0.1:51234/flclash.pac?v=3".into());
        let current = settings(PAC, "", "http://127.0.0.1:51234/flclash.pac?v=3");
        let restored = restored_settings(&current, &pac, None, |_| false).unwrap();
        assert_eq!(restored.flags, PROXY_TYPE_DIRECT);
    }

    #[test]
    fn reads_the_port_of_any_local_url() {
        assert_eq!(local_url_port("http://127.0.0.1:10810/pac/proxy.js"), Some(10810));
        assert_eq!(local_url_port("http://127.0.0.1:33331?x"), Some(33331));
        assert_eq!(local_url_port("http://127.0.0.1:33331"), Some(33331));
        assert_eq!(local_url_port("http://10.0.0.1:80/pac"), None);
        assert_eq!(local_url_port("https://127.0.0.1:443/pac"), None);
        assert_eq!(local_url_port("http://localhost:33331/pac"), Some(33331));
        assert_eq!(local_url_port("HTTP://LOCALHOST:33331/pac"), Some(33331));
        assert_eq!(local_url_port("http://[::1]:33331/pac"), Some(33331));
        assert_eq!(local_url_port("http://evil.localhost:33331/pac"), None);
        assert_eq!(local_url_port("http://127.0.0.1/pac"), None);
    }

    #[test]
    fn drops_only_the_part_that_went_stale() {
        let pac_url = "http://127.0.0.1:51234/flclash.pac?v=3";
        let both = MANUAL | PAC;
        let cleared = stale_cleared_flags(both, "127.0.0.1:7890", pac_url, |port| port == 51234);
        assert_eq!(cleared, MANUAL);
        let other_pac = "http://127.0.0.1:51234/proxy.pac";
        assert_eq!(stale_cleared_flags(PAC, "", other_pac, |_| true), PAC);
    }
}
