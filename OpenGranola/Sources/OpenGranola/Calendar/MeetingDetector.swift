import AppKit
import CoreAudio
import Foundation
import Observation
import os

private let detectorLog = Logger(subsystem: "com.opengranola", category: "MeetingDetector")

/// Represents a detected meeting/call.
struct DetectedMeeting: Identifiable, Sendable {
    let id: String
    let title: String
    let detectedAt: Date

    enum Source: String, Sendable {
        case audioDevice
        case process
    }
    let source: Source
}

/// Known meeting app bundle identifiers.
private let meetingAppBundleIDs: Set<String> = [
    "us.zoom.xos",
    "com.microsoft.teams",
    "com.microsoft.teams2",
    "com.tinyspeck.slackmacgap",
    "com.apple.FaceTime",
    "com.cisco.webexmeetingsapp",
    "com.cisco.webex.meetings",
    "com.brave.Browser",
]

/// Bundle IDs for browsers (Google Meet, etc. run inside these).
private let browserBundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.apple.Safari",
    "com.microsoft.edgemac",
    "org.mozilla.firefox",
    "com.brave.Browser",
    "com.vivaldi.Vivaldi",
    "company.thebrowser.Browser",  // Arc
]

/// Monitors the system for meeting/call activity using two signals:
/// 1. CoreAudio device list changes (virtual devices created by meeting apps)
/// 2. NSWorkspace process launches for known meeting apps
@Observable
@MainActor
final class MeetingDetector {
    /// The currently detected meeting, if any. Observed by the UI to show popup.
    private(set) var detectedMeeting: DetectedMeeting?

    private var isMonitoring = false

    /// Event IDs that have been dismissed or acted upon — won't re-trigger.
    private var suppressedIDs: Set<String> = []

    /// Cooldown: don't re-trigger for the same source within this interval.
    private let cooldownInterval: TimeInterval = 300 // 5 minutes

    /// Tracks last detection time per source key to enforce cooldown.
    private var lastDetectionTimes: [String: Date] = [:]

    /// Snapshot of audio device IDs at last check, for diffing.
    private var knownDeviceIDs: Set<AudioDeviceID> = []

    /// CoreAudio listener block reference (must be retained to remove later).
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?

    /// NSWorkspace observer token.
    private var launchObserver: NSObjectProtocol?

    /// Periodic timer for checking audio device "is running" state.
    private var audioRunningTimer: Timer?

    /// Set of device IDs that were "running" last time we checked.
    private var devicesRunningAudio: Set<AudioDeviceID> = []

    // MARK: - Public API

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        detectorLog.info("MeetingDetector started")

        // Take initial snapshot of audio devices
        knownDeviceIDs = Set(Self.allAudioDeviceIDs())
        devicesRunningAudio = Self.devicesCurrentlyRunning()

        installDeviceListListener()
        installProcessLaunchObserver()
        startAudioRunningPoller()
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        detectorLog.info("MeetingDetector stopped")

