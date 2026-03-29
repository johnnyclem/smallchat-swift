import Foundation

/// Represents a file to be uploaded as part of a multipart request.
public struct FileUpload: Sendable {
    /// The form field name for this file.
    public let fieldName: String
    /// The filename to use in the multipart header.
    public let filename: String
    /// The MIME content type.
    public let contentType: String
    /// The file content as raw data.
    public let content: Data

    public init(
        fieldName: String,
        filename: String,
        contentType: String,
        content: Data
    ) {
        self.fieldName = fieldName
        self.filename = filename
        self.contentType = contentType
        self.content = content
    }
}

/// Build a multipart/form-data body from files and additional fields.
///
/// Returns the body data and the Content-Type header value (including boundary).
public func buildMultipartBody(
    files: [FileUpload],
    fields: [String: any Sendable]? = nil
) -> (data: Data, contentType: String) {
    let boundary = "SmallChat-\(UUID().uuidString)"
    var body = Data()

    // Add regular fields first
    if let fields {
        for (key, value) in fields {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            if let dictValue = value as? [String: any Sendable],
               let jsonData = try? JSONSerialization.data(withJSONObject: dictValue) {
                body.append(jsonData)
            } else {
                body.append("\(value)")
            }
            body.append("\r\n")
        }
    }

    // Add file uploads
    for file in files {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.filename)\"\r\n")
        body.append("Content-Type: \(file.contentType)\r\n\r\n")
        body.append(file.content)
        body.append("\r\n")
    }

    body.append("--\(boundary)--\r\n")

    return (data: body, contentType: "multipart/form-data; boundary=\(boundary)")
}

/// Check if a transport input requires multipart encoding.
public func requiresMultipart(_ files: [FileUpload]?) -> Bool {
    guard let files else { return false }
    return !files.isEmpty
}

// MARK: - Data Helpers

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
