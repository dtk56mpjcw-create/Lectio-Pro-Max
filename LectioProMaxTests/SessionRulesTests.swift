import Foundation
import Testing
@testable import LectioProMax

/// The rules for keeping the Lectio session (see LectioCookies.merged):
/// the auto-login key and the session cookie are only ever replaced by a
/// real value — an empty or expired one from Lectio is ignored, because
/// taking it wiped the key and meant signing in again. Pure: nothing here
/// touches the real session on the phone.
struct SessionRulesTests {

    static let url = URL(string: "https://www.lectio.dk/lectio/21/forside.aspx")!

    static func parse(_ header: String) -> [HTTPCookie] {
        HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url)
    }

    static func value(_ name: String, in jar: [String: HTTPCookie]) -> String? {
        jar.first { $0.key.lowercased() == name.lowercased() }?.value.value
    }

    @Test func emptyAnswersDontWipeTheKey() {
        let now = Date()
        var jar = LectioCookies.merged([:], Self.parse("autologinkeyV2=abc123; expires=Wed, 01-Jan-2031 00:00:00 GMT; path=/"), now: now)
        jar = LectioCookies.merged(jar, Self.parse("ASP.NET_SessionId=s1; path=/; HttpOnly"), now: now)
        #expect(Self.value("autologinkeyV2", in: jar) == "abc123")

        // Lectio answering with an emptied or expired key or session.
        jar = LectioCookies.merged(jar, Self.parse("autologinkeyV2=; expires=Thu, 01-Jan-1970 00:00:01 GMT; path=/"), now: now)
        jar = LectioCookies.merged(jar, Self.parse("ASP.NET_SessionId=; path=/"), now: now)
        #expect(Self.value("autologinkeyV2", in: jar) == "abc123")
        #expect(Self.value("ASP.NET_SessionId", in: jar) == "s1")
    }

    @Test func aNewKeyReplacesTheOld() {
        let now = Date()
        var jar = LectioCookies.merged([:], Self.parse("autologinkeyV2=old; expires=Wed, 01-Jan-2031 00:00:00 GMT; path=/"), now: now)
        jar = LectioCookies.merged(jar, Self.parse("AutoLoginKeyV2=new; expires=Wed, 01-Jan-2031 00:00:00 GMT; path=/"), now: now)
        #expect(Self.value("autologinkeyV2", in: jar) == "new")
        // One of it, whatever the case it's written in.
        #expect(jar.keys.filter { $0.lowercased() == "autologinkeyv2" }.count == 1)
    }

    @Test func otherCookiesFollowTheUsualRules() {
        let now = Date()
        var jar = LectioCookies.merged([:], Self.parse("LastAuthenticatedPageLoad2=1; path=/"), now: now)
        #expect(Self.value("LastAuthenticatedPageLoad2", in: jar) == "1")
        jar = LectioCookies.merged(jar, Self.parse("LastAuthenticatedPageLoad2=; expires=Thu, 01-Jan-1970 00:00:01 GMT; path=/"), now: now)
        #expect(Self.value("LastAuthenticatedPageLoad2", in: jar) == nil)
    }

    @Test func onlyLectiosOwn() {
        let other = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "autologinkeyV2=x; path=/"],
                                       for: URL(string: "https://broker.unilogin.dk/")!)
        #expect(LectioCookies.merged([:], other, now: Date()).isEmpty)
    }

    /// What a message or a hand-in comment sends: percent-encoded UTF-8, as
    /// a browser sends it — Lectio's own canary field included.
    @Test func formsAreEncodedLikeABrowser() {
        #expect(LectioForms.encoded(["masterfootervalue": "X1!ÆØÅ"])
                == "masterfootervalue=X1%21%C3%86%C3%98%C3%85")
        #expect(LectioForms.encoded(["m$Content$tb": "Hej, kan vi mødes? 5 & 6 = 11"])
                == "m%24Content%24tb=Hej%2C%20kan%20vi%20m%C3%B8des%3F%205%20%26%206%20%3D%2011")
    }

    /// A page posted back sends its text boxes as they were written — an
    /// event's note keeps its lines when only its title is changed — less
    /// the one line break HTML ignores after the opening tag.
    @Test func textAreasGoBackAsWritten() {
        let html = "<form id='aspnetForm'><textarea name='note'>\r\nFirst line\r\nSecond  line</textarea>"
            + "<input name='title' value='Football'></form>"
        let fields = LectioForms.fields(in: HTMLDocument.parse(html))
        #expect(fields["note"] == "First line\r\nSecond  line")
        #expect(fields["title"] == "Football")
    }
}
