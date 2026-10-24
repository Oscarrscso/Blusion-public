import Foundation
import Testing
@testable import StremioKit

struct ManifestExpectation: Sendable, CustomTestStringConvertible {
    var file: String
    var id: String
    var resources: [String]
    var types: [String]
    var catalogs: [String]
    var installable: Bool
    var issueCodes: [ManifestIssue.Code] = []
    var testDescription: String { file }
}

private let expectations: [ManifestExpectation] = [
    .init(file: "01-string-resources.json", id: "org.example.strings",
        resources: ["catalog", "meta", "stream"], types: ["movie", "series"], catalogs: ["movie/top"], installable: true),
    .init(file: "02-object-resources.json", id: "org.example.objects", resources: ["stream", "subtitles"], types: ["movie", "series"], catalogs: [], installable: true),
    .init(file: "03-mixed-resources.json", id: "org.example.mixed",
        resources: ["catalog", "meta", "stream"], types: ["movie"], catalogs: ["movie/popular"], installable: true),
    .init(file: "04-top-level-idprefixes.json", id: "org.example.toplevel", resources: ["stream"], types: ["movie", "series"], catalogs: [], installable: true),
    .init(file: "05-resource-level-idprefixes.json", id: "org.example.reslevel", resources: ["stream", "meta"], types: ["movie"], catalogs: [], installable: true),
    .init(file: "06-legacy-extra.json", id: "org.example.legacy",
        resources: ["catalog"], types: ["movie"], catalogs: ["movie/legacy", "movie/browse"], installable: true),
    .init(file: "07-missing-types.json", id: "org.example.notypes", resources: ["stream"], types: ["movie", "series"], catalogs: ["series/s"], installable: true),
    .init(file: "08-null-arrays.json", id: "org.example.nulls",
        resources: ["stream", "catalog"], types: [], catalogs: [], installable: true, issueCodes: [.catalogResourceWithoutCatalogs]),
    .init(file: "09-numbers-as-strings.json", id: "org.example.strnums", resources: ["catalog"], types: ["movie"], catalogs: ["movie/x"], installable: true),
    .init(file: "10-cinemeta-like.json", id: "org.example.cinemeta",
        resources: ["catalog", "meta", "addon_catalog"], types: ["movie", "series"],
        catalogs: ["movie/top", "series/top", "movie/search-only"], installable: true),
    .init(file: "11-stream-only.json", id: "org.example.streamonly", resources: ["stream"], types: ["movie"], catalogs: [], installable: true),
    .init(file: "12-subtitles-only.json", id: "org.example.subsonly", resources: ["subtitles"], types: ["movie", "series"], catalogs: [], installable: true),
    .init(file: "13-configuration-required.json", id: "org.example.config",
        resources: ["stream"], types: ["movie"], catalogs: [], installable: true, issueCodes: [.configurationRequired]),
    .init(file: "14-invalid-no-id.json", id: "", resources: ["stream"], types: ["movie"], catalogs: [], installable: false, issueCodes: [.missingID]),
    .init(file: "15-invalid-empty-resources.json", id: "org.example.empty",
        resources: [], types: ["movie"], catalogs: [], installable: false, issueCodes: [.noResources]),
    .init(file: "16-only-addon-catalog.json", id: "org.example.addoncat",
        resources: ["addon_catalog"], types: ["all"], catalogs: [], installable: false, issueCodes: [.noUsableResources]),
    .init(file: "17-unicode-and-unknown-fields.json", id: "org.example.unicode",
        resources: ["catalog", "stream"], types: ["movie"], catalogs: ["movie/ru"], installable: true),
    .init(file: "18-bad-items-dropped.json", id: "org.example.baditems", resources: ["stream", "meta"], types: ["movie"], catalogs: ["movie/ok"], installable: true),
]

@Suite struct ManifestDecodingTests {
    @Test func fixtureSetHasAtLeastTenVariants() throws {
        let names = try Fixture.names(in: "manifests")
        #expect(names.count >= 10)
        #expect(Set(names) == Set(expectations.map(\.file)), "every fixture needs an expectation and vice versa")
    }

    @Test(arguments: expectations)
    func decodesEachFixture(expected: ManifestExpectation) throws {
        let manifest = try ResponseDecoder.manifest(from: Fixture.data("manifests/\(expected.file)"))
        #expect(manifest.id == expected.id)
        #expect(manifest.resources.map(\.name) == expected.resources)
        #expect(manifest.types == expected.types)
        #expect(manifest.catalogs.map(\.key) == expected.catalogs)
        #expect(manifest.isInstallable == expected.installable)
        #expect(Set(manifest.validate().map(\.code)) == Set(expected.issueCodes))
    }

    @Test(arguments: expectations)
    func roundTripsThroughCodable(expected: ManifestExpectation) throws {
        let manifest = try ResponseDecoder.manifest(from: Fixture.data("manifests/\(expected.file)"))
        let encoded = try JSONEncoder().encode(manifest)
        #expect(try JSONDecoder().decode(Manifest.self, from: encoded) == manifest)
    }

