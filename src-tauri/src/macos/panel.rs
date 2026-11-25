use objc2::MainThreadMarker;
use objc2_app_kit::{NSEvent, NSScreen, NSWindow};
use objc2_core_foundation::{CFDictionary, CFNumber, CFString, CFType};
use objc2_core_graphics::{
    CGRectMakeWithDictionaryRepresentation, CGWindowLevelForKey, CGWindowLevelKey,
    CGWindowListCopyWindowInfo, CGWindowListOption, kCGWindowBounds, kCGWindowLayer,
    kCGWindowOwnerPID,
};
use objc2_foundation::{NSMouseInRect, NSPoint, NSRect, NSSize};
use tauri::tray::TrayIcon;
use tauri::{PhysicalPosition, Rect, WebviewWindow};

// 同一状态项在每块菜单栏都有 WindowServer 窗口，NSStatusItem.button 只暴露其中一份。
fn status_item_frames(desktop_top: f64) -> Vec<NSRect> {
    let Some(list) = CGWindowListCopyWindowInfo(CGWindowListOption::OptionOnScreenOnly, 0) else {
        return Vec::new();
    };
    let status_level = CGWindowLevelForKey(CGWindowLevelKey::StatusWindowLevelKey);
    // SAFETY: Quartz 返回 CFString 键和 CFType 值的窗口描述字典。
    let rows = unsafe { list.cast_unchecked::<CFDictionary<CFString, CFType>>() };
    rows.iter()
        .filter_map(|row| {
            let number = |key: &CFString| row.get(key)?.downcast::<CFNumber>().ok()?.as_i32();
            // SAFETY: 这些常量是 Quartz 提供的静态字典键。
            let (pid, layer, bounds) =
                unsafe { (kCGWindowOwnerPID, kCGWindowLayer, kCGWindowBounds) };
            if number(pid)? != std::process::id() as i32 || number(layer)? != status_level {
                return None;
            }
            let bounds = row.get(bounds)?.downcast::<CFDictionary>().ok()?;
            let mut frame = NSRect::ZERO;
            // SAFETY: bounds 是 Quartz 的窗口边界字典，frame 可写。
            if !unsafe { CGRectMakeWithDictionaryRepresentation(Some(&bounds), &mut frame) } {
                return None;
            }
            frame.origin.y = desktop_top - frame.max().y;
            Some(frame)
        })
        .collect()
}

fn clicked_icon(frames: &[NSRect], click: NSPoint, cursor: NSPoint) -> Option<NSRect> {
    [click, cursor].into_iter().find_map(|point| {
        frames
            .iter()
            .copied()
            .find(|frame| NSMouseInRect(point, *frame, false))
    })
}

fn panel_top_left(icon: NSRect, area: NSRect, size: NSSize) -> NSPoint {
    NSPoint::new(
        (icon.mid().x - size.width / 2.0)
            .clamp(area.min().x, (area.max().x - size.width).max(area.min().x)),
        (icon.min().y - 4.0).clamp((area.min().y + size.height).min(area.max().y), area.max().y),
    )
}

pub fn position(
    window: &WebviewWindow,
    tray: &TrayIcon,
    click: Option<(PhysicalPosition<f64>, Rect)>,
) -> Option<bool> {
    let window = window.clone();
    tray.with_inner_tray_icon(move |tray| {
        let mtm = MainThreadMarker::new()?;
        let status = tray.ns_status_item()?.button(mtm)?.window()?;
        let (icon, screen) = if let Some((position, rect)) = click {
            let screens = NSScreen::screens(mtm);
            let desktop_top = screens.firstObject()?.frame().max().y;
            // 事件坐标使用发送事件的状态项窗口倍率，副本可能位于另一块屏幕。
            let item_width = status.frame().size.width;
            let width_error = |scale| (rect.size.to_logical::<f64>(scale).width - item_width).abs();
            let scale = screens
                .iter()
                .map(|s| s.backingScaleFactor())
                .min_by(|a, b| width_error(*a).total_cmp(&width_error(*b)))?;
            let point = position.to_logical::<f64>(scale);
            let click = NSPoint::new(point.x, desktop_top - point.y);
            let frames = status_item_frames(desktop_top);
            let icon = clicked_icon(&frames, click, NSEvent::mouseLocation());
            let anchor = icon.map_or(click, |frame| frame.mid());
            let screen = screens
                .iter()
                .find(|s| NSMouseInRect(anchor, s.frame(), false))?;
            let icon = icon.unwrap_or_else(|| {
                NSRect::new(
                    NSPoint::new(click.x, screen.frame().max().y - status.frame().size.height),
                    NSSize::ZERO,
                )
            });
            (icon, screen)
        } else {
            (status.frame(), status.screen()?)
        };
        // SAFETY: Tauri 持有该 NSWindow，托盘闭包在主线程内同步使用它。
        let panel = unsafe { window.ns_window().ok()?.cast::<NSWindow>().as_ref()? };
        let same_screen = panel.screen().as_deref() == Some(&*screen);
        panel.setFrameTopLeftPoint(panel_top_left(
            icon,
            screen.visibleFrame(),
            panel.frame().size,
        ));
        Some(same_screen)
    })
    .ok()
    .flatten()
}

pub fn resize(window: &WebviewWindow, height: f64) {
    let _ = window.with_webview(move |webview| {
        // SAFETY: with_webview 在主线程提供当前 WebView 所在的有效 NSWindow。
        let panel = unsafe { &*webview.ns_window().cast::<NSWindow>() };
        let mut frame = panel.frame();
        // AppKit 单独调整大小会固定左下角；一次更新整个 frame 让菜单下方的上沿固定。
        frame.origin.y = frame.max().y - height;
        frame.size.height = height;
        panel.setFrame_display(frame, true);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clicking_the_internal_copy_uses_its_own_menu_bar_frame() {
        let internal = NSRect::new(NSPoint::new(922.0, 876.0), NSSize::new(69.0, 24.0));
        let external = NSRect::new(NSPoint::new(2842.0, 1056.0), NSSize::new(69.0, 24.0));
        let frames = [external, internal];
        // 模拟实际点击左边缘后鼠标已移往外屏，仍以被点中的整个图标居中。
        let icon = clicked_icon(&frames, NSPoint::new(928.0, 888.0), external.mid()).unwrap();
        let work_area = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(1440.0, 876.0));
        assert_eq!(
            panel_top_left(icon, work_area, NSSize::new(360.0, 466.0)),
            NSPoint::new(776.5, 872.0)
        );
        assert_eq!(
            clicked_icon(&frames, external.mid(), internal.mid()),
            Some(external)
        );
    }

    #[test]
    fn keeps_the_panel_on_a_left_display_when_the_icon_is_near_its_edge() {
        let icon = NSRect::new(NSPoint::new(-64.0, 816.0), NSSize::new(63.0, 24.0));
        let work_area = NSRect::new(NSPoint::new(-1440.0, -60.0), NSSize::new(1440.0, 876.0));
        assert_eq!(
            panel_top_left(icon, work_area, NSSize::new(360.0, 466.0)),
            NSPoint::new(-360.0, 812.0)
        );
    }
}
