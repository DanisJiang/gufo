#pragma once

#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <string_view>

namespace gufo::cache::testing {

inline std::filesystem::path MakeTemporaryDirectory(std::string_view pattern) {
  const auto utf8 =
      (std::filesystem::temp_directory_path() / std::string(pattern))
          .u8string();
  std::string name(utf8.begin(), utf8.end());
  if (!::mkdtemp(name.data())) {
    throw std::runtime_error(std::string("create test directory: ") +
                             std::strerror(errno));
  }
  return std::filesystem::path(std::u8string(name.begin(), name.end()));
}

}  // namespace gufo::cache::testing
