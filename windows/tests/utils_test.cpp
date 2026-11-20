#include "utils.h"

#include <iostream>
#include <string>

extern "C" void FlutterDesktopResyncOutputStreams() {}

int main() {
  const wchar_t lone_high[] = {0xd800, 0};
  const wchar_t lone_low[] = {0xdc00, 0};
  const wchar_t wrong_pair[] = {0xd800, L'a', 0};
  const wchar_t mixed[] = {L'a', 0xd800, 0};
  const wchar_t smile[] = {0xd83d, 0xde42, 0};
  const wchar_t chinese[] = {0x4e2d, 0x6587, 0};
  const struct {
    const wchar_t* input;
    const char* expected;
  } cases[] = {
      {nullptr, ""}, {L"", ""}, {L"plain", "plain"},
      {lone_high, ""}, {lone_low, ""}, {wrong_pair, ""}, {mixed, ""},
      {smile, "\xf0\x9f\x99\x82"},
      {chinese, "\xe4\xb8\xad\xe6\x96\x87"},
  };
  for (const auto& test : cases) {
    if (Utf8FromUtf16(test.input) != test.expected) {
      std::cerr << "UTF-16 conversion mismatch\n";
      return 1;
    }
  }
  const std::wstring long_input(32767, L'a');
  if (Utf8FromUtf16(long_input.c_str()) != std::string(32767, 'a')) {
    std::cerr << "Long command-line conversion mismatch\n";
    return 1;
  }
  std::cout << "10 UTF-16 boundary cases passed\n";
  return 0;
}
