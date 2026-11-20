pub mod hub;
#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(any(all(feature = "windows-service", target_os = "windows"), test))]
pub mod owner;
#[cfg(all(feature = "windows-service", target_os = "windows"))]
pub mod peer;
#[cfg(all(feature = "windows-service", target_os = "windows"))]
pub mod windows;
#[cfg(target_os = "linux")]
#[path = "install_path_linux.rs"]
mod install_path;
#[cfg(windows)]
#[path = "install_path_windows.rs"]
mod install_path;
