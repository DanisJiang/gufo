#ifndef GUFO_CORE_CONTEXT_POOL_HPP_
#define GUFO_CORE_CONTEXT_POOL_HPP_

#include <cstddef>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <utility>

namespace gufo::core {

// Logical admission capacity, including reusable idle frontiers. This ledger
// does not allocate native buffers or change their upstream lifetime.
// A request reserves its complete prompt + output envelope before executing;
// execution never waits for capacity while holding a partial envelope.
class ContextPool {
public:
  explicit ContextPool(std::size_t capacity) : capacity_(capacity) {
    if (!capacity)
      throw std::invalid_argument("context pool capacity must be positive");
  }
  [[nodiscard]] std::size_t capacity() const noexcept { return capacity_; }
  [[nodiscard]] std::size_t used() const {
    const std::lock_guard lock(mutex_);
    return used_;
  }
  class Reservation {
  public:
    Reservation() = default;
    explicit Reservation(std::shared_ptr<ContextPool> pool)
        : pool_(std::move(pool)) {}
    ~Reservation() { (void)Resize(0); }
    Reservation(const Reservation&) = delete;
    Reservation& operator=(const Reservation&) = delete;
    [[nodiscard]] std::size_t size() const noexcept { return size_; }
    [[nodiscard]] bool Resize(std::size_t size) {
      if (!pool_)
        return size == 0;
      const std::lock_guard lock(pool_->mutex_);
      if (size > size_ && size - size_ > pool_->capacity_ - pool_->used_)
        return false;
      pool_->used_ = pool_->used_ - size_ + size;
      size_ = size;
      return true;
    }

  private:
    std::shared_ptr<ContextPool> pool_;
    std::size_t size_{};
  };

private:
  const std::size_t capacity_;
  std::size_t used_{};
  mutable std::mutex mutex_;
};
}  // namespace gufo::core
#endif
