// Layer: EngineAgent system observation.
// Role: translate OS observations into immutable SystemConditions without
// touching torrent records or performing recovery itself.
// Must-not: create volume paths, restart the agent, or poll in a timer loop.
// Invariants: callbacks are emitted only after a changed snapshot (except for
// mount notifications), networkGeneration changes on any path/interface change,
// and stop() is idempotent.

import AppKit
import Foundation
import Network
import TorrentinoIPC

final class SystemConditionMonitor: @unchecked Sendable {
    private static let powerStateNotification = Notification.Name("NSProcessInfoPowerStateDidChangeNotification")
    private static let willSleepNotification = Notification.Name("NSWorkspaceWillSleepNotification")
    private static let didWakeNotification = Notification.Name("NSWorkspaceDidWakeNotification")
    private static let didMountNotification = Notification.Name("NSWorkspaceDidMountNotification")
    private static let didUnmountNotification = Notification.Name("NSWorkspaceDidUnmountNotification")

    private let callback: @Sendable (SystemConditions) -> Void
    private let queue = DispatchQueue(label: "com.torrentino.app.engine-agent.system-conditions", qos: .utility)
    private let pathMonitor = NWPathMonitor()
    private let memorySource: DispatchSourceMemoryPressure
    private let lock = NSLock()
    private var conditions = SystemConditions.normal
    private var pathSignature = ""
    private var observers: [NSObjectProtocol] = []
    private var started = false

    init(callback: @escaping @Sendable (SystemConditions) -> Void) {
        self.callback = callback
        self.memorySource = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: queue)
    }

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        installObservers()
        memorySource.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.memorySource.data
            let level: MemoryPressureLevel
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                level = .normal
            }
            self.update { $0.merged(memoryPressure: level) }
        }
        memorySource.resume()

        let processInfo = ProcessInfo.processInfo
        update {
            $0.merged(
                thermal: Self.thermalCondition(processInfo.thermalState),
                lowPower: processInfo.isLowPowerModeEnabled
            )
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path: path)
        }
        pathMonitor.start(queue: queue)
    }

    func stop() {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        started = false
        let tokens = observers
        observers.removeAll()
        lock.unlock()

        pathMonitor.cancel()
        memorySource.cancel()
        let center = NotificationCenter.default
        for token in tokens {
            center.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let processTokens = [
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.update { $0.merged(thermal: Self.thermalCondition(ProcessInfo.processInfo.thermalState)) }
                }
            },
            center.addObserver(forName: Self.powerStateNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.update { $0.merged(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled) }
                }
            },
        ]
        let workspaceTokens = [
            workspaceCenter.addObserver(forName: Self.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.update { $0.merged(sleeping: true) }
                }
            },
            workspaceCenter.addObserver(forName: Self.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.update { $0.merged(sleeping: false) }
                }
            },
            workspaceCenter.addObserver(forName: Self.didMountNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.publishCurrent(force: true)
                }
            },
            workspaceCenter.addObserver(forName: Self.didUnmountNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.publishCurrent(force: true)
                }
            },
        ]
        lock.lock()
        observers = processTokens + workspaceTokens
        lock.unlock()
    }

    private func handle(path: NWPath) {
        let reachability: NetworkReachability
        switch path.status {
        case .satisfied: reachability = .satisfied
        case .requiresConnection: reachability = .requiresConnection
        case .unsatisfied: reachability = .unsatisfied
        @unknown default: reachability = .unknown
        }
        let interfaces = path.availableInterfaces
            .map { "\($0.type):\(String(describing: $0))" }
            .sorted()
            .joined(separator: ",")
        // NWPath's description includes the selected route and endpoint
        // identity that is not exposed as a stable typed property. Keeping it
        // in the signature catches same-interface VPN/address changes.
        let routeIdentity = String(reflecting: path)
        let signature = Self.pathSignature(
            status: String(describing: path.status),
            interfaces: interfaces,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            routeIdentity: routeIdentity
        )
        lock.lock()
        let changed = signature != pathSignature
        pathSignature = signature
        let generation = changed ? conditions.networkGeneration &+ 1 : conditions.networkGeneration
        lock.unlock()
        update {
            $0.merged(network: reachability, networkGeneration: generation)
        }
    }

    private func update(_ transform: (SystemConditions) -> SystemConditions) {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        let next = transform(conditions)
        let changed = next != conditions
        conditions = next
        lock.unlock()
        if changed { callback(next) }
    }

    private func publishCurrent(force: Bool) {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        let snapshot = conditions
        lock.unlock()
        if force { callback(snapshot) }
    }

    static func pathSignature(
        status: String,
        interfaces: String,
        isExpensive: Bool,
        isConstrained: Bool,
        supportsIPv4: Bool,
        supportsIPv6: Bool,
        routeIdentity: String
    ) -> String {
        "\(status)|\(interfaces)|\(isExpensive)|\(isConstrained)|\(supportsIPv4)|\(supportsIPv6)|route=\(routeIdentity)"
    }

    private static func thermalCondition(_ state: ProcessInfo.ThermalState) -> ThermalCondition {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
}
