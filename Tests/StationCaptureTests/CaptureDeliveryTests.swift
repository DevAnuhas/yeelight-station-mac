import XCTest
@testable import StationCapture

final class CaptureMailboxTests: XCTestCase {
    func testKeepsOnlyLatestSampleAndTerminalErrorsWin() {
        let mailbox = CaptureMailbox<Double>()
        for value in 0..<10_000 { mailbox.publish(Double(value)) }
        XCTAssertEqual(try? mailbox.take()?.get(), 9_999)
        XCTAssertNil(mailbox.take())
        mailbox.publish(1)
        mailbox.fail(.invalidAudioBuffer)
        mailbox.publish(2)
        guard case .failure(.invalidAudioBuffer) = mailbox.take() else {
            return XCTFail("A terminal error must replace pending samples")
        }
    }

    func testInvalidationDropsPendingAndFuturePublications() {
        let mailbox = CaptureMailbox<Double>()
        mailbox.publish(1)
        mailbox.invalidate()
        mailbox.publish(2)
        mailbox.fail(.invalidAudioBuffer)
        XCTAssertNil(mailbox.take())
    }
}

@MainActor
final class CaptureDeliveryTests: XCTestCase {
    private final class Recorder {
        var values: [Double] = []
        var errors: [CaptureError] = []
        var times: [TimeInterval] = []
    }

    func testCanceledDeliveryDoesNotCallBackFromQueuedTimerOrSamples() async throws {
        let recorder = Recorder()
        let firstValue = expectation(description: "First delivered sample")
        let mailbox = CaptureMailbox<Double>()
        let delivery = CaptureDelivery(mailbox: mailbox, interval: 0.05,
            onValue: { value in
                recorder.values.append(value)
                firstValue.fulfill()
            }, onFailure: { recorder.errors.append($0) })
        mailbox.publish(0.5)
        delivery.start()
        await fulfillment(of: [firstValue], timeout: 2)
        delivery.invalidate()
        mailbox.publish(0.9)
        mailbox.fail(.invalidAudioBuffer)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(recorder.values, [0.5])
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testTerminalFailureClosesDeliveryBeforeInvokingErrorHandler() async throws {
        let recorder = Recorder()
        let failed = expectation(description: "Terminal failure")
        let mailbox = CaptureMailbox<Double>()
        let delivery = CaptureDelivery(mailbox: mailbox, interval: 0.05,
            onValue: { recorder.values.append($0) },
            onFailure: { error in
                recorder.errors.append(error)
                mailbox.publish(1)
                failed.fulfill()
            })
        mailbox.publish(0.5)
        mailbox.fail(.invalidAudioBuffer)
        delivery.start()
        await fulfillment(of: [failed], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(recorder.values.isEmpty)
        XCTAssertEqual(recorder.errors, [.invalidAudioBuffer])
    }

    func testBusyMainThreadDoesNotCauseDeliveryToCatchUpAboveTwentyHz() async {
        let recorder = Recorder()
        let received = expectation(description: "Three throttled samples")
        received.expectedFulfillmentCount = 3
        let mailbox = CaptureMailbox<Double>()
        let delivery = CaptureDelivery(mailbox: mailbox, interval: 0.05, staleValue: 0,
            onValue: { value in
                recorder.values.append(value)
                recorder.times.append(ProcessInfo.processInfo.systemUptime)
                if recorder.values.count == 1 { Thread.sleep(forTimeInterval: 0.12) }
                received.fulfill()
            }, onFailure: { _ in XCTFail("Unexpected capture error") })
        mailbox.publish(1)
        delivery.start()
        await fulfillment(of: [received], timeout: 2)
        delivery.invalidate()
        XCTAssertEqual(recorder.values, [1, 0, 0])
        for index in 1..<recorder.times.count {
            XCTAssertGreaterThanOrEqual(recorder.times[index] - recorder.times[index - 1], 0.05)
        }
    }

    func testSmootherAttacksQuicklyReleasesGraduallyAndStaysNormalized() {
        let smoother = AudioLevelSmoother()
        XCTAssertEqual(smoother.consume(rms: 0, at: 0), 0)
        let attack = smoother.consume(rms: 1, at: 0.05)
        let release = smoother.consume(rms: 0, at: 0.10)
        XCTAssertGreaterThan(attack, 0.7)
        XCTAssertLessThan(attack, 1)
        XCTAssertLessThan(release, attack)
        XCTAssertGreaterThan(release, 0.5)
        XCTAssertEqual(smoother.consume(rms: .nan, at: 10), 0, accuracy: 0.01)
        XCTAssertTrue((0...1).contains(smoother.consume(rms: .infinity, at: 11)))
    }

    func testInvalidIntervalFailsBeforePermissionAndRepeatedStopIsSafe() async {
        let capture = ScreenSyncCapture()
        for interval in [0, -1, .nan, .infinity] {
            do {
                try await capture.start(displayID: 0, zones: [], interval: interval) { _ in
                    XCTFail("Invalid starts must not deliver colors")
                }
                XCTFail("Invalid interval must throw")
            } catch {
                XCTAssertEqual(error as? CaptureError, .invalidInterval)
            }
        }
        await capture.stop()
        await capture.stop()
        XCTAssertFalse(capture.isRunning)
    }
}
