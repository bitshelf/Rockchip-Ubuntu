// SPDX-License-Identifier: Apache-2.0
// Submit an RGA fill against a dma-buf and verify the synchronized CPU view.

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <im2d.h>

namespace {

using u32 = std::uint32_t;
using u64 = std::uint64_t;

struct dma_heap_allocation_data {
    u64 len;
    u32 fd;
    u32 fd_flags;
    u64 heap_flags;
};

struct dma_buf_sync {
    u64 flags;
};

constexpr unsigned long dma_heap_alloc =
    _IOWR('H', 0, dma_heap_allocation_data);
constexpr unsigned long dma_buf_sync_ioctl = _IOW('b', 0, dma_buf_sync);
constexpr u64 dma_buf_sync_read = 1U << 0;
constexpr u64 dma_buf_sync_write = 2U << 0;
constexpr u64 dma_buf_sync_start = 0U << 2;
constexpr u64 dma_buf_sync_end = 1U << 2;

bool sync_dma_buf(int fd, u64 flags, const char *operation) {
    dma_buf_sync sync{flags};
    if (ioctl(fd, dma_buf_sync_ioctl, &sync) == 0)
        return true;
    std::fprintf(stderr, "%s failed: %s\n", operation, std::strerror(errno));
    return false;
}

int allocate_dma_buffer(std::size_t size, int *buffer_fd, void **mapping) {
    static const char *const heaps[] = {
        "/dev/dma_heap/system-uncached",
        "/dev/dma_heap/system",
        "/dev/dma_heap/reserved",
    };

    for (const char *heap_path : heaps) {
        int heap_fd = open(heap_path, O_RDWR | O_CLOEXEC);
        if (heap_fd < 0)
            continue;

        dma_heap_allocation_data allocation{};
        allocation.len = size;
        allocation.fd_flags = O_RDWR | O_CLOEXEC;
        int result = ioctl(heap_fd, dma_heap_alloc, &allocation);
        int saved_errno = errno;
        close(heap_fd);
        if (result < 0) {
            errno = saved_errno;
            continue;
        }

        void *address = mmap(nullptr, size, PROT_READ | PROT_WRITE,
                             MAP_SHARED, allocation.fd, 0);
        if (address == MAP_FAILED) {
            saved_errno = errno;
            close(allocation.fd);
            errno = saved_errno;
            continue;
        }

        std::printf("dma_heap=%s dma_buf_bytes=%zu\n", heap_path, size);
        *buffer_fd = static_cast<int>(allocation.fd);
        *mapping = address;
        return 0;
    }

    std::fprintf(stderr, "cannot allocate a usable dma-buf: %s\n",
                 std::strerror(errno));
    return -1;
}

} // namespace

int main() {
    constexpr int width = 128;
    constexpr int height = 128;
    constexpr std::size_t pixel_bytes = 4;
    constexpr std::size_t size = width * height * pixel_bytes;
    constexpr unsigned char sentinel = 0x33;
    constexpr std::uint32_t fill_color = 0xff00ff00;

    int dma_fd = -1;
    void *mapping = nullptr;
    if (allocate_dma_buffer(size, &dma_fd, &mapping) != 0)
        return 1;

    if (!sync_dma_buf(dma_fd, dma_buf_sync_start | dma_buf_sync_write,
                      "DMA_BUF_SYNC START WRITE"))
        return 1;
    std::memset(mapping, sentinel, size);
    if (!sync_dma_buf(dma_fd, dma_buf_sync_end | dma_buf_sync_write,
                      "DMA_BUF_SYNC END WRITE"))
        return 1;

    rga_buffer_handle_t handle = importbuffer_fd(dma_fd, static_cast<int>(size));
    if (handle == 0) {
        std::fprintf(stderr, "RGA failed to import the dma-buf\n");
        munmap(mapping, size);
        close(dma_fd);
        return 1;
    }

    rga_buffer_t destination =
        wrapbuffer_handle(handle, width, height, RK_FORMAT_RGBA_8888);
    im_rect rectangle{0, 0, width, height};
    IM_STATUS status = imcheck({}, destination, {}, rectangle, IM_COLOR_FILL);
    if (status == IM_STATUS_NOERROR)
        status = imfill(destination, rectangle, fill_color);

    bool read_sync_started = sync_dma_buf(
        dma_fd, dma_buf_sync_start | dma_buf_sync_read,
        "DMA_BUF_SYNC START READ");
    const auto *bytes = static_cast<const unsigned char *>(mapping);
    std::size_t changed = 0;
    std::size_t mismatched_pixels = 0;
    if (read_sync_started) {
        for (std::size_t index = 0; index < size; ++index)
            changed += bytes[index] != sentinel;
        for (std::size_t offset = pixel_bytes; offset < size;
             offset += pixel_bytes) {
            mismatched_pixels +=
                std::memcmp(bytes, bytes + offset, pixel_bytes) != 0;
        }
    }

    std::printf(
        "rga_status=%d changed_bytes=%zu mismatched_pixels=%zu "
        "first_pixel=%02x%02x%02x%02x\n",
        status, changed, mismatched_pixels, bytes[0], bytes[1], bytes[2],
        bytes[3]);

    bool read_sync_ended = read_sync_started && sync_dma_buf(
        dma_fd, dma_buf_sync_end | dma_buf_sync_read,
        "DMA_BUF_SYNC END READ");
    releasebuffer_handle(handle);
    munmap(mapping, size);
    close(dma_fd);

    if (status != IM_STATUS_SUCCESS && status != IM_STATUS_NOERROR) {
        std::fprintf(stderr, "RGA color fill failed: %s\n", imStrError(status));
        return 1;
    }
    if (!read_sync_ended)
        return 1;
    if (changed < size / 2) {
        std::fprintf(stderr, "RGA did not replace the sentinel dma-buf\n");
        return 1;
    }
    if (mismatched_pixels != 0) {
        std::fprintf(stderr, "RGA fill did not produce a uniform frame\n");
        return 1;
    }

    std::puts("RGA_SMOKE_OK");
    return 0;
}
