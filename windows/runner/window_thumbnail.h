#include <windows.h>
#include <wincodec.h>

#include <string>

namespace window_thumbnail {

/// Captures `hwnd` into a PNG in the user temp directory.
///
/// Returns the absolute path of the written file, or an empty string when the
/// surface cannot be captured (a GPU-composited window may refuse
/// `PrintWindow`). Never throws: `/EHsc` with `_HAS_EXCEPTIONS=0` is set for
/// this target, so every COM call is checked by return code.
std::string CaptureToPng(HWND hwnd);

}  // namespace window_thumbnail