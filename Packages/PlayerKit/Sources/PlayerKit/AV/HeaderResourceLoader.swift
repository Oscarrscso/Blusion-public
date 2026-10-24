#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Creates assets. Streams without request headers get a plain `AVURLAsset`. With headers, ADR-005 applies:
/// the documented `AVAssetResourceLoaderDelegate` route by default, or the undocumented asset option behind a compile flag.
enum AVAssetFactory {
    static func make(url: URL, headers: [String: String]) -> (asset: AVURLAsset, loader: HeaderResourceLoader?) {
        guard !headers.isEmpty else { return (AVURLAsset(url: url), nil) }
        #if BLUSION_UNDOCUMENTED_AV_HEADERS
        return (AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers]), nil)
        #else
        guard let custom = CustomScheme.encode(url) else { return (AVURLAsset(url: url), nil) }
        let loader = HeaderResourceLoader(headers: headers)
        let asset = AVURLAsset(url: custom)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (asset, loader)
        #endif
    }
}

/// Fetches media for AVPlayer through URLSession with extra request headers. UNVERIFIED on device (see docs/DEVICE_CHECKLIST.md).
/// ATS applies to these URLSession loads: plain-http streams to non-local hosts fail by design (ADR-005).
final class HeaderResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.blusion.resource-loader")
    private enum ResponseAction { case allow, cancel, finish, unsupportedRange }

    private final class Job {
        let loadingRequest: AVAssetResourceLoadingRequest
        let realURL: URL
        let requestedOffset: Int64
        var remaining: Int?
        var buffer = Data()
        var info: HTTPURLResponse?
        var isPlaylist = false

        init(loadingRequest: AVAssetResourceLoadingRequest, realURL: URL, requestedOffset: Int64, remaining: Int?) {
            self.loadingRequest = loadingRequest
            self.realURL = realURL
            self.requestedOffset = requestedOffset
            self.remaining = remaining
        }
    }

    private let headers: [String: String]
    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private var session: URLSession!

    init(headers: [String: String]) {
        self.headers = headers
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// URLSession retains its delegate, so the owner must explicitly break the cycle.
    func invalidate() {
        session.invalidateAndCancel()
        let pending = lock.withLock {
            let pending = Array(jobs.values)
            jobs.removeAll()
            return pending
        }
        for job in pending { job.loadingRequest.finishLoading(with: URLError(.cancelled)) }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, let real = CustomScheme.decode(url) else { return false }
        var request = URLRequest(url: real)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        var offset: Int64 = 0
        var remaining: Int?
        if let data = loadingRequest.dataRequest {
            offset = max(data.requestedOffset, data.currentOffset)
            remaining = data.requestsAllDataToEndOfResource ? nil : max(0, data.requestedLength - Int(offset - data.requestedOffset))
            let range = ByteRange.header(offset: offset, length: remaining ?? data.requestedLength, toEnd: data.requestsAllDataToEndOfResource)
            request.setValue(range, forHTTPHeaderField: "Range")
        } else if loadingRequest.contentInformationRequest != nil {
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")   // just enough to learn type and total length
        }
        let task = session.dataTask(with: request)
        lock.withLock { jobs[task.taskIdentifier] = Job(loadingRequest: loadingRequest, realURL: real, requestedOffset: offset, remaining: remaining) }
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let ids = lock.withLock { jobs.filter { $0.value.loadingRequest === loadingRequest }.map(\.key) }
        session.getAllTasks { tasks in
            for task in tasks where ids.contains(task.taskIdentifier) { task.cancel() }
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let disposition: ResponseAction = lock.withLock {
            guard let job = jobs[dataTask.taskIdentifier] else { return .cancel }
            job.info = http
            let mime = http.mimeType?.lowercased() ?? ""
            job.isPlaylist = mime.contains("mpegurl") || job.realURL.pathExtension.lowercased() == "m3u8"
            // A deep seek must not redownload the movie from byte zero when a server ignores Range.
            if http.statusCode == 200, job.requestedOffset > 0, !job.isPlaylist { return .unsupportedRange }
            if !job.isPlaylist { Self.fillContentInformation(job.loadingRequest.contentInformationRequest, from: http, url: job.realURL, bodyLength: nil) }
            return !job.isPlaylist && job.loadingRequest.dataRequest == nil ? .finish : .allow
        }
        if disposition == .unsupportedRange {
            finish(taskID: dataTask.taskIdentifier, error: URLError(.badServerResponse))
            completionHandler(.cancel)
        } else if http.statusCode >= 400 {
            finish(taskID: dataTask.taskIdentifier, error: URLError(.badServerResponse))
            completionHandler(.cancel)
        } else if disposition != .allow {
            finish(taskID: dataTask.taskIdentifier, error: nil)
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let complete = lock.withLock {
            guard let job = jobs[dataTask.taskIdentifier] else { return false }
            if job.isPlaylist {
                guard job.buffer.count + data.count <= 1024 * 1024 else { return true }
                job.buffer.append(data)        // playlists are rewritten as a whole
                return false
            }
            let chunk = job.remaining.map { data.prefix($0) } ?? data
            if !chunk.isEmpty { job.loadingRequest.dataRequest?.respond(with: chunk) }
            if let remaining = job.remaining { job.remaining = remaining - chunk.count }
            return job.remaining == 0
        }
        if complete {
            let oversizedPlaylist = lock.withLock { jobs[dataTask.taskIdentifier]?.isPlaylist == true }
            finish(taskID: dataTask.taskIdentifier, error: oversizedPlaylist ? URLError(.dataLengthExceedsMaximum) : nil)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(taskID: task.taskIdentifier, error: error)
    }

    // MARK: Completion

    private func finish(taskID: Int, error: Error?) {
        guard let job = lock.withLock({ jobs.removeValue(forKey: taskID) }) else { return }
        if let error {
            job.loadingRequest.finishLoading(with: error)
            return
        }
        if job.isPlaylist {
            let text = String(decoding: job.buffer, as: UTF8.self)
            let rewritten = Data(HLSPlaylistRewriter.rewrite(text, baseURL: job.realURL, map: CustomScheme.encode).utf8)
            if let info = job.info {
                Self.fillContentInformation(job.loadingRequest.contentInformationRequest, from: info, url: job.realURL, bodyLength: Int64(rewritten.count))
            }
            if let data = job.loadingRequest.dataRequest {
                let start = min(Int(job.requestedOffset), rewritten.count)
                let bytes = rewritten.dropFirst(start)
                data.respond(with: data.requestsAllDataToEndOfResource ? bytes : bytes.prefix(job.remaining ?? data.requestedLength))
            }
        }
        job.loadingRequest.finishLoading()
    }

    private static func fillContentInformation(_ info: AVAssetResourceLoadingContentInformationRequest?, from response: HTTPURLResponse,
                                               url: URL, bodyLength: Int64?) {
        guard let info else { return }
        let headers = response.allHeaderFields
        let contentRange = (headers["Content-Range"] as? String) ?? (headers["content-range"] as? String)
        info.isByteRangeAccessSupported = response.statusCode == 206 || ((headers["Accept-Ranges"] as? String)?.lowercased() == "bytes")
        if let bodyLength {
            info.contentLength = bodyLength
            info.isByteRangeAccessSupported = true
        } else if let total = ByteRange.totalLength(fromContentRange: contentRange) {
            info.contentLength = total
        } else if response.statusCode == 200, response.expectedContentLength > 0 {
            info.contentLength = response.expectedContentLength
        }
        let mime = response.mimeType ?? ""
        let type = UTType(mimeType: mime) ?? UTType(filenameExtension: url.pathExtension)
        info.contentType = type?.identifier ?? mime
    }
}
#endif
