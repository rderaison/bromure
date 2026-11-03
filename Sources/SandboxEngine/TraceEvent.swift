import Foundation

/// An HTTP trace event captured from the guest browser via CDP Network domain.
public struct TraceEvent: Codable, Identifiable, Sendable {
    public let id: String
    public let timestamp: Double
    public let method: String
    public let url: String
    public var statusCode: Int?
    public var duration: Double?
    public var requestHeaders: [String: String]?
    public var responseHeaders: [String: String]?
    public var postData: String?
    public var responseBody: String?
    public var responseBodyTruncated: Bool?
    public var mimeType: String?
    public var initiator: String?
    public var tabId: Int?
    public var errorText: String?
    public var hostname: String?
    public var documentUrl: String?
    public var frameUrl: String?
    public var navType: String?
    public var redirectFrom: String?
    public var formFields: [FormFieldSnapshot]?

    public struct FormFieldSnapshot: Codable, Sendable {
        public let name: String
        public let type: String
        public let value: String

        public init(name: String, type: String, value: String) {
            self.name = name
            self.type = type
            self.value = value
        }
    }

    public init(
        id: String,
        timestamp: Double,
        method: String,
        url: String,
        statusCode: Int? = nil,
        duration: Double? = nil,
        requestHeaders: [String: String]? = nil,
        responseHeaders: [String: String]? = nil,
        postData: String? = nil,
        responseBody: String? = nil,
        responseBodyTruncated: Bool? = nil,
        mimeType: String? = nil,
        initiator: String? = nil,
        tabId: Int? = nil,
        errorText: String? = nil,
        hostname: String? = nil,
        documentUrl: String? = nil,
        frameUrl: String? = nil,
        navType: String? = nil,
        redirectFrom: String? = nil,
        formFields: [FormFieldSnapshot]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.url = url
        self.statusCode = statusCode
        self.duration = duration
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.postData = postData
        self.responseBody = responseBody
        self.responseBodyTruncated = responseBodyTruncated
        self.mimeType = mimeType
        self.initiator = initiator
        self.tabId = tabId
        self.errorText = errorText
        self.hostname = hostname
        self.documentUrl = documentUrl
        self.frameUrl = frameUrl
        self.navType = navType
        self.redirectFrom = redirectFrom
        self.formFields = formFields
    }
}
