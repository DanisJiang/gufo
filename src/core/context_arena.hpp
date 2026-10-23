#ifndef GUFO_CORE_CONTEXT_ARENA_HPP_
#define GUFO_CORE_CONTEXT_ARENA_HPP_

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <map>
#include <optional>
#include <stdexcept>
#include <utility>
#include <vector>

namespace gufo::core {

// Layout only: a caller owns one fixed physical allocation. Plans never
// allocate backing memory and leave the current layout intact until committed.
class ContextArena {
public:
  struct Range {
    std::size_t offset{}, size{};
    bool operator==(const Range&) const = default;
  };
  struct Move {
    std::size_t id{}, from{}, to{}, size{};
  };
  struct Plan {
    std::uint64_t generation{};
    std::map<std::size_t, Range> ranges;
    std::vector<Move> moves;
  };
  explicit ContextArena(std::size_t capacity) : capacity_(capacity) {
    if (!capacity)
      throw std::invalid_argument("empty shared context arena");
  }
  [[nodiscard]] std::size_t capacity() const noexcept { return capacity_; }
  [[nodiscard]] std::size_t used() const noexcept { return used_; }
  template<typename Copy>
  static void CopyChunks(std::size_t from, std::size_t to, std::size_t bytes,
                         std::size_t scratch_bytes, Copy&& copy) {
    if (!scratch_bytes)
      throw std::invalid_argument("empty context relocation scratch");
    for (std::size_t done = 0; done < bytes;) {
      const auto count = std::min(scratch_bytes, bytes - done);
      const auto offset = to > from ? bytes - done - count : done;
      copy(from + offset, to + offset, count);
      done += count;
    }
  }
  [[nodiscard]] std::size_t Register() {
    const auto id = next_id_++;
    ranges_.emplace(id, Range{});
    ++generation_;
    return id;
  }
  [[nodiscard]] Range Get(std::size_t id) const { return ranges_.at(id); }
  void Release(std::size_t id) {
    auto& range = ranges_.at(id);
    used_ -= range.size;
    range = {};
    ++generation_;
  }
  void Unregister(std::size_t id) noexcept {
    const auto found = ranges_.find(id);
    if (found == ranges_.end())
      return;
    used_ -= found->second.size;
    ranges_.erase(found);
    ++generation_;
  }
  [[nodiscard]] std::optional<Plan> Prepare(std::size_t id,
                                            std::size_t size) const {
    const auto current = ranges_.at(id);
    if (size < current.size)
      throw std::invalid_argument(
          "release a context before shrinking its range");
    if (size - current.size > capacity_ - used_)
      return std::nullopt;
    Plan plan{generation_, ranges_, {}};
    if (size == current.size)
      return plan;
    std::vector<std::size_t> order;
    order.reserve(ranges_.size());
    for (const auto& [other, range] : ranges_)
      if (range.size)
        order.push_back(other);
    std::ranges::sort(order, [&](auto a, auto b) {
      return ranges_.at(a).offset < ranges_.at(b).offset;
    });
    if (current.size) {
      auto end = capacity_;
      for (auto other : order)
        if (ranges_.at(other).offset > current.offset) {
          end = ranges_.at(other).offset;
          break;
        }
      if (size <= end - current.offset) {
        plan.ranges.at(id).size = size;
        return plan;
      }
    } else {
      std::size_t start = 0;
      for (auto other : order) {
        const auto range = ranges_.at(other);
        if (size <= range.offset - start) {
          plan.ranges.at(id) = {start, size};
          return plan;
        }
        start = range.offset + range.size;
      }
      if (size <= capacity_ - start) {
        plan.ranges.at(id) = {start, size};
        return plan;
      }
      order.push_back(id);
    }
    // Pack in the existing order. Move right-going ranges from the end first,
    // then left-going ranges from the beginning. This preserves every old
    // source even when a growing range pushes a neighbor to the right.
    std::size_t next = 0;
    std::vector<Move> left, right;
    for (auto other : order) {
      const auto old = ranges_.at(other);
      const auto length = other == id ? size : old.size;
      plan.ranges.at(other) = {next, length};
      if (old.size && old.offset != next) {
        const Move move{other, old.offset, next, old.size};
        (next < old.offset ? left : right).push_back(move);
      }
      next += length;
    }
    plan.moves.insert(plan.moves.end(), right.rbegin(), right.rend());
    plan.moves.insert(plan.moves.end(), left.begin(), left.end());
    return plan;
  }
  void Commit(Plan plan) {
    if (plan.generation != generation_)
      throw std::logic_error("stale shared context layout");
    std::size_t used = 0;
    for (const auto& [id, range] : plan.ranges)
      used += range.size;
    ranges_ = std::move(plan.ranges);
    used_ = used;
    ++generation_;
  }

private:
  const std::size_t capacity_;
  std::size_t used_{}, next_id_{1};
  std::uint64_t generation_{};
  std::map<std::size_t, Range> ranges_;
};

}  // namespace gufo::core
#endif
