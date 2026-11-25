use anyhow::{Result, ensure};
use std::ptr::null_mut;
use tauri::image::Image;
use windows_sys::Win32::Foundation::RECT;
use windows_sys::Win32::Graphics::Gdi::{
    ANTIALIASED_QUALITY, BITMAPINFO, BITMAPINFOHEADER, CreateCompatibleDC, CreateDIBSection,
    CreateFontW, DEFAULT_CHARSET, DIB_RGB_COLORS, DT_CENTER, DT_NOCLIP, DT_SINGLELINE, DT_VCENTER,
    DeleteDC, DeleteObject, DrawTextW, FW_SEMIBOLD, GdiFlush, HBITMAP, HDC, HFONT, SelectObject,
    SetBkColor, SetBkMode, SetTextColor, TRANSPARENT,
};
use windows_sys::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_DWORD, RegGetValueW};
use windows_sys::core::w;

pub fn light_taskbar() -> bool {
    let mut light = 0_u32;
    let mut size = size_of::<u32>() as u32;
    // 任务栏跟随 Windows 模式，可能与应用窗口的深浅色设置不同。
    unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
            w!("SystemUsesLightTheme"),
            RRF_RT_REG_DWORD,
            null_mut(),
            std::ptr::from_mut(&mut light).cast(),
            &mut size,
        ) == 0
            && light != 0
    }
}

struct Canvas {
    dc: HDC,
    bitmap: HBITMAP,
    font: HFONT,
}

impl Drop for Canvas {
    fn drop(&mut self) {
        unsafe {
            // 先销毁 DC，解除选中状态，再释放位图和字体。
            DeleteDC(self.dc);
            DeleteObject(self.bitmap);
            DeleteObject(self.font);
        }
    }
}

pub fn quota_icon(remaining: &str, light: bool) -> Result<Image<'static>> {
    const SIZE: i32 = 32;
    const BYTES: usize = (SIZE * SIZE * 4) as usize;
    unsafe {
        let mut canvas = Canvas {
            dc: CreateCompatibleDC(null_mut()),
            bitmap: null_mut(),
            font: null_mut(),
        };
        ensure!(!canvas.dc.is_null(), "cannot create tray drawing context");
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: SIZE,
                biHeight: -SIZE,
                biPlanes: 1,
                biBitCount: 32,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut pixels = null_mut();
        canvas.bitmap =
            CreateDIBSection(canvas.dc, &info, DIB_RGB_COLORS, &mut pixels, null_mut(), 0);
        ensure!(
            !canvas.bitmap.is_null() && !pixels.is_null(),
            "cannot create tray bitmap"
        );
        let face: Vec<u16> = "Segoe UI\0".encode_utf16().collect();
        canvas.font = CreateFontW(
            if remaining.len() == 3 { -17 } else { -26 },
            0,
            0,
            0,
            FW_SEMIBOLD as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET as u32,
            0,
            0,
            ANTIALIASED_QUALITY as u32,
            0,
            face.as_ptr(),
        );
        ensure!(!canvas.font.is_null(), "cannot create tray font");
        ensure!(
            !SelectObject(canvas.dc, canvas.bitmap).is_null(),
            "cannot select tray bitmap"
        );
        ensure!(
            !SelectObject(canvas.dc, canvas.font).is_null(),
            "cannot select tray font"
        );
        // 用黑底白字取得灰度覆盖率，作为透明度；避免 ClearType 彩边。
        std::slice::from_raw_parts_mut(pixels.cast::<u8>(), BYTES).fill(0);
        SetBkColor(canvas.dc, 0);
        SetBkMode(canvas.dc, TRANSPARENT as i32);
        SetTextColor(canvas.dc, 0x00ffffff);
        let text: Vec<u16> = remaining.encode_utf16().collect();
        let mut rect = RECT {
            left: 1,
            top: 0,
            right: SIZE - 1,
            bottom: SIZE,
        };
        // 排版矩形只用于居中，避免在它的边界静默裁掉数字。
        ensure!(
            DrawTextW(
                canvas.dc,
                text.as_ptr(),
                text.len() as i32,
                &mut rect,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOCLIP
            ) != 0,
            "cannot draw tray quota"
        );
        ensure!(GdiFlush() != 0, "cannot flush tray drawing");
        let mask = std::slice::from_raw_parts(pixels.cast::<u8>(), BYTES);
        let (mut left, mut top, mut right, mut bottom) = (SIZE, SIZE, 0, 0);
        for (index, pixel) in mask.chunks_exact(4).enumerate() {
            if pixel[0] > 8 {
                let (x, y) = (index as i32 % SIZE, index as i32 / SIZE);
                left = left.min(x);
                top = top.min(y);
                right = right.max(x);
                bottom = bottom.max(y);
            }
        }
        ensure!(left <= right && top <= bottom, "tray digits are empty");
        // 按实际字形居中，消除字体下降部留白，让不同位数的数字保持对齐。
        let offset_x = (SIZE - (right - left + 1)) / 2 - left;
        let offset_y = (SIZE - (bottom - top + 1)) / 2 - top;
        let foreground = if light {
            [35_u8, 42, 51]
        } else {
            [241_u8, 244, 248]
        };
        let mut rgba = vec![0; BYTES];
        for (index, pixel) in mask.chunks_exact(4).enumerate() {
            let alpha = pixel[0];
            let x = index as i32 % SIZE + offset_x;
            let y = index as i32 / SIZE + offset_y;
            if alpha == 0 || !(0..SIZE).contains(&x) || !(0..SIZE).contains(&y) {
                continue;
            }
            let destination = &mut rgba[((y * SIZE + x) * 4) as usize..][..4];
            // CreateIcon 会处理 alpha 预乘，这里保留直通 RGB，避免边缘被二次压暗。
            destination[..3].copy_from_slice(&foreground);
            destination[3] = alpha;
        }
        Ok(Image::new_owned(rgba, SIZE as u32, SIZE as u32))
    }
}

#[cfg(test)]
mod tests {
    use super::quota_icon;
    use std::collections::HashSet;

    #[test]
    fn all_quota_values_have_distinct_visible_unclipped_digits() {
        let mut rendered = HashSet::new();
        for (light, remaining) in [true, false]
            .into_iter()
            .flat_map(|light| (0..=100).map(move |value| (light, value)))
        {
            let icon = quota_icon(&remaining.to_string(), light).unwrap();
            assert_eq!((icon.width(), icon.height()), (32, 32));
            assert_eq!(icon.rgba().len(), 32 * 32 * 4);
            let mut text_pixels = 0;
            for (index, pixel) in icon.rgba().chunks_exact(4).enumerate() {
                let (x, y) = (index % 32, index / 32);
                if x == 0 || x == 31 || y == 0 || y == 31 {
                    assert_eq!(
                        pixel,
                        [0, 0, 0, 0],
                        "{remaining} has an opaque background at {x},{y}"
                    );
                }
                if pixel[3] > 128 {
                    text_pixels += 1;
                    assert!((1..31).contains(&x), "{remaining} clipped horizontally");
                    assert!((1..31).contains(&y), "{remaining} clipped vertically");
                }
            }
            assert!(text_pixels > 20, "{remaining} has no readable digits");
            let brightest = icon
                .rgba()
                .chunks_exact(4)
                .map(|pixel| pixel[0])
                .max()
                .unwrap();
            assert_eq!(
                brightest < 128,
                light,
                "digits must contrast with the taskbar"
            );
            assert!(
                rendered.insert(icon.rgba().to_vec()),
                "{remaining} repeats another icon"
            );
        }
    }
}
