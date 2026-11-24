use std::path::{Path, PathBuf};

use anyhow::Result;
use objc2::rc::{Retained, autoreleasepool};
use objc2::runtime::Bool;
use objc2_foundation::{
    NSBundle, NSData, NSString, NSURL, NSURLBookmarkResolutionOptions, NSUserDefaults,
};
use objc2_service_management::{SMAppService, SMAppServiceStatus};
use sha2::{Digest, Sha256};

mod bundle;

use bundle::{USAGE_BUNDLE_ID, app_bundle};

const AGENT_PLIST: &str = "com.local.CodexUsage.Watcher.plist";
const WATCHER_EXECUTABLE: &str = "Contents/MacOS/CodexUsageWatcher";

pub fn register_companion() {
    if std::env::var_os("XCTestBundlePath").is_some() {
        return;
    }
    autoreleasepool(|_| {
        let Ok(executable) = std::env::current_exe().and_then(|path| path.canonicalize()) else {
            return;
        };
        let Some(bundle) = app_bundle(&executable) else {
            return;
        };
        if NSBundle::mainBundle().bundleIdentifier().as_deref()
            != Some(NSString::from_str(USAGE_BUNDLE_ID).as_ref())
        {
            return;
        }
        let agent = bundle
            .join("Contents/Library/LaunchAgents")
            .join(AGENT_PLIST);
        let watcher = bundle.join(WATCHER_EXECUTABLE);
        let Ok(fingerprint) = registration_fingerprint(bundle, &executable, &watcher, &agent)
        else {
            return;
        };

        let defaults = NSUserDefaults::standardUserDefaults();
        let key = NSString::from_str("companionHelperFingerprint");
        let stored = defaults.stringForKey(&key).map(|value| value.to_string());
        // SAFETY: The minimum supported macOS is 13, and the plist is inside the current bundle.
        let service =
            unsafe { SMAppService::agentServiceWithPlistName(&NSString::from_str(AGENT_PLIST)) };
        // SAFETY: This service identifies the current app's embedded agent.
        let status = unsafe { service.status() };
        let Some(action) = registration_action(status, stored.as_deref(), &fingerprint) else {
            return;
        };
        // SAFETY: Registration acts on the validated embedded agent through macOS ServiceManagement.
        if action == RegistrationAction::Refresh
            && let Err(error) = unsafe { service.unregisterAndReturnError() }
        {
            eprintln!(
                "Could not unregister Codex Usage companion: {}",
                error.code()
            );
            return;
        }
        // SAFETY: The current bundle and agent plist were validated above.
        if let Err(error) = unsafe { service.registerAndReturnError() } {
            eprintln!("Could not register Codex Usage companion: {}", error.code());
            return;
        }
        // SAFETY: NSString is a property-list type supported by NSUserDefaults.
        unsafe { defaults.setObject_forKey(Some(&NSString::from_str(&fingerprint)), &key) };
    });
}

#[derive(Debug, PartialEq, Eq)]
enum RegistrationAction {
    Register,
    Refresh,
}

fn registration_action(
    status: SMAppServiceStatus,
    stored: Option<&str>,
    current: &str,
) -> Option<RegistrationAction> {
    match status {
        SMAppServiceStatus::NotRegistered | SMAppServiceStatus::NotFound => {
            Some(RegistrationAction::Register)
        }
        SMAppServiceStatus::Enabled if stored != Some(current) => Some(RegistrationAction::Refresh),
        _ => None,
    }
}

fn registration_fingerprint(
    bundle: &Path,
    executable: &Path,
    watcher: &Path,
    agent: &Path,
) -> Result<String> {
    let mut fingerprint = Sha256::new();
    fingerprint.update(bundle.as_os_str().as_encoded_bytes());
    for file in [executable, watcher, agent] {
        fingerprint.update(Sha256::digest(std::fs::read(file)?));
    }
    Ok(format!("{:x}", fingerprint.finalize()))
}

pub fn legacy_interface_style() -> Option<String> {
    autoreleasepool(|_| {
        NSUserDefaults::standardUserDefaults()
            .persistentDomainForName(&NSString::from_str(USAGE_BUNDLE_ID))?
            .objectForKey(&NSString::from_str("interfaceStyle"))?
            .downcast::<NSString>()
            .ok()
            .map(|style| style.to_string())
    })
}

