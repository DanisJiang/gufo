#include <unistd.h>

#include <algorithm>
#include <array>
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>

#include "src/cache/disk.hpp"

namespace {
using namespace gufo::cache;
namespace fs = std::filesystem;

struct Directory {
  fs::path path;
  Directory() {
    const auto pattern =
        (fs::temp_directory_path() / "gufo-cache-portable-XXXXXX").u8string();
    std::string name(pattern.begin(), pattern.end());
    assert(mkdtemp(name.data()));
    path = fs::u8path(name);
  }
  ~Directory() { fs::remove_all(path); }
};

DiskFileId Id(std::uint8_t value) {
  DiskFileId id{};
  id[0] = value;
  return id;
}
template<class F>
void Reject(F action) {
  bool rejected = false;
  try {
    action();
  } catch (const std::exception&) {
    rejected = true;
  }
  assert(rejected);
}
void CheckRead(DiskStore& store, const DiskPayload& payload,
               std::span<const std::uint8_t> expected) {
  auto snapshot = store.Open({1});
  assert(snapshot);
  std::array<std::uint8_t, 2> staging{};
  std::vector<std::uint8_t> actual;
  const auto stats = store.ReadPayload(
      *snapshot, true, payload, staging,
      [&](std::uint64_t offset, std::span<const std::uint8_t> piece) {
        assert(offset == actual.size());
        actual.insert(actual.end(), piece.begin(), piece.end());
      });
  assert(stats.bytes == expected.size());
  assert(std::ranges::equal(actual, expected));
}
void RoundTripAndCorruption() {
  Directory directory;
  ResourceLedger ledger{{1ULL << 24, 1ULL << 24, 0, 0}};
  const std::array<std::uint8_t, 4> bytes{7, 11, 23, 42};
  const DiskPayload payload{Id(2), bytes.size(), DiskChecksum(bytes)};
  DiskManifest manifest;
  manifest.checkpoint = {1};
  manifest.lineage = {1};
  manifest.compatibility.fill(0x53);
  manifest.tokens = {100, 101, 102};
  manifest.components.push_back(
      {{{1}, 1, ComponentKind::kPrivateState, 0, 0, bytes.size()},
       {{1}, manifest.tokens.size()},
       {},
       {},
       payload});
  const std::array<DiskWriteBuffer, 1> buffers{{{true, payload.file, bytes}}};
  {
    DiskStore store(ledger, directory.path, 1ULL << 20);
    // The live lock excludes a second writer, even in this process.
    Reject([&] { DiskStore second(ledger, directory.path, 1ULL << 20); });
    store.Publish(Id(3), manifest, buffers);
    assert(store.Entries().size() == 1);
    CheckRead(store, payload, bytes);
    Reject([&] { store.Publish(Id(3), manifest, buffers); });
    assert(store.Entries().size() == 1);
  }
  {
    // Discovery must enumerate existing manifests and preserve their bytes.
    DiskStore store(ledger, directory.path, 1ULL << 20);
    assert(store.Entries().size() == 1);
    assert(store.Entries()[0].Manifest().tokens == manifest.tokens);
    CheckRead(store, payload, bytes);
    // Checksum failure quarantines the entry instead of serving corrupt state.
    auto path = directory.path / "v2/private" / DiskFileName(payload.file);
    std::fstream file(path, std::ios::binary | std::ios::in | std::ios::out);
    file.put('\0');
    file.close();
    Reject([&] { CheckRead(store, payload, bytes); });
    assert(!store.Open({1}));
  }
  // Invalid manifests are rejected on startup, never restored as a context.
  const auto path = directory.path / "v2/manifests" / DiskFileName(Id(3));
  std::ofstream(path, std::ios::binary | std::ios::trunc) << "corrupt";
  DiskStore store(ledger, directory.path, 1ULL << 20);
  assert(store.Entries().empty());
  assert(store.Stats().rejected_manifests == 1);
  store.ReclaimOrphans();
  store.WaitForReclamation();
  assert(store.Stats().managed_bytes == 0);
}
}  // namespace

int main() {
  RoundTripAndCorruption();
  std::cout << "portable cache disk contracts passed\n";
}
