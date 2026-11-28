#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <thread>

#include "flutter_window.h"
#include "rust_api.h"
#include "utils.h"

namespace {

class ScopedComInitializer {
 public:
  explicit ScopedComInitializer(HRESULT hr) : initialized_(SUCCEEDED(hr)) {}
  ~ScopedComInitializer() {
    if (initialized_) {
      ::CoUninitialize();
    }
  }

  ScopedComInitializer(const ScopedComInitializer&) = delete;
  ScopedComInitializer& operator=(const ScopedComInitializer&) = delete;

 private:
  bool initialized_;
};

}  // namespace

// The installer and the uninstaller run this after killing the app, whose exit
// path is what normally turns the system proxy off.
constexpr char kClearStaleProxyArgument[] = "--clear-stale-proxy";

bool ClearStaleProxy() {
  const auto clear_stale_proxy =
      RustApiFunction<int (*)()>("flclash_clear_stale_proxy_count");
  if (clear_stale_proxy == nullptr) return false;
  const int count = clear_stale_proxy();
  const std::string output = std::to_string(count) + "\n";
  HANDLE out = ::GetStdHandle(STD_OUTPUT_HANDLE);
  if (out != nullptr && out != INVALID_HANDLE_VALUE) {
    DWORD written = 0;
    ::WriteFile(out, output.data(), static_cast<DWORD>(output.size()),
                &written, nullptr);
  }
  return count >= 0;
}

HWND FindRunningWindow() {
  const auto find_running_window =
      RustApiFunction<HWND (*)()>("flclash_find_running_window");
  return find_running_window == nullptr ? nullptr : find_running_window();
}

void ForwardLinks(HWND window) {
  if (const auto forward_links =
          RustApiFunction<void (*)(HWND)>("flclash_forward_links")) {
    forward_links(window);
  }
}

// A run that crashed or was killed never reached the exit path that turns its
// system proxy off, so every app would keep going to a dead port until the next
// connect. Only a 127.0.0.1 proxy or PAC URL with nothing listening behind it
// is cleared: another proxy app that is running keeps its setting. A port in
// use is looked at again for up to two seconds, hence the thread; in Rust the
// clear and the app's own proxy changes take the same lock.
std::thread ClearStaleProxyInBackground() {
  const auto clear_stale_proxy =
      RustApiFunction<bool (*)()>("flclash_clear_stale_proxy");
  if (clear_stale_proxy == nullptr) return {};
  return std::thread([clear_stale_proxy] { clear_stale_proxy(); });
}

// Joined on every way out of wWinMain, so the clear never runs on while the
// process tears down the runtime it calls into.
struct JoinOnExit {
  std::thread thread;
  ~JoinOnExit() {
    if (thread.joinable()) thread.join();
  }
};

void ActivateWindow(HWND window) {
  if (const auto activate_window =
          RustApiFunction<void (*)(HWND)>("flclash_activate_window")) {
    activate_window(window);
  }
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  if (std::find(command_line_arguments.begin(), command_line_arguments.end(),
                kClearStaleProxyArgument) != command_line_arguments.end()) {
    return ClearStaleProxy() ? EXIT_SUCCESS : EXIT_FAILURE;
  }

  if (HWND running = FindRunningWindow()) {
    ForwardLinks(running);
    ActivateWindow(running);
    return EXIT_SUCCESS;
  }

  // After the single-instance check: a second launch leaves the running
  // instance's proxy alone. So does a safe build, which never writes the
  // system proxy.
  JoinOnExit stale_proxy_clear{
      FLCLASH_SAFE_MODE ? std::thread{} : ClearStaleProxyInBackground()};

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  ScopedComInitializer com_guard(com);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"vps2vpn", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  BOOL get_message_result = 0;
  while ((get_message_result = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  return get_message_result == -1 ? EXIT_FAILURE : EXIT_SUCCESS;
}
