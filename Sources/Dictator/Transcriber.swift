import Foundation

// Sends a WAV file to the resident whisper-server's /inference endpoint as a
// multipart/form-data upload and reads back the transcript.
struct Transcriber {
  let port: Int
  let language: String

  enum TranscribeError: Error { case badResponse, http(Int), empty }

  func transcribe(wavURL: URL) async throws -> String {
    let url = URL(string: "http://127.0.0.1:\(port)/inference")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    // Generous timeout: large-v3-turbo is fast on Metal, but cold paths or long
    // dictations shouldn't trip a premature failure.
    request.timeoutInterval = 120

    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")

    let wavData = try Data(contentsOf: wavURL)
    let body = Self.multipartBody(boundary: boundary,
                                  wavData: wavData,
                                  filename: wavURL.lastPathComponent,
                                  fields: [
                                    "temperature": "0.0",
                                    "response_format": "json",
                                    "language": language
                                  ])

    let (data, response) = try await URLSession.shared.upload(for: request, from: body)
    guard let http = response as? HTTPURLResponse else { throw TranscribeError.badResponse }
    guard (200..<300).contains(http.statusCode) else { throw TranscribeError.http(http.statusCode) }

    // whisper-server returns {"text": "..."} for response_format=json. Fall back
    // to treating the body as raw text if it isn't the expected JSON shape.
    let text: String
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let t = obj["text"] as? String {
      text = t
    } else {
      text = String(data: data, encoding: .utf8) ?? ""
    }

    // whisper inserts newlines at segment boundaries (e.g. "country can\n do"),
    // which look wrong pasted inline. Collapse every run of whitespace/newlines
    // to a single space and trim the ends.
    let normalized = text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard !normalized.isEmpty else { throw TranscribeError.empty }
    return normalized
  }

  // Hand-build the multipart body: one file part + several plain text fields.
  private static func multipartBody(boundary: String,
                                    wavData: Data,
                                    filename: String,
                                    fields: [String: String]) -> Data {
    var body = Data()
    func append(_ s: String) { body.append(s.data(using: .utf8)!) }

    for (key, value) in fields {
      append("--\(boundary)\r\n")
      append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
      append("\(value)\r\n")
    }

    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
    append("Content-Type: audio/wav\r\n\r\n")
    body.append(wavData)
    append("\r\n")
    append("--\(boundary)--\r\n")
    return body
  }
}
