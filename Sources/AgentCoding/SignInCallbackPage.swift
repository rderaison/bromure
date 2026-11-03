import Foundation

/// What the browser sees when a sign-in's loopback callback lands on the
/// host's listener and the host keeps the credential.
enum SignInCallbackPage {
    /// A friendly, self-contained "signed in" page — no dependency on a live
    /// bromure.io URL (a 302 to a missing page would just 404 in the browser).
    static func response(provider: String) -> String {
        let body = """
        <!doctype html><html><head><meta charset="utf-8">\
        <title>Signed in — Bromure</title><style>\
        html,body{height:100%;margin:0}\
        body{background:#0b0f14;color:#e7ecf2;\
        font:15px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;\
        display:flex;align-items:center;justify-content:center}\
        .c{text-align:center;max-width:420px;padding:32px}\
        .m{font-size:44px;line-height:1}\
        h1{font-size:19px;font-weight:600;margin:18px 0 8px}\
        p{color:#9aa7b4;margin:0;font-size:13px}\
        </style></head><body><div class="c"><div class="m">✓</div>\
        <h1>Signed in to \(provider)</h1>\
        <p>Bromure captured your credentials. You can close this tab and return to the app.</p>\
        </div></body></html>
        """
        let bytes = Array(body.utf8).count
        return "HTTP/1.1 200 OK\r\n"
             + "Content-Type: text/html; charset=utf-8\r\n"
             + "Content-Length: \(bytes)\r\n"
             + "Connection: close\r\n\r\n"
             + body
    }
}
