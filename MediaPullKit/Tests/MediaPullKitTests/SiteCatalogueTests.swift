import Foundation
@testable import MediaPullCore
import XCTest

final class SiteCatalogueTests: XCTestCase {
    private var bundled: SiteCatalogue {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("MediaPull/Resources/SiteCatalogue.json")
        return SiteCatalogue.load(from: file)
    }

    func testBundledCatalogueNamesSitesAndSignIn() {
        let catalogue = bundled
        XCTAssertGreaterThan(catalogue.sites.count, 300)
        XCTAssertEqual(catalogue.name(SiteInfoKey(category: "deviantart")), "DeviantArt")
        XCTAssertEqual(catalogue.signIn(SiteInfoKey(category: "twitter")), .cookies)
        XCTAssertEqual(catalogue.signIn(SiteInfoKey(category: "flickr")), .oauth)
        XCTAssertEqual(catalogue.name(SiteInfoKey(category: "unknownsite.example")), "Unknownsite")
    }

    func testSwitchesComeFromTheSiteOrItsEngine() {
        let catalogue = bundled
        let twitter = catalogue.switches(SiteInfoKey(category: "twitter")).map(\.key)
        XCTAssertTrue(twitter.contains("retweets") && twitter.contains("quoted"), "\(twitter)")
        let server = catalogue.switches(SiteInfoKey(category: "mastodon.example", baseCategory: "mastodon")).map(\.key)
        XCTAssertTrue(server.contains("reblogs"), "\(server)")
        // Only switches that choose media; nothing that changes an account.
        let all = Set(catalogue.options.values.flatMap { $0.map(\.key) })
        XCTAssertFalse(all.contains("auto-watch") || all.contains("comments") || all.contains("dms"))
    }

    func testChoicesAreReadable() {
        let cases: [(String, String)] = [("with-replies", "Posts and Replies"), ("favorite", "Favourites"), ("user-images", "Images"),
                                         ("some_new-part", "Some New Part")]
        for (choice, label) in cases {
            XCTAssertEqual(SiteCatalogue.choiceLabel(choice), label)
        }
        XCTAssertEqual(SiteCatalogue.visibleChoices(["info", "avatar", "media", "following"]), ["avatar", "media"])
    }

    func testGalleryErrorsAreExplained() {
        let cases: [(String, String)] = [
            ("Cloudflare challenge", "asked for a browser check"),
            ("AuthenticationError: 'refresh-token' required.", "own app sign-in"),
            ("no 'a' and 'b' session cookies set", "needs you signed in"),
            ("AuthRequired: 'api-key' & 'user-id' needed to access the API", "API key"),
            ("HttpError: '403 Forbidden' for 'https://example.com/'", "refused the request"),
            ("NotFoundError: Requested user could not be found", "Nothing was found"),
            ("API responded with 429 Too Many Requests.", "limiting requests"),
            ("An unexpected error occurred: KeyError - 'x'", "may have changed"),
        ]
        for (message, expected) in cases {
            XCTAssertTrue(GalleryError.describe(message, site: "Site").contains(expected), message)
        }
    }
}