        removeDeviceListListener()
        removeProcessLaunchObserver()
        audioRunningTimer?.invalidate()
        audioRunningTimer = nil
    }

    /// Dismiss a detected meeting (user clicked Dismiss).
    func dismiss(id: String) {
        suppressedIDs.insert(id)
        if detectedMeeting?.id == id {
            detectedMeeting = nil
        }
    }

    /// Clear the current detection (e.g., user started recording).
    func clearDetection() {
        if let meeting = detectedMeeting {
            suppressedIDs.insert(meeting.id)
        }
        detectedMeeting = nil
    }

    // MARK: - Audio Device List Monitoring

    /// Detects when new audio devices appear (meeting apps often create virtual devices).
    private func installDeviceListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.handleDeviceListChange()
            }
        }
        deviceListListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeDeviceListListener() {
        guard let block = deviceListListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        deviceListListenerBlock = nil
    }

    private func handleDeviceListChange() {
        let currentIDs = Set(Self.allAudioDeviceIDs())
        let newDevices = currentIDs.subtracting(knownDeviceIDs)
        knownDeviceIDs = currentIDs

        guard !newDevices.isEmpty else { return }

        // Get names of new devices for logging and display
        let newDeviceNames = newDevices.compactMap { Self.deviceName(for: $0) }
        detectorLog.info("New audio devices detected: \(newDeviceNames.joined(separator: ", "))")

        let sourceKey = "audioDevice"
        guard !isOnCooldown(sourceKey: sourceKey) else { return }

        let title = newDeviceNames.first ?? "Audio device"
        let meetingID = "audio-\(newDevices.sorted().map(String.init).joined(separator: "-"))"

        guard !suppressedIDs.contains(meetingID) else { return }

        triggerDetection(DetectedMeeting(
            id: meetingID,
            title: "Meeting detected",
            detectedAt: .now,
            source: .audioDevice
        ), sourceKey: sourceKey)
    }

    // MARK: - Audio "Is Running" Polling

    /// Polls every 5 seconds to check if any audio device started being used.
    /// This catches browser-based meetings (Google Meet) where no new device appears
    /// but an existing device starts streaming audio.
    private func startAudioRunningPoller() {
        audioRunningTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAudioRunningState()
            }
        }
    }

    private func checkAudioRunningState() {
        let currentlyRunning = Self.devicesCurrentlyRunning()
        let newlyRunning = currentlyRunning.subtracting(devicesRunningAudio)
        devicesRunningAudio = currentlyRunning

        guard !newlyRunning.isEmpty else { return }

        let sourceKey = "audioRunning"
        guard !isOnCooldown(sourceKey: sourceKey) else { return }

        let meetingID = "running-\(newlyRunning.sorted().map(String.init).joined(separator: "-"))"
        guard !suppressedIDs.contains(meetingID) else { return }

        detectorLog.info("Audio devices started running: \(newlyRunning.map(String.init).joined(separator: ", "))")

        triggerDetection(DetectedMeeting(
            id: meetingID,
            title: "Call detected",
            detectedAt: .now,
            source: .audioDevice
        ), sourceKey: sourceKey)
    }

    // MARK: - Process Monitoring

    private func installProcessLaunchObserver() {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleAppLaunch(notification)
            }
        }
    }

    private func removeProcessLaunchObserver() {
        if let observer = launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            launchObserver = nil
        }
    }

    private func handleAppLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }

        // Only trigger for known meeting apps (not browsers — they're handled by audio detection)
        guard meetingAppBundleIDs.contains(bundleID) else { return }

        let sourceKey = "process-\(bundleID)"
        guard !isOnCooldown(sourceKey: sourceKey) else { return }

        let appName = app.localizedName ?? bundleID
        let meetingID = "process-\(bundleID)"
        guard !suppressedIDs.contains(meetingID) else { return }

        detectorLog.info("Meeting app launched: \(appName) (\(bundleID))")

        triggerDetection(DetectedMeeting(
            id: meetingID,
            title: "\(appName) opened",
            detectedAt: .now,
            source: .process
        ), sourceKey: sourceKey)
    }

    // MARK: - Helpers

    private func triggerDetection(_ meeting: DetectedMeeting, sourceKey: String) {
        lastDetectionTimes[sourceKey] = .now
        detectedMeeting = meeting
    }

    private func isOnCooldown(sourceKey: String) -> Bool {
        if let lastTime = lastDetectionTimes[sourceKey],
           Date.now.timeIntervalSince(lastTime) < cooldownInterval {
            return true
        }
        return false
    }

    // MARK: - CoreAudio Helpers

    /// Returns all audio device IDs on the system.
    static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        return status == noErr ? deviceIDs : []
    }

    /// Returns the set of audio device IDs that are currently actively streaming.
    static func devicesCurrentlyRunning() -> Set<AudioDeviceID> {
        var running = Set<AudioDeviceID>()
        for deviceID in allAudioDeviceIDs() {
            if isDeviceRunning(deviceID) {
                running.insert(deviceID)
            }
        }
        return running
    }

    /// Check if a specific audio device is currently running (streaming audio).
    static func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }

    /// Get the human-readable name of an audio device.
    static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
        return status == noErr ? name as String : nil
    }
}
