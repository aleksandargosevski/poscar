import Testing
@testable import PoscarCore

@Suite struct RecipientListTests {
    @Test func separatorsTurnAddressesIntoTokens() {
        for separator in [",", ";", "\n"] {
            var list = RecipientList()
            list.updateDraft("ana@x.com\(separator) mar")
            #expect(list.addresses.map(\.email) == ["ana@x.com"], "separator \(separator.debugDescription)")
            #expect(list.draft == "mar")
        }
    }

    @Test func keepsTypingWithoutSeparators() {
        var list = RecipientList()
        list.updateDraft("Ana Pet")
        #expect(list.addresses.isEmpty)
        #expect(list.draft == "Ana Pet")
    }

    @Test func splitsPastedLists() {
        var list = RecipientList()
        list.updateDraft(#""Doe, John" <john@x.com>, Ana <ana@x.com>; marko@y.com,"#)
        #expect(list.addresses.map(\.email) == ["john@x.com", "ana@x.com", "marko@y.com"])
        #expect(list.addresses.first?.name == "Doe, John")
        #expect(list.draft.isEmpty)
    }

    @Test func leavesInvalidTextInTheDraft() {
        var list = RecipientList()
        list.updateDraft("not an address, ana@x.com,")
        #expect(list.addresses.map(\.email) == ["ana@x.com"])
        #expect(list.draft == "not an address")
        let committed = list.commitDraft()
        #expect(!committed)
    }

    @Test func ignoresDuplicates() {
        var list = RecipientList([EmailAddress(email: "Ana@x.com")])
        list.updateDraft("ana@X.com,")
        #expect(list.addresses.count == 1)
        let added = list.add(EmailAddress(name: "Ana", email: "ana@x.com"))
        #expect(!added)
    }

    @Test func commitsAndResolvesTheDraft() throws {
        var list = RecipientList([EmailAddress(email: "a@x.com")], draft: "b@y.com")
        #expect(list.draftIsBareAddress)
        #expect(try list.resolved(field: "To").map(\.email) == ["a@x.com", "b@y.com"])
        let committed = list.commitDraft()
        #expect(committed)
        #expect(list.addresses.count == 2)

        let broken = RecipientList(draft: "marko")
        #expect(throws: PoscarError.self) { try broken.resolved(field: "To") }
    }
}
