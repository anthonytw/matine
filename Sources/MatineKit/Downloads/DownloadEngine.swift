import Foundation

/// What a transfer reports. `key` is `"<userId>/<itemId>"`.
public enum DownloadEvent: Sendable, Equatable {
    case progress(key: String, written: Int64, total: Int64)
    /// The file is in place at the destination.
    case finished(key: String, bytes: Int64)
    /// Stopped without a file. `resumeData` lets a later try continue; a
    /// `status` is the server's refusal (401, 404 …), nil for a lost connection.
    case failed(key: String, status: Int?, resumeData: Data?)
}

/// The transfer seam: the app's is a background `URLSession`, the CLI's a
/// plain one, tests use a fake that writes bytes.
public protocol DownloadEngine: Sendable {
    /// Starts (or, with `resumeData`, continues) one download into `destination`.
    func start(_ request: URLRequest, key: String, resumeData: Data?)
    /// Stops a transfer for good (no resume data kept).
    func cancel(key: String)
    /// Keys of the transfers still alive: after a relaunch, what the system kept running.
    func activeKeys() async -> Set<String>
    /// Progress and results, in order. One consumer.
    var events: AsyncStream<DownloadEvent> { get }
}

/// Downloads with URLSession's download tasks. A background configuration
/// lets iOS keep going while the app is suspended and relaunch it when
/// finished; the Authorization header on the request carries the token (never
/// the URL). A foreground session refuses a redirect that leaves the server's
/// origin; a background session never asks (the system follows redirects on
/// its own), so a finished download is checked afterwards: the URL it ended
/// up at must be on the origin it started from, else the file is discarded.
public final class URLSessionDownloadEngine: NSObject, DownloadEngine, URLSessionDownloadDelegate, @unchecked Sendable {
    public let events: AsyncStream<DownloadEvent>
    private let continuation: AsyncStream<DownloadEvent>.Continuation
    /// Where a finished download goes, by key (nil: nowhere, discard it).
    private let destination: @Sendable (String) -> URL?
    private var session: URLSession!

    /// The app's: survives suspension. `identifier` must be the same on every launch.
    public static func background(identifier: String, destination: @escaping @Sendable (String) -> URL?) -> URLSessionDownloadEngine {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        return URLSessionDownloadEngine(configuration: configuration, destination: destination)
    }

    /// For the command line and anything that stays in the foreground.
    public static func foreground(destination: @escaping @Sendable (String) -> URL?) -> URLSessionDownloadEngine {
        URLSessionDownloadEngine(configuration: .ephemeral, destination: destination)
    }

    init(configuration: URLSessionConfiguration, destination: @escaping @Sendable (String) -> URL?) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.destination = destination
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func start(_ request: URLRequest, key: String, resumeData: Data?) {
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
        task.taskDescription = key
        task.resume()
    }

    public func cancel(key: String) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == key { task.cancel() }
        }
    }

    public func activeKeys() async -> Set<String> {
        await Set(session.allTasks.compactMap(\.taskDescription))
    }

    // MARK: Background relaunch

    private let waitLock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var eventsDone = false

    /// For `.backgroundTask(.urlSession)`: returns once the system has
    /// delivered every event it was holding for this session (or after 30 s).
    public func waitForBackgroundEvents() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = waitLock.withLock { () -> Bool in
                if eventsDone { eventsDone = false; return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() } else {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    self?.releaseWaiters()
                }
            }
        }
    }

    private func releaseWaiters() {
        let pending = waitLock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let none = waitLock.withLock { () -> Bool in
            if waiters.isEmpty { eventsDone = true }
            return waiters.isEmpty
        }
        if !none { releaseWaiters() }
    }

    // MARK: Delegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        continuation.yield(.progress(key: key, written: totalBytesWritten, total: totalBytesExpectedToWrite))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // Ended up somewhere else (a redirect off the server's origin)? Not our file.
        guard SameOriginRedirects.allows(from: downloadTask.originalRequest?.url, to: downloadTask.currentRequest?.url ?? downloadTask.originalRequest?.url) else {
            continuation.yield(.failed(key: key, status: Self.offOrigin, resumeData: nil))
            return
        }
        // The temporary file goes away when this returns: move it now.
        guard (200..<300).contains(status), let target = destination(key) else {
            continuation.yield(.failed(key: key, status: status, resumeData: nil))
            return
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            DownloadStore.protect(target)
            let size = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
            continuation.yield(.finished(key: key, bytes: size))
        } catch {
            continuation.yield(.failed(key: key, status: nil, resumeData: nil))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let key = task.taskDescription else { return }
        let nsError = error as NSError
        // A task cancelled with no resume data was cancelled on purpose.
        let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if nsError.code == NSURLErrorCancelled, resume == nil { return }
        continuation.yield(.failed(key: key, status: nil, resumeData: resume))
    }

    /// The failure status for "finished somewhere other than the server".
    static let offOrigin = -1

    /// Called for foreground sessions only (see the type's note).
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(SameOriginRedirects.allows(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }
}
