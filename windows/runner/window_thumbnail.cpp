#include "window_thumbnail.h"

#include <objbase.h>

#include <windows.h>

#include <cstdint>
#include <cstring>
#include <vector>

namespace window_thumbnail {
namespace {

/// Maximum thumbnail width in pixels. The Recents panel displays thumbnails
/// at 260x200 and workspace previews at 200x150, so 320 px gives headroom
/// for high-DPI displays without wasting encode time on full-resolution output.
constexpr UINT kMaxThumbnailWidth = 320;

/// Minimal COM pointer wrapper: this target builds with `_HAS_EXCEPTIONS=0`,
/// so no RAII type from the STL that may throw can be used.
template <typename T>
class ComPtr {
 public:
  ComPtr() = default;
  ~ComPtr() { reset(); }
  ComPtr(const ComPtr&) = delete;
  ComPtr& operator=(const ComPtr&) = delete;

  T** put() {
    reset();
    return &ptr_;
  }

  T* get() const { return ptr_; }
  T* operator->() const { return ptr_; }

  void reset() {
    if (ptr_ != nullptr) {
      ptr_->Release();
      ptr_ = nullptr;
    }
  }

 private:
  T* ptr_ = nullptr;
};

/// Read all bytes from an IStream into a vector.
std::vector<uint8_t> ReadStreamBytes(IStream* stream) {
  if (stream == nullptr) return {};

  // Reset stream position to the beginning.
  LARGE_INTEGER zero = {};
  stream->Seek(zero, STREAM_SEEK_SET, nullptr);

  std::vector<uint8_t> result;
  BYTE buffer[8192];
  ULONG bytes_read = 0;
  HRESULT hr = S_OK;
  while (SUCCEEDED(hr = stream->Read(buffer, sizeof(buffer), &bytes_read)) &&
         bytes_read > 0) {
    result.insert(result.end(), buffer, buffer + bytes_read);
  }
  return result;
}

}  // namespace

std::vector<uint8_t> CaptureToPng(HWND hwnd) {
  if (hwnd == nullptr || !IsWindow(hwnd)) return {};

  RECT rect = {};
  if (!GetClientRect(hwnd, &rect)) return {};
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) return {};

  // Capture the window into a DIB section.
  const HDC screen_dc = GetDC(nullptr);
  if (screen_dc == nullptr) return {};
  const HDC memory_dc = CreateCompatibleDC(screen_dc);
  ReleaseDC(nullptr, screen_dc);
  if (memory_dc == nullptr) return {};

  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;  // top-down DIB
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  const HBITMAP bitmap = CreateDIBSection(memory_dc, &info, DIB_RGB_COLORS,
                                          &bits, nullptr, 0);
  if (bitmap == nullptr || bits == nullptr) {
    DeleteDC(memory_dc);
    return {};
  }

  const HGDIOBJ previous = SelectObject(memory_dc, bitmap);
  const BOOL captured = PrintWindow(hwnd, memory_dc, PW_RENDERFULLCONTENT);
  SelectObject(memory_dc, previous);
  DeleteDC(memory_dc);

  if (!captured) {
    DeleteObject(bitmap);
    return {};
  }

  // Harmless if the engine already initialised COM on this thread.
  const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  std::vector<uint8_t> result;
  UINT thumb_width = static_cast<UINT>(width);
  UINT thumb_height = static_cast<UINT>(height);

  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(factory.put()));

  if (SUCCEEDED(hr)) {
    // Create a WIC bitmap from the captured HBITMAP.
    ComPtr<IWICBitmap> source_bitmap;
    hr = factory->CreateBitmapFromHBITMAP(bitmap, nullptr,
                                          WICBitmapIgnoreAlpha,
                                          source_bitmap.put());

    // Downscale to thumbnail dimensions before encoding.
    if (SUCCEEDED(hr)) {
      thumb_width = static_cast<UINT>(width);
      thumb_height = static_cast<UINT>(height);
      if (thumb_width > kMaxThumbnailWidth) {
        thumb_width = kMaxThumbnailWidth;
        thumb_height = static_cast<UINT>(
            static_cast<double>(height) * kMaxThumbnailWidth / width);
      }

      ComPtr<IWICBitmapScaler> scaler;
      hr = factory->CreateBitmapScaler(scaler.put());
      if (SUCCEEDED(hr)) {
        hr = scaler->Initialize(source_bitmap.get(), thumb_width,
                                thumb_height, WICBitmapInterpolationModeLinear);
      }

      if (SUCCEEDED(hr)) {
        // Encode directly to an in-memory IStream -- no temp file I/O.
        ComPtr<IStream> stream;
        hr = CreateStreamOnHGlobal(nullptr, TRUE, stream.put());
        if (SUCCEEDED(hr)) {
          ComPtr<IWICBitmapEncoder> encoder;
          if (SUCCEEDED(hr)) {
            hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                        encoder.put());
          }
          if (SUCCEEDED(hr)) {
            hr = encoder->Initialize(stream.get(), WICBitmapEncoderNoCache);
          }

          ComPtr<IWICBitmapFrameEncode> frame;
          ComPtr<IPropertyBag2> properties;
          if (SUCCEEDED(hr)) {
            hr = encoder->CreateNewFrame(frame.put(), properties.put());
          }
          if (SUCCEEDED(hr)) hr = frame->Initialize(properties.get());
          if (SUCCEEDED(hr)) {
            hr = frame->SetSize(thumb_width, thumb_height);
          }

          WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
          if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);

          // Copy scaled pixels via a lock on the scaler's output bitmap.
          if (SUCCEEDED(hr)) {
            ComPtr<IWICBitmap> scaled_bitmap;
            hr = factory->CreateBitmapFromSource(
                scaler.get(), WICBitmapCacheOnDemand, scaled_bitmap.put());
            if (SUCCEEDED(hr) && scaled_bitmap.get() != nullptr) {
              WICRect lock_rect = {
                  0, 0, static_cast<INT>(thumb_width),
                  static_cast<INT>(thumb_height)};
              ComPtr<IWICBitmapLock> lock;
              hr = scaled_bitmap->Lock(&lock_rect, WICBitmapLockRead,
                                       lock.put());
              if (SUCCEEDED(hr) && lock.get() != nullptr) {
                UINT data_size = 0;
                UINT stride = 0;
                BYTE* data = nullptr;
                hr = lock->GetDataPointer(&data_size, &data);
                if (SUCCEEDED(hr)) {
                  hr = lock->GetStride(&stride);
                }
                if (SUCCEEDED(hr) && data != nullptr) {
                  hr = frame->WritePixels(thumb_height, stride, data_size,
                                         data);
                }
                // IWICBitmapLock is released by resetting the ComPtr.
                lock.reset();
              }
            }
          }

          if (SUCCEEDED(hr)) hr = frame->Commit();
          if (SUCCEEDED(hr)) hr = encoder->Commit();

          // Read the PNG bytes from the memory stream.
          if (SUCCEEDED(hr) && stream.get() != nullptr) {
            result = ReadStreamBytes(stream.get());
          }

          // Release encoder chain before stream is freed.
          frame.reset();
          properties.reset();
          encoder.reset();
        }
      }
    }
  }

  // Release COM objects.
  factory.reset();

  DeleteObject(bitmap);
  if (SUCCEEDED(com)) CoUninitialize();

  return result;
}

}  // namespace window_thumbnail