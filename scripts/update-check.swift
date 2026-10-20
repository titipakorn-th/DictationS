import Foundation

/// The GitHub repository that publishes DictationS releases.
let releasesEndpoint = URL(string: "https://api.github.com/repos/titipakorn-th/DictationS/releases/latest")!

/// A published DictationS release.
struct UpdateRelease {
    /// The release version, without the leading "v" of its tag.
    let version: String
    /// The release page on GitHub.
    let page: URL
}

/// Why an update check did not produce a release.
enum UpdateError: Error {
    case request(String)
    case unreadable
}

/// The latest published DictationS release.
func latestRelease(completion: @escaping (Result<UpdateRelease, Error>) -> Void) {
    var request = URLRequest(url: releasesEndpoint)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("DictationS", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
            completion(.failure(UpdateError.request(error.localizedDescription)))
            return
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap({ URL(string: $0) }) else {
            completion(.failure(UpdateError.unreadable))
            return
        }
        completion(.success(UpdateRelease(version: releaseVersion(fromTag: tag), page: page)))
    }.resume()
}

/// The version a release tag names, without its leading "v".
func releaseVersion(fromTag tag: String) -> String {
    var version = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    if version.hasPrefix("v") || version.hasPrefix("V") {
        version.removeFirst()
    }
    return version
}

/// Whether a release version is newer than the running one.
func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    let left = versionParts(candidate)
    let right = versionParts(current)
    for index in 0..<max(left.count, right.count) {
        let candidate = index < left.count ? left[index] : 0
        let running = index < right.count ? right[index] : 0
        if candidate != running {
            return candidate > running
        }
    }
    return false
}

/// The numbers of a version, ignoring anything that is not one.
private func versionParts(_ version: String) -> [Int] {
    version.split(separator: ".").map { part in
        Int(part.prefix(while: { $0.isNumber })) ?? 0
    }
}
