import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import GitCoworkCore

@Suite struct HostReposTests {
    // MARK: Requests

    @Test func firstPageRequests() throws {
        let gh = try #require(HostAPI.reposRequest(kind: .github, host: "github.com", token: "t1"))
        #expect(gh.url?.absoluteString == "https://api.github.com/user/repos?per_page=100&sort=pushed")
        #expect(gh.value(forHTTPHeaderField: "Authorization") == "Bearer t1")
        #expect(gh.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")

        let gl = try #require(HostAPI.reposRequest(kind: .gitlab, host: "gitlab.example.com", token: "t2"))
        #expect(gl.url?.absoluteString
                == "https://gitlab.example.com/api/v4/projects?membership=true&order_by=last_activity_at&per_page=100")
        #expect(gl.value(forHTTPHeaderField: "Authorization") == "Bearer t2")

        let gitea = try #require(HostAPI.reposRequest(kind: .gitea, host: "codeberg.org", token: "t3"))
        #expect(gitea.url?.absoluteString == "https://codeberg.org/api/v1/user/repos?limit=50")
        #expect(gitea.value(forHTTPHeaderField: "Authorization") == "token t3")
    }

    @Test func readsNextLink() {
        let header = #"<https://api.github.com/user/repos?per_page=100&page=2>; rel="next", <https://api.github.com/user/repos?per_page=100&page=5>; rel="last""#
        #expect(HostAPI.nextPageURL(linkHeader: header)?.absoluteString == "https://api.github.com/user/repos?per_page=100&page=2")
        let lastPage = #"<https://api.github.com/user/repos?page=1>; rel="first", <https://api.github.com/user/repos?page=4>; rel="prev""#
        #expect(HostAPI.nextPageURL(linkHeader: lastPage) == nil)
        #expect(HostAPI.nextPageURL(linkHeader: nil) == nil)
        #expect(HostAPI.nextPageURL(linkHeader: "") == nil)
        // GitLab puts rel first-ish and spaces differently.
        #expect(HostAPI.nextPageURL(linkHeader: "<https://gitlab.com/api/v4/projects?page=3>; rel=next")?.absoluteString
                == "https://gitlab.com/api/v4/projects?page=3")
    }

    @Test func nextPageStaysOnTheHostAPI() throws {
        func next(_ url: String, kind: HostKind = .github, host: String = "github.com") -> URLRequest? {
            HostAPI.nextReposRequest(linkHeader: "<\(url)>; rel=\"next\"", kind: kind, host: host, token: "t")
        }
        let ok = try #require(next("https://api.github.com/user/repos?page=2"))
        #expect(ok.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(next("https://evil.example/user/repos?page=2") == nil)
        #expect(next("http://api.github.com/user/repos?page=2") == nil)
        #expect(next("https://api.github.com.evil.example/user/repos") == nil)
        #expect(next("https://git.corp:8443/api/v4/projects?page=2", kind: .gitlab, host: "git.corp:8443") != nil)
        #expect(next("https://git.corp/api/v4/projects?page=2", kind: .gitlab, host: "git.corp:8443") == nil)
        #expect(next("https://git.corp/other/projects?page=2", kind: .gitlab, host: "git.corp") == nil)
    }

    // MARK: Responses

    @Test func parsesGitHubRepos() throws {
        let json = #"""
        [{"name":"app","full_name":"octo/app","clone_url":"https://github.com/octo/app.git",
          "private":true,"pushed_at":"2026-10-01T12:00:00Z","updated_at":"2025-01-01T00:00:00Z"},
         {"name":"lib","full_name":"acme/lib","clone_url":"https://github.com/acme/lib.git",
          "private":false,"pushed_at":null,"updated_at":"2026-09-01T08:30:00Z"}]
        """#
        let repos = try #require(HostAPI.parseRepos(Data(json.utf8), kind: .github, host: "github.com"))
        #expect(repos.count == 2)
        #expect(repos[0] == HostRepo(name: "app", fullPath: "octo/app", cloneURL: "https://github.com/octo/app.git",
                                     isPrivate: true, updatedAt: Date(timeIntervalSince1970: 1_790_856_000)))
        #expect(repos[1].isPrivate == false)
        #expect(repos[1].updatedAt == HostAPI.parseDate("2026-09-01T08:30:00Z"))
    }

    @Test func parsesGitLabProjects() throws {
        let json = #"""
        [{"path":"web","name":"Web App","path_with_namespace":"team/sub/web",
          "http_url_to_repo":"https://gitlab.example.com/team/sub/web.git","visibility":"internal",
          "last_activity_at":"2026-10-02T09:15:30.123+02:00"},
         {"path":"docs","name":"Docs","path_with_namespace":"anna/docs",
          "http_url_to_repo":"http://gitlab.example.com/anna/docs.git","visibility":"public",
          "last_activity_at":"2026-10-01T00:00:00Z"}]
        """#
        let repos = try #require(HostAPI.parseRepos(Data(json.utf8), kind: .gitlab, host: "gitlab.example.com"))
        #expect(repos.map(\.fullPath) == ["team/sub/web", "anna/docs"])
        #expect(repos[0].name == "web")
        #expect(repos[0].isPrivate)
        #expect(repos[0].updatedAt != nil)
        #expect(!repos[1].isPrivate)
        // An http:// URL from the server becomes https, so the signed-in token applies.
        #expect(repos[1].cloneURL == "https://gitlab.example.com/anna/docs.git")
    }

    @Test func parsesGiteaRepos() throws {
        let json = #"[{"name":"tool","full_name":"org/tool","clone_url":"https://codeberg.org/org/tool.git","private":false,"updated_at":"2026-08-08T08:08:08+00:00"}]"#
        let repos = try #require(HostAPI.parseRepos(Data(json.utf8), kind: .gitea, host: "codeberg.org"))
        #expect(repos == [HostRepo(name: "tool", fullPath: "org/tool", cloneURL: "https://codeberg.org/org/tool.git",
                                   isPrivate: false, updatedAt: HostAPI.parseDate("2026-08-08T08:08:08Z"))])
    }

    @Test func skipsBrokenEntriesAndRejectsErrors() {
        let json = #"[{"name":"x"},{"full_name":"a/b"}]"#
        let repos = HostAPI.parseRepos(Data(json.utf8), kind: .github, host: "github.com")
        #expect(repos?.map(\.fullPath) == ["a/b"])
        #expect(repos?.first?.name == "b")
        #expect(repos?.first?.cloneURL == "https://github.com/a/b.git")
        #expect(HostAPI.parseRepos(Data(#"{"message":"Bad credentials"}"#.utf8), kind: .github, host: "github.com") == nil)
        #expect(HostAPI.parseRepos(Data("[]".utf8), kind: .gitea, host: "codeberg.org") == [])
    }

    @Test func filters() {
        let repo = HostRepo(name: "app", fullPath: "Acme/App", cloneURL: "", isPrivate: false, updatedAt: nil)
        #expect(repo.matches(""))
        #expect(repo.matches("acme/a"))
        #expect(repo.matches(" APP "))
        #expect(!repo.matches("lib"))
    }
}
