#ifndef WINDOW_THUMBNAIL_H_
#define WINDOW_THUMBNAIL_H_

#include <windows.h>
#include <wincodec.h>

#include <stdint.h>
#include <vector>

namespace window_thumbnail {

/// Captures `hwnd` as a downscaled PNG in memory.
///
/// Returns the raw PNG bytes (empty vector when the surface cannot be
/// captured — a GPU-composited window may refuse `PrintWindow`).
/// The bitmap is downscaled to a maximum width of 320 px before encoding,
/// which is the largest size displayed in the Recents panel or workspace
/// preview. This avoids encoding a full 1920×1080 PNG for a 260×200 card.
///
/// Never throws: `/EHsc` with `_HAS_EXCEPTIONS=0` is set for this target,
/// so every COM call is checked by return code.
std::vector<uint8_t> CaptureToPng(HWND hwnd);

}  // namespace window_thumbnail

#endif  // WINDOW_THUMBNAIL_H_
