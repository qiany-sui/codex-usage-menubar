use anyhow::{Result, ensure};
use std::ptr::null_mut;
use tauri::image::Image;
use windows_sys::Win32::Foundation::RECT;
use windows_sys::Win32::Graphics::Gdi::{
    ANTIALIASED_QUALITY, BITMAPINFO, BITMAPINFOHEADER, CreateCompatibleDC, CreateDIBSection,
    CreateFontW, DEFAULT_CHARSET, DIB_RGB_COLORS, DT_CENTER, DT_NOCLIP, DT_SINGLELINE, DT_VCENTER,
    DeleteDC, DeleteObject, DrawTextW, FW_BOLD, GdiFlush, HBITMAP, HDC, HFONT, SelectObject,
    SetBkColor, SetBkMode, SetTextColor, TRANSPARENT,
};

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

pub fn quota_icon(remaining: &str) -> Result<Image<'static>> {
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
            if remaining.len() == 3 { -18 } else { -26 },
            0,
            0,
            0,
            FW_BOLD as i32,
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
        // 固定深底白字，在系统深浅色任务栏上都保持对比度；避免 ClearType 彩边。
        for pixel in std::slice::from_raw_parts_mut(pixels.cast::<u8>(), BYTES).chunks_exact_mut(4)
        {
            pixel.copy_from_slice(&[48, 36, 32, 0]);
        }
        SetBkColor(canvas.dc, 0x00302420);
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
        // GDI 输出 BGRA，且不写 alpha；Tauri 需要完整的 RGBA 像素。
        let mut rgba = std::slice::from_raw_parts(pixels.cast::<u8>(), BYTES).to_vec();
        for pixel in rgba.chunks_exact_mut(4) {
            pixel.swap(0, 2);
            pixel[3] = 255;
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
        for remaining in 0..=100 {
            let icon = quota_icon(&remaining.to_string()).unwrap();
            assert_eq!((icon.width(), icon.height()), (32, 32));
            assert_eq!(icon.rgba().len(), 32 * 32 * 4);
            let mut text_pixels = 0;
            for (index, pixel) in icon.rgba().chunks_exact(4).enumerate() {
                assert_eq!(pixel[3], 255);
                if pixel[0] > 128 {
                    text_pixels += 1;
                    let (x, y) = (index % 32, index / 32);
                    assert!((1..31).contains(&x), "{remaining} clipped horizontally");
                    assert!((1..31).contains(&y), "{remaining} clipped vertically");
                }
            }
            assert!(text_pixels > 20, "{remaining} has no readable digits");
            assert!(
                rendered.insert(icon.rgba().to_vec()),
                "{remaining} repeats another icon"
            );
        }
    }
}
