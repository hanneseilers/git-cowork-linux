import CGtk
import Dispatch
import Foundation

// libdispatch's hooks for running the main queue inside another event loop
// (CoreFoundation uses the same ones). On Linux the handle is an eventfd that
// becomes readable when work is queued on the main queue.
@_silgen_name("_dispatch_get_main_queue_handle_4CF")
private func dispatchMainQueueHandle() -> Int32
@_silgen_name("_dispatch_main_queue_callback_4CF")
private func dispatchMainQueueCallback(_ msg: UnsafeMutableRawPointer?)

/// Runs DispatchQueue.main (and with it @MainActor tasks) inside GLib's main
/// loop, so Swift concurrency and GTK share one thread with no polling.
enum MainLoop {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let fd = dispatchMainQueueHandle()
        if fd >= 0 {
            // libdispatch pokes the eventfd but leaves resetting it to the
            // loop; without the read GLib would wake again at once (100% CPU).
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            g_unix_fd_add(fd, G_IO_IN, { fd, _, _ in
                var counter: UInt64 = 0
                _ = read(fd, &counter, MemoryLayout<UInt64>.size)
                dispatchMainQueueCallback(nil)
                return 1   // G_SOURCE_CONTINUE
            }, nil)
        } else {
            // Shouldn't happen on Linux; fall back to a short timer.
            g_timeout_add(10, { _ in
                dispatchMainQueueCallback(nil)
                return 1
            }, nil)
        }
    }
}