pub fn legacy_home() -> Option<PathBuf> {
    autoreleasepool(|_| {
        let defaults = NSUserDefaults::standardUserDefaults();
        let domain = defaults.persistentDomainForName(&NSString::from_str(USAGE_BUNDLE_ID))?;
        let bookmark = domain
            .objectForKey(&NSString::from_str("codexHomeBookmark"))?
            .downcast::<NSData>()
            .ok()?;
        let url = resolve_legacy_bookmark(&bookmark)?;
        let path = url.to_file_path()?;
        // 旧版和新版使用同一用户的文件权限，可直接访问已选的目录。
        ["sessions", "archived_sessions"]
            .into_iter()
            .any(|subdirectory| path.join(subdirectory).is_dir())
            .then_some(path)
    })
}

fn resolve_legacy_bookmark(bookmark: &NSData) -> Option<Retained<NSURL>> {
    let mut stale = Bool::NO;
    let options = NSURLBookmarkResolutionOptions::WithSecurityScope
        | NSURLBookmarkResolutionOptions::WithoutUI
        | NSURLBookmarkResolutionOptions::WithoutMounting;
    // SAFETY: stale is a valid writable BOOL, and the bookmark remains borrowed for the call.
    let url = unsafe {
        NSURL::URLByResolvingBookmarkData_options_relativeToURL_bookmarkDataIsStale_error(
            bookmark, options, None, &mut stale,
        )
    }
    .ok()?;
    (!stale.as_bool() && url.isFileURL()).then_some(url)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refreshes_changed_agent_registration_without_override_of_approval() {
        assert_eq!(
            registration_action(SMAppServiceStatus::Enabled, Some("old"), "new"),
            Some(RegistrationAction::Refresh)
        );
        assert_eq!(
            registration_action(SMAppServiceStatus::Enabled, Some("new"), "new"),
            None
        );
        assert_eq!(
            registration_action(SMAppServiceStatus::RequiresApproval, Some("old"), "new"),
            None
        );
        assert_eq!(
            registration_action(SMAppServiceStatus::NotRegistered, None, "new"),
            Some(RegistrationAction::Register)
        );
        assert_eq!(
            registration_action(SMAppServiceStatus::NotFound, None, "new"),
            Some(RegistrationAction::Register)
        );
    }

    #[test]
    fn locates_only_a_containing_application_bundle() {
        let app = Path::new("/Applications/Codex Usage.app");
        assert_eq!(
            app_bundle(&app.join("Contents/MacOS/Codex Usage")),
            Some(app)
        );
        assert_eq!(app_bundle(Path::new("/tmp/bin/Codex Usage")), None);
        assert_eq!(
            app_bundle(Path::new("/tmp/Bogus/Contents/MacOS/Codex Usage")),
            None
        );
    }

    #[test]
    fn agent_fingerprint_changes_when_the_signed_helper_changes() -> Result<()> {
        let source = Path::new(env!("CARGO_MANIFEST_DIR"));
        let plist = source.join("resources").join(AGENT_PLIST);
        let executable = source.join("Cargo.toml");
        let watcher = source.join("tauri.conf.json");
        let bundle = Path::new("/Applications/Codex Usage.app");
        let fingerprint = registration_fingerprint(bundle, &executable, &watcher, &plist)?;
        assert_ne!(
            fingerprint,
            registration_fingerprint(bundle, &executable, &plist, &plist)?,
        );
        assert_ne!(
            fingerprint,
            registration_fingerprint(bundle, &watcher, &watcher, &plist)?,
        );
        assert_ne!(
            fingerprint,
            registration_fingerprint(
                Path::new("/tmp/Codex Usage.app"),
                &executable,
                &watcher,
                &plist
            )?,
        );
        Ok(())
    }

    #[test]
    fn rejects_invalid_legacy_bookmark_data() {
        autoreleasepool(|_| {
            assert!(resolve_legacy_bookmark(&NSData::with_bytes(b"invalid bookmark")).is_none());
        });
    }
}
