import Foundation

@main
struct RelatedTabsTests {
    static var checks = 0

    static func main() {
        entities()
        relations()
        print("Passed \(checks) related tab checks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        // fatalError prints the message in optimized builds too.
        if !condition() { fatalError(message) }
    }

    static func tab(_ title: String, _ url: String, index: Int = 1) -> BrowserTab {
        BrowserTab(windowID: 1, index: index, title: title, url: url)
    }

    static func kinds(_ title: String, _ url: String, _ kind: TabEntity.Kind) -> [String] {
        RelatedTabs.entities(title: title, url: url).filter { $0.kind == kind }.map(\.value).sorted()
    }

    static func entities() {
        expect(kinds("ACME-123 Login fails", "https://acme.atlassian.net/browse/ACME-123", .issue) == ["ACME-123"],
               "A ticket key in the title and address is one entity")
        expect(kinds("Fix login (ACME-123, OPS-7)", "https://example.com/", .issue) == ["ACME-123", "OPS-7"],
               "Several ticket keys are all found")
        expect(kinds("Branch", "https://github.com/acme/api/tree/feature/ACME-9-login", .issue) == ["ACME-9"],
               "A ticket key inside a branch name is found")
        expect(kinds("UTF-8, ISO-8601, SHA-256 and RFC-9110", "https://example.com/", .issue).isEmpty,
               "Standards and encodings are not tickets")
        expect(kinds("acme-123 and ACME-0123 and XACME-1a", "https://example.com/", .issue).isEmpty,
               "Lowercase keys, leading zeros and keys glued to other text are not tickets")
        expect(kinds("Fix login · Pull Request #4", "https://github.com/Acme/API/pull/4/files", .item) == ["acme/api#4"],
               "A GitHub pull request is identified by repository and number")
        expect(kinds("Issue", "https://gitlab.example.org/acme/api/-/merge_requests/12", .item) == ["acme/api#12"],
               "A GitLab merge request is identified the same way")
        expect(kinds("Actions", "https://github.com/acme/api/actions/runs/99", .repository) == ["acme/api"]
               && kinds("Actions", "https://github.com/acme/api/actions/runs/99", .item).isEmpty,
               "Other repository pages share only the repository")
        expect(kinds("Notifications", "https://github.com/notifications/beta", .repository).isEmpty
               && kinds("Pulls", "https://github.com/pulls/assigned", .repository).isEmpty,
               "GitHub's own pages are not repositories")
        expect(kinds("Budget", "https://docs.google.com/spreadsheets/d/1AbC_x/edit#gid=0", .document) == ["1AbC_x"],
               "A Google document is identified by its file id")
        expect(kinds("Home", "https://www.Example.com/a", .site) == ["example.com"], "The site ignores case and www.")
        expect(RelatedTabs.entities(title: "Start Page", url: "").isEmpty, "A blank tab has no identifiers")
        expect(kinds("Search", "https://example.com/?q=ACME%2D5", .issue) == ["ACME-5"], "Encoded addresses are decoded first")
    }

    static func relations() {
        let jira = tab("[ACME-123] Login fails - Jira", "https://acme.atlassian.net/browse/ACME-123")
        let pull = tab("ACME-123: fix login · Pull Request #4 · acme/api", "https://github.com/acme/api/pull/4", index: 2)
        let checks = tab("Checks · acme/api", "https://github.com/acme/api/pull/4/checks", index: 3)
        let actions = tab("Actions · acme/api", "https://github.com/acme/api/actions", index: 4)
        let otherJira = tab("[ACME-200] Something else - Jira", "https://acme.atlassian.net/browse/ACME-200", index: 5)
        let unrelated = tab("Weather", "https://weather.example.com/", index: 6)
        let tabs = [jira, pull, checks, actions, otherJira, unrelated]
        let fromPull = RelatedTabs.relations(to: pull, in: tabs)
        expect(fromPull[jira]?.strength == 1 && fromPull[jira]?.shared == TabEntity(kind: .issue, value: "ACME-123"),
               "A pull request naming a ticket relates to the ticket")
        expect(fromPull[checks]?.shared == TabEntity(kind: .item, value: "acme/api#4"), "Pages of the same pull request relate fully")
        expect(fromPull[actions]?.strength == 0.5, "Pages of the same repository relate partly")
        expect(fromPull[otherJira] == nil && fromPull[unrelated] == nil && fromPull[pull] == nil,
               "Unrelated pages and the page itself have no relation")
        expect(RelatedTabs.relations(to: jira, in: tabs)[otherJira]?.strength == 0.15,
               "Other pages of the same site relate only faintly")
        expect(RelatedTabs.relations(to: nil, in: tabs).isEmpty, "Without a tab on screen nothing is related")
        expect(TabEntity(kind: .repository, value: "acme/api").label == "Repository acme/api"
               && TabEntity(kind: .issue, value: "ACME-1").label == "ACME-1", "Relations have short labels")
    }
}