    @Test func objectResourcesKeepTheirScopes() throws {
        let m = try ResponseDecoder.manifest(from: Fixture.data("manifests/02-object-resources.json"))
        #expect(m.resources[0] == ResourceDescriptor(name: "stream", types: ["movie"], idPrefixes: ["tt"]))
        #expect(m.resources[1] == ResourceDescriptor(name: "subtitles", types: ["movie", "series"], idPrefixes: nil))
    }

    @Test func legacyExtraFieldsAreMergedIntoExtra() throws {
        let m = try ResponseDecoder.manifest(from: Fixture.data("manifests/06-legacy-extra.json"))
        let legacy = try #require(m.catalogs.first { $0.id == "legacy" })
        #expect(legacy.extra.map(\.name) == ["search", "genre", "skip"])
        #expect(legacy.extra(named: "search")?.isRequired == true)
        #expect(legacy.genreOptions == ["Action", "Drama"])
        #expect(legacy.isBrowsable == false)
        #expect(legacy.supportsSearch)
        let browse = try #require(m.catalogs.first { $0.id == "browse" })
        #expect(browse.isBrowsable)
        #expect(browse.supportsSkip)
    }

    @Test func missingTypesAreDerived() throws {
        let m = try ResponseDecoder.manifest(from: Fixture.data("manifests/07-missing-types.json"))
        #expect(m.types == ["movie", "series"])
    }

    @Test func sloppyScalarsAreCoerced() throws {
        let m = try ResponseDecoder.manifest(from: Fixture.data("manifests/09-numbers-as-strings.json"))
        #expect(m.version == "2")
        #expect(m.behaviorHints.adult)
        #expect(m.behaviorHints.configurable)
        #expect(m.behaviorHints.p2p == false)
        let genre = try #require(m.catalogs.first?.extra(named: "genre"))
        #expect(genre.isRequired)
        #expect(genre.options == ["A", "1", "true"])
        #expect(genre.optionsLimit == 1)
    }

    @Test func catalogRowsAndSearch() throws {
        let m = try ResponseDecoder.manifest(from: Fixture.data("manifests/10-cinemeta-like.json"))
        #expect(m.browsableCatalogs().map(\.key) == ["movie/top", "series/top"])
        #expect(m.browsableCatalogs(type: "series").map(\.key) == ["series/top"])
        #expect(m.searchableCatalogs.map(\.key) == ["movie/top", "movie/search-only"])
        #expect(m.logo?.absoluteString == "https://example.com/logo.png")
        #expect(m.catalogs.first?.genreOptions == ["Action", "Comedy", "Drama"])
    }

    @Test func unicodeSurvives() throws {
        let m = try ResponseDecoder.manifest(from: Fixture.data("manifests/17-unicode-and-unknown-fields.json"))
        #expect(m.name == "Фильмы 🎬 映画")
        #expect(m.catalogs.first?.name == "Кино")
    }

    @Test func nonObjectManifestsThrowInvalidJSON() {
        for text in ["[]", "null", "42", "\"str\"", "", "{", "{\"id\":"] {
            #expect(throws: AddonError.invalidJSON) { try ResponseDecoder.manifest(from: Data(text.utf8)) }
        }
    }

    @Test func emptyObjectDecodesButIsNotInstallable() throws {
        let m = try ResponseDecoder.manifest(from: Data("{}".utf8))
        #expect(!m.isInstallable)
        let codes = Set(m.validate().filter { $0.severity == .error }.map(\.code))
        #expect(codes == [.missingID, .missingName, .noResources])
    }

    @Test func issuesDescribeThemselves() throws {
        let m = try ResponseDecoder.manifest(from: Fixture.data("manifests/14-invalid-no-id.json"))
        let issue = try #require(m.validate().first)
        #expect(issue.description.hasPrefix("error:"))
    }

    @Test func declaredCatalogsAreInstallableWithoutAResourcesList() throws {
        let json = #"{"id":"org.example.catalogsonly","name":"Catalogs Only","version":"1","catalogs":[{"type":"movie","id":"top","name":"Top"}]}"#
        let m = try ResponseDecoder.manifest(from: Data(json.utf8))
        #expect(m.resources.isEmpty)
        #expect(m.isInstallable)
        #expect(m.validate().isEmpty)
        #expect(m.browsableCatalogs().map(\.key) == ["movie/top"])
    }

    @Test func declaredCatalogsStayInstallableWhenResourcesListNothingUsable() {
        let m = Manifest(id: "c", name: "C", version: "1", resources: [ResourceDescriptor(name: "addon_catalog")], types: ["movie"],
                         catalogs: [CatalogDescriptor(type: "movie", id: "top")])
        #expect(m.isInstallable)
        #expect(m.validate().isEmpty)
    }

    @Test func noResourcesAndNoCatalogsStayUninstallable() {
        let nothing = Manifest(id: "a", name: "A", version: "1")
        #expect(Set(nothing.validate().map(\.code)) == [.noResources])
        #expect(!nothing.isInstallable)
        let addonCatalogOnly = Manifest(id: "b", name: "B", version: "1", resources: [ResourceDescriptor(name: "addon_catalog")])
        #expect(Set(addonCatalogOnly.validate().map(\.code)) == [.noUsableResources])
        #expect(!addonCatalogOnly.isInstallable)
    }
}
