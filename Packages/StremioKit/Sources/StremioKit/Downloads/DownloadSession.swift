#if canImport(Darwin)
import Foundation

/// Delegate callbacks are serialized into one stream. The completed temporary file is moved before returning to URLSession.
public final class DownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let identifier = "app.blusion.player.downloads.v1"
    public struct Response: Sendable {
        public var status: Int
        public var range: String?
        public var validator: String?
        public var contentType: String?
        public init(_ response: URLResponse?) {
            let http = response as? HTTPURLResponse
            status = http?.statusCode ?? 0
            range = http?.value(forHTTPHeaderField: "Content-Range")
            let etag = http?.value(forHTTPHeaderField: "ETag")
            validator = etag?.hasPrefix("W/") == false ? etag : http?.value(forHTTPHeaderField: "Last-Modified")
            contentType = http?.value(forHTTPHeaderField: "Content-Type")
        }
    }
    public enum Event: Sendable {
        case progress(UUID, Int, Int64, Int64, Response)
        case file(UUID, Int, String, Response)
        case finished(UUID, Int, Int?, Data?, Response)
        case drained
        case reconciled
    }
    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let callbacks: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let root: URL
    private var lastProgress: [UUID: Date] = [:]
    private let sessionID: String
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: callbacks)
    }()
    public init(root: URL) {
        self.root = root
        self.sessionID = Self.identifier
        (events, continuation) = AsyncStream.makeStream()
        super.init()
    }
    public func tasks() async -> [URLSessionTask] { await session.allTasks }
    public func reconciliationBarrier() {
        callbacks.addOperation { [continuation] in continuation.yield(.reconciled) }
    }
    public func start(id: UUID, url: URL, headers: [String: String], cellular: Bool, resume: Data? = nil,
                      offset: Int64 = 0, validator: String? = nil) -> URLSessionDownloadTask {
        let task: URLSessionDownloadTask
        if let resume, offset == 0 {
            task = session.downloadTask(withResumeData: resume)
        } else {
            var request = URLRequest(url: url)
            request.allowsCellularAccess = cellular
            request.allHTTPHeaderFields = headers.filter { !["range", "if-range"].contains($0.key.lowercased()) }
            if offset > 0, let validator {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
            task = session.downloadTask(with: request)
        }
        task.taskDescription = id.uuidString
        task.priority = URLSessionTask.highPriority
        task.resume()
        return task
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let now = Date()
        if let last = lastProgress[id], now.timeIntervalSince(last) < 1, totalBytesWritten != totalBytesExpectedToWrite { return }
        lastProgress[id] = now
        continuation.yield(.progress(id, downloadTask.taskIdentifier, totalBytesWritten, totalBytesExpectedToWrite, Response(downloadTask.response)))
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let name = id.uuidString + ".incoming-\(downloadTask.taskIdentifier)"
        let destination = root.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            continuation.yield(.file(id, downloadTask.taskIdentifier, name, Response(downloadTask.response)))
        } catch { continuation.yield(.finished(id, downloadTask.taskIdentifier, NSFileWriteOutOfSpaceError, nil, Response(downloadTask.response))) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let error = error as NSError?
        continuation.yield(.finished(id, task.taskIdentifier, error?.code, error?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, Response(task.response)))
    }
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { continuation.yield(.drained) }

    /// Resume data is opaque to the app's persistent records. A best-effort copy permits explicit validated Range after link refresh.
    public func preservePartial(_ data: Data, id: UUID) -> Int64 {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["NSURLSessionResumeInfoTempFileName"] as? String, name == (name as NSString).lastPathComponent else { return 0 }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let destination = root.appendingPathComponent(id.uuidString + ".partial")
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
            return (try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        } catch { return 0 }
    }
}
#endif
