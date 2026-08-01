import Foundation

final class NativeDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @Sendable (Int64, Int64) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: ProgressHandler?
    private var downloadedURL: URL?
    private var destinationURL: URL?
    private var moveError: Error?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func download(from url: URL, to destination: URL, progress: @escaping ProgressHandler) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    self.progressHandler = progress
                    self.downloadedURL = nil
                    self.destinationURL = destination
                    self.moveError = nil
                }
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            self.session.getAllTasks { $0.forEach { $0.cancel() } }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let handler = lock.withLock { progressHandler }
        handler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.withLock {
            guard let destinationURL else { return }
            do {
                let fileManager = FileManager.default
                try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: location, to: destinationURL)
                downloadedURL = destinationURL
            } catch {
                moveError = error
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion: (CheckedContinuation<URL, Error>?, Result<URL, Error>) = lock.withLock {
            defer {
                continuation = nil
                progressHandler = nil
                downloadedURL = nil
                destinationURL = nil
                moveError = nil
            }
            let result: Result<URL, Error>
            if let error {
                result = .failure(error)
            } else if let moveError {
                result = .failure(moveError)
            } else if let response = task.response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let downloadedURL {
                result = .success(downloadedURL)
            } else {
                result = .failure(SandboxError.invalidDownloadResponse)
            }
            return (continuation, result)
        }
        switch completion.1 {
        case let .success(url): completion.0?.resume(returning: url)
        case let .failure(error): completion.0?.resume(throwing: error)
        }
    }
}
