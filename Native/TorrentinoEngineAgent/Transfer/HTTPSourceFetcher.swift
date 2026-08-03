// Layer: EngineAgent (Transfer).
// Role: bounded HTTP(S) fetch of .torrent files (WP-07 HTTP source).
// Limits (frozen): http/https scheme only; <= 5 redirects; max body 10 MiB;
// 30 s deadline; content-type must be application/x-bittorrent,
// application/octet-stream or absent.
// Must-not: follow redirects to non-http(s) schemes, accept oversized or
// late bodies, or block the caller (async only, injectable URLSession).
// Invariants: one fetch = one result (Data or typed error); the response is
// fully buffered before returning and never written anywhere by this type.

import Foundation

public enum HTTPSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidURL(String)
    case unsupportedScheme(String)
    case tooManyRedirects
    case redirectToUnsupportedScheme(String)
    case responseTooLarge(Int64)
    case unacceptableContentType(String)
    case nonSuccessStatus(Int)
    case transportFailure(String)
    case deadlineExceeded
    case emptyResponse

    public var description: String {
        switch self {
        case .invalidURL(let u): return "invalid URL '\(u)'"
        case .unsupportedScheme(let s): return "unsupported scheme '\(s)'"
        case .tooManyRedirects: return "too many redirects"
        case .redirectToUnsupportedScheme(let u): return "redirect to unsupported scheme '\(u)'"
        case .responseTooLarge(let n): return "response too large (\(n) bytes)"
        case .unacceptableContentType(let t): return "unacceptable content type '\(t)'"
        case .nonSuccessStatus(let s): return "HTTP \(s)"
        case .transportFailure(let m): return "transport failure: \(m)"
        case .deadlineExceeded: return "deadline exceeded"
        case .emptyResponse: return "empty response"
        }
    }
}

/// Fetches a .torrent over HTTP(S) with the WP-07 limit set.
public struct HTTPSourceFetcher: Sendable {
    /// Frozen limits.
    public static let maxRedirects = 5
    public static let maxBodyBytes = TransferLimits.maxTorrentFileBytes
    public static let deadline: TimeInterval = 30
    public static let allowedContentTypes: Set<String> = [
        "application/x-bittorrent",
        "application/octet-stream",
    ]

    /// Optional injected configuration (tests install a URLProtocol here);
    /// nil means the default ephemeral bounded configuration.
    private let configuration: URLSessionConfiguration?

    public init(configuration: URLSessionConfiguration? = nil) {
        self.configuration = configuration
    }

    /// Downloads and returns the .torrent bytes, or throws a typed error.
    public func fetch(urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw HTTPSourceError.invalidURL(urlString)
        }
        guard let scheme = url.scheme?.lowercased() else {
            throw HTTPSourceError.invalidURL(urlString)
        }
        guard scheme == "http" || scheme == "https" else {
            throw HTTPSourceError.unsupportedScheme(scheme)
        }

        // The delegate must be the session's own delegate for the
        // delegate-based dataTask to deliver callbacks, so each fetch gets a
        // fresh session built around its FetchDelegate (URLSession retains it).
        let sessionConfiguration = configuration ?? {
            let ephemeral = URLSessionConfiguration.ephemeral
            ephemeral.timeoutIntervalForRequest = Self.deadline
            ephemeral.timeoutIntervalForResource = Self.deadline
            ephemeral.waitsForConnectivity = false
            return ephemeral
        }()
        let delegate = FetchDelegate()
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: url)

        let data: Data
        do {
            data = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    delegate.setContinuation(continuation)
                    task.resume()
                }
            }, onCancel: {
                task.cancel()
                delegate.cancel()
            })
        } catch let error as URLError where error.code == .timedOut {
            throw HTTPSourceError.deadlineExceeded
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        session.invalidateAndCancel()
        guard !data.isEmpty else { throw HTTPSourceError.emptyResponse }
        return data
    }

    // MARK: - Delegate (per-fetch state; URLSession.delegate is not Sendable,
    // so a fresh delegate per fetch keeps the type Sendable). The session
    // delivers delegate callbacks serially on its delegate queue, but
    // setContinuation/cancel arrive from the awaiting task, so all mutable
    // state lives behind a lock.

    private final class FetchDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private var cancelled = false
        private var finished = false
        private var redirectCount = 0
        private var received = 0
        private var buffer = Data()

        func setContinuation(_ continuation: CheckedContinuation<Data, Error>) {
            lock.lock(); defer { lock.unlock() }
            if cancelled {
                finished = true
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
        }

        /// Resumes the continuation with CancellationError if the fetch is
        /// still in flight; safe to call from any thread, at most once.
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            if let continuation {
                finished = true
                self.continuation = nil
                continuation.resume(throwing: CancellationError())
            } else {
                cancelled = true
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            let overLimit = lock.withLock {
                redirectCount += 1
                if redirectCount > HTTPSourceFetcher.maxRedirects {
                    finishLocked(.failure(HTTPSourceError.tooManyRedirects))
                    return true
                }
                return false
            }
            if overLimit { return nil }
            guard let url = request.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                finishLocked(.failure(HTTPSourceError.redirectToUnsupportedScheme(request.url?.absoluteString ?? "?")))
                return nil
            }
            return request
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
            lock.withLock {
                guard let http = response as? HTTPURLResponse else {
                    finishLocked(.failure(HTTPSourceError.transportFailure("non-HTTP response")))
                    return .cancel
                }
                guard (200..<400).contains(http.statusCode) else {
                    finishLocked(.failure(HTTPSourceError.nonSuccessStatus(http.statusCode)))
                    return .cancel
                }
                if let contentType = http.allHeaderFields["Content-Type"] as? String {
                    let media = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    if !HTTPSourceFetcher.allowedContentTypes.contains(media.lowercased()) {
                        finishLocked(.failure(HTTPSourceError.unacceptableContentType(media)))
                        return .cancel
                    }
                }
                if http.expectedContentLength > HTTPSourceFetcher.maxBodyBytes {
                    finishLocked(.failure(HTTPSourceError.responseTooLarge(http.expectedContentLength)))
                    return .cancel
                }
                return .allow
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            received += data.count
            if received > HTTPSourceFetcher.maxBodyBytes {
                finishLocked(.failure(HTTPSourceError.responseTooLarge(Int64(received))))
                dataTask.cancel()
                return
            }
            buffer.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            if let error {
                finishLocked(.failure(error))
                return
            }
            let data = buffer
            buffer = Data()
            finishLocked(.success(data))
        }

        /// Caller holds the lock. Resumes the continuation exactly once.
        private func finishLocked(_ result: Result<Data, Error>) {
            guard !finished else { return }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(with: result)
        }
    }
}
