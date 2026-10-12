import AppKit
import DiskArbitration
import SwiftUI

struct ExternalDrive: Identifiable, Equatable {
    let id: String
    var name: String
    var volumes: [String]

    var displayName: String {
        volumes.isEmpty ? name : volumes.joined(separator: ", ")
    }
}

@MainActor
final class DriveStore: ObservableObject {
    static let shared = DriveStore()

    @Published private(set) var drives: [ExternalDrive] = []
    @Published private(set) var ejecting = Set<String>()
    @Published var statusMessage: String?

    private var session: DASession?
    private let queue = DispatchQueue(label: "DriveDock.disk-arbitration")
    private var records: [String: DiskRecord] = [:]

    private struct DiskRecord {
        var wholeDisk: String?
        var isWholeExternalDisk: Bool
        var mediaName: String
        var volumeName: String?
    }

    private init() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            statusMessage = "Disk services are unavailable."
            return
        }
        self.session = session
        DASessionSetDispatchQueue(session, queue)

        DARegisterDiskAppearedCallback(session, nil, diskAppeared, nil)
        DARegisterDiskDisappearedCallback(session, nil, diskDisappeared, nil)
        refresh()
    }

    func refresh() {
        guard let session else { return }
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []
        for url in urls {
            if let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) {
                ingest(disk)
            }
        }
        publishDrives()
    }

    func eject(_ drive: ExternalDrive) {
        guard !ejecting.contains(drive.id) else { return }
        guard let session, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, drive.id) else {
            statusMessage = "Could not access \(drive.displayName)."
            return
        }

        ejecting.insert(drive.id)
        statusMessage = "Ejecting \(drive.displayName)…"
        let request = EjectRequest(diskID: drive.id, diskName: drive.displayName, store: self)
        let context = Unmanaged.passRetained(request).toOpaque()
        DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), ejectCompleted, context)
    }

    func ejectAll() {
        for drive in drives where !ejecting.contains(drive.id) {
            eject(drive)
        }
    }

    fileprivate func finishEject(_ request: EjectRequest, succeeded: Bool, reason: String?) {
        ejecting.remove(request.diskID)

        if succeeded {
            statusMessage = "Drive ejected."
        } else {
            statusMessage = reason.map { "Couldn’t eject drive: \($0)" } ?? "Couldn’t eject drive. Close files using it and try again."
        }
        refresh()
    }

    fileprivate func ingestFromCallback(_ disk: DADisk) {
        ingest(disk)
        publishDrives()
    }

    fileprivate func removeFromCallback(_ disk: DADisk) {
        let name = DADiskGetBSDName(disk).map { String(cString: $0) }
        if let name { records.removeValue(forKey: name) }
        publishDrives()
    }

    private func ingest(_ disk: DADisk) {
        guard let raw = DADiskCopyDescription(disk) as NSDictionary? else { return }
        guard let bsdNamePointer = DADiskGetBSDName(disk) else { return }
        let bsdName = String(cString: bsdNamePointer)
        let isWhole = (raw[kDADiskDescriptionMediaWholeKey] as? NSNumber)?.boolValue ?? false
        let isInternal = (raw[kDADiskDescriptionDeviceInternalKey] as? NSNumber)?.boolValue ?? true
        let mediaName = raw[kDADiskDescriptionMediaNameKey] as? String ?? "External Drive"
        let volumeName = raw[kDADiskDescriptionVolumeNameKey] as? String

        if isWhole {
            records[bsdName] = DiskRecord(
                wholeDisk: bsdName,
                isWholeExternalDisk: !isInternal,
                mediaName: mediaName,
                volumeName: nil
            )
            return
        }

        guard let wholeDisk = DADiskCopyWholeDisk(disk),
              let wholeNamePointer = DADiskGetBSDName(wholeDisk) else {
            records[bsdName] = DiskRecord(wholeDisk: nil, isWholeExternalDisk: false, mediaName: mediaName, volumeName: volumeName)
            return
        }
        records[bsdName] = DiskRecord(
            wholeDisk: String(cString: wholeNamePointer),
            isWholeExternalDisk: false,
            mediaName: mediaName,
            volumeName: volumeName
        )
    }

    private func publishDrives() {
        var byDisk: [String: ExternalDrive] = [:]
        for (bsdName, record) in records where record.isWholeExternalDisk {
            byDisk[bsdName] = ExternalDrive(id: bsdName, name: record.mediaName, volumes: [])
        }
        for record in records.values {
            guard let wholeDisk = record.wholeDisk,
                  var drive = byDisk[wholeDisk],
                  let volume = record.volumeName,
                  !drive.volumes.contains(volume) else { continue }
            drive.volumes.append(volume)
            drive.volumes.sort()
            byDisk[wholeDisk] = drive
        }
        drives = byDisk.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

private final class EjectRequest {
    let diskID: String
    let diskName: String
    weak var store: DriveStore?

    init(diskID: String, diskName: String, store: DriveStore) {
        self.diskID = diskID
        self.diskName = diskName
        self.store = store
    }
}

private func diskAppeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            DriveStore.shared.ingestFromCallback(disk)
        }
    }
}

private func diskDisappeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            DriveStore.shared.removeFromCallback(disk)
        }
    }
}

private func ejectCompleted(_ disk: DADisk?, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let request = Unmanaged<EjectRequest>.fromOpaque(context).takeRetainedValue()
    let succeeded = dissenter == nil
    let reason = dissenter.flatMap { DADissenterGetStatusString($0) as String? }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            request.store?.finishEject(request, succeeded: succeeded, reason: reason)
        }
    }
}

@main
struct DriveDockApp: App {
    @StateObject private var store = DriveStore.shared

    var body: some Scene {
        MenuBarExtra("DriveDock", systemImage: "externaldrive") {
            MenuContentView()
                .environmentObject(store)
                .frame(width: 300)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuContentView: View {
    @EnvironmentObject private var store: DriveStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("External Drives", systemImage: "externaldrive")
                    .font(.headline)
                Spacer()
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh drives")
            }

            if store.drives.isEmpty {
                Text("No external drives connected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.drives) { drive in
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(drive.displayName)
                                .lineLimit(1)
                            Text(drive.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("Eject") {
                            store.eject(drive)
                        }
                        .disabled(store.ejecting.contains(drive.id))
                    }
                }

                Button {
                    store.ejectAll()
                } label: {
                    Label("Eject All", systemImage: "eject.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.ejecting.count == store.drives.count)
            }

            if let message = store.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            Button("Quit DriveDock") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }
}
