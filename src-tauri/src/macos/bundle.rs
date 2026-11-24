use std::path::Path;

pub(super) const USAGE_BUNDLE_ID: &str = "com.local.CodexUsage";

pub(super) fn app_bundle(executable: &Path) -> Option<&Path> {
    let macos = executable.parent()?;
    let contents = macos.parent()?;
    let bundle = contents.parent()?;
    (macos.ends_with("MacOS") && contents.ends_with("Contents") && bundle.extension()? == "app")
        .then_some(bundle)
}
