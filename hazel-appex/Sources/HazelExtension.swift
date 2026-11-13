// HazelExtension.swift
//
// Ported from Phosphene's PhospheneExtension.swift + WallpaperExtensionConfig.swift
// (MIT License, Copyright (c) 2026 kageroumado). Simplified: accept all
// WallpaperAgent connections (no caller-signature gate in this build),
// scan the single-video library, watch prefs/library Darwin signals.

import AppKit
import ExtensionFoundation
import Foundation

@main
final class HazelWallpaperExtension: NSObject, AppExtension {
    override required init() {
        super.init()
        let frameworkPath = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if dlopen(frameworkPath, RTLD_LAZY) != nil {
            hazelLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier)) — WallpaperExtensionKit loaded")
            HazelLibrary.shared.startObserving()
            HazelPrefsSource.start()
        } else {
            hazelLog("INIT — dlopen failed: \(String(cString: dlerror()))")
        }
    }

    var configuration: some AppExtensionConfiguration {
        HazelWallpaperExtensionConfig()
    }
}

struct HazelWallpaperExtensionConfig: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        hazelLog("XPC from PID=\(connection.processIdentifier)")
        guard HazelCallerValidation.isAcceptable(connection) else {
            hazelLog("XPC rejected: non-Apple caller")
            return false
        }

        let exported = NSXPCInterface(with: (any WallpaperExtensionXPCProtocol).self)

        // Class whitelist from runtime-loaded WallpaperExtensionKit classes.
        let typeNames = [
            "WallpaperIDXPC",
            "WallpaperCreationRequestXPC",
            "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC",
            "WallpaperSnapshotXPC",
            "WallpaperContentTypeSetXPC",
            "WallpaperChoiceIDXPC",
            "WallpaperChoiceIDsXPC",
            "WallpaperExtensionChoiceRequestXPC",
            "WallpaperChoiceRequestAdditionResultXPC",
            "WallpaperDebugRequestXPC",
            "WallpaperDebugResponseXPC",
            "WallpaperMigrationVersionXPC",
            "WallpaperSettingsViewModelsXPC",
            "AuditTokenXPC",
        ]
        let allTypes = NSMutableSet()
        for name in typeNames {
            if let cls = objc_getClass(name) {
                allTypes.add(cls)
            }
        }
        allTypes.add(NSString.self)
        allTypes.add(NSNumber.self)
        allTypes.add(NSData.self)
        allTypes.add(NSArray.self)
        allTypes.add(NSDictionary.self)
        allTypes.add(NSURL.self)
        allTypes.add(NSError.self)

        let classes = allTypes as! Set<AnyHashable>
        let selectors: [(Selector, Int, Bool)] = [
            (#selector(HazelWallpaperHandler.acquire(withId:request:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.acquire(withId:request:reply:)), 1, false),
            (#selector(HazelWallpaperHandler.acquire(withId:request:reply:)), 0, true),
            (#selector(HazelWallpaperHandler.update(withId:request:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.update(withId:request:reply:)), 1, false),
            (#selector(HazelWallpaperHandler.invalidate(withId:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.snapshot(withId:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.snapshot(withId:reply:)), 0, true),
            (#selector(HazelWallpaperHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, true),
            (#selector(HazelWallpaperHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 1, false),
            (#selector(HazelWallpaperHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, true),
            (#selector(HazelWallpaperHandler.removeChoiceRequest(withChoiceRequest:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.selectedChoicesDidChange(for:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 1, false),
            (#selector(HazelWallpaperHandler.isChoiceDownloaded(with:reply:)), 0, false),
        (#selector(HazelWallpaperHandler.isChoiceDownloaded(with:reply:)), 0, true),
            (#selector(HazelWallpaperHandler.download(withChoiceID:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.pauseDownload(for:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.cancelDownload(for:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.resumeDownload(for:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.removeDownload(for:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.migrateSelectedChoice(for:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.migrateSelectedChoice(for:reply:)), 0, true),
            (#selector(HazelWallpaperHandler.migrate(from:to:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.migrate(from:to:reply:)), 1, false),
            (#selector(HazelWallpaperHandler.skipShuffledContent(withId:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.canSkipShuffledContent(withId:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.handleDebugRequest(for:reply:)), 0, false),
            (#selector(HazelWallpaperHandler.handleDebugRequest(for:reply:)), 0, true),
            (#selector(HazelWallpaperHandler.handleNotification(withNamed:reply:)), 0, false),
        ]
        for (sel, idx, isReply) in selectors {
            exported.setClasses(classes, for: sel, argumentIndex: idx, ofReply: isReply)
        }

        connection.exportedInterface = exported
        // No remoteObjectInterface: the extension never calls back into the host,
        // so no proxy classes need whitelisting.
        connection.exportedObject = HazelWallpaperHandler()
        connection.resume()
        hazelLog("XPC accepted")
        return true
    }
}
