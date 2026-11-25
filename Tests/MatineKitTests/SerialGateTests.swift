import Foundation
import Testing
@testable import MatineKit

@Suite struct SerialGateTests {
    private actor Probe {
        var running = 0
        var peak = 0
        var order: [Int] = []
        func enter(_ n: Int) { running += 1; peak = max(peak, running); order.append(n) }
        func leave() { running -= 1 }
    }

    @Test func callsNeverOverlap() async {
        let gate = SerialGate()
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<20 {
                group.addTask {
                    await gate.run {
                        await probe.enter(n)
                        try? await Task.sleep(for: .milliseconds(2))
                        await probe.leave()
                    }
                }
            }
        }
        #expect(await probe.peak == 1)
        #expect(await probe.order.count == 20)
    }

    @Test func aThrowingCallReleasesTheGate() async {
        struct Boom: Error {}
        let gate = SerialGate()
        await #expect(throws: Boom.self) { try await gate.run { throw Boom() } }
        let value = await gate.run { 7 }
        #expect(value == 7)
    }
}

#if canImport(CloudKit)
import CloudKit

@Suite struct HouseholdRecordRoundTripTests {
    @Test func aMemberSurvivesTheRecordEncodingUnchanged() throws {
        let members = [
            HouseholdMember(server: testServer, userId: "ana", name: "ana", modified: 100),
            HouseholdMember(
                server: testServer, userId: "kid", name: "kid", displayName: "Peque", role: .kid,
                avatar: Avatar(figure: .animal(.cat), color: .teal), language: .english, pin: "0042", modified: 7
            ),
            HouseholdMember(server: testServer, userId: "gone", name: "gone", pin: "", modified: 9, removed: true),
        ]
        for member in members {
            let record = CKRecord(recordType: CloudKitHouseholdCloud.memberType, recordID: CKRecord.ID(recordName: member.recordName))
            CloudKitHouseholdCloud.fill(record, with: member)
            let back = try #require(CloudKitHouseholdCloud.member(from: record))
            #expect(back == member)
            // Filling a record that came back from the server again changes nothing either.
            let again = CKRecord(recordType: CloudKitHouseholdCloud.memberType, recordID: record.recordID)
            CloudKitHouseholdCloud.fill(again, with: back)
            #expect(CloudKitHouseholdCloud.member(from: again) == member)
        }
    }
}
#endif

@Suite struct HouseholdSettlesTests {
    let hub = HouseholdHub()
    let clock = HouseholdClock()

    /// Two devices syncing in turn (as every foreground does) must go quiet: no copy keeps being resent.
    @Test func twoDevicesThatAgreeStopSendingEachOthersRecords() async throws {
        let phone = HouseholdDevice(hub, clock, name: "iPhone"), tv = HouseholdDevice(hub, clock, name: "Apple TV")
        try phone.add("ana", pin: "4321")
        try phone.add("kid", role: .kid)
        try phone.edit("kid") { $0.displayName = "Peque"; $0.language = .english; $0.avatar = Avatar(figure: .animal(.cat), color: .teal) }
        for _ in 0..<3 {
            _ = await phone.sync.sync()
            clock.advance(5)
            _ = await tv.sync.sync()
            clock.advance(5)
        }
        let before = phone.cloud.saves + tv.cloud.saves
        for _ in 0..<5 {
            _ = await phone.sync.sync()
            clock.advance(5)
            _ = await tv.sync.sync()
            clock.advance(5)
        }
        #expect(phone.cloud.saves + tv.cloud.saves == before)
    }

    @Test func twoDifferentEditsOfTheSameSecondSettleOnOneWinnerAndStop() async throws {
        let phone = HouseholdDevice(hub, clock), tv = HouseholdDevice(hub, clock)
        try phone.add("ana")
        _ = await phone.sync.sync()
        _ = await tv.sync.sync()
        clock.advance(60)
        try phone.edit("ana") { $0.displayName = "Uno" }
        try tv.edit("ana") { $0.displayName = "Dos" }
        for _ in 0..<4 {
            _ = await phone.sync.sync()
            _ = await tv.sync.sync()
        }
        #expect(phone.account("ana")?.displayName == tv.account("ana")?.displayName)
        let before = phone.cloud.saves + tv.cloud.saves
        for _ in 0..<4 {
            _ = await phone.sync.sync()
            _ = await tv.sync.sync()
        }
        #expect(phone.cloud.saves + tv.cloud.saves == before)
    }
}
