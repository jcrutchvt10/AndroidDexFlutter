#include "window_thumbnail.h"

#include <objbase.h>

#include <cstdio>

namespace window_thumbnail {
namespace {

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

/// Temp file the Dart side reads and then deletes.
std::string TempPngPath(HWND hwnd) {
  char temp_dir[MAX_PATH] = {};
  const DWORD length = GetTempPathA(MAX_PATH, temp_dir);
  if (length == 0 || length >= MAX_PATH) return std::string();

  char file_name[80] = {};
  const unsigned long long owner =
      static_cast<unsigned long long>(GetCurrentProcessId());
  const unsigned long long handle =
      static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(hwnd));
  _snprintf_s(file_name, sizeof(file_name), _TRUNCATE,
              "androiddex-thumb-%llu-%llu.png", owner, handle);

  std::string path(temp_dir);
  path += file_name;
  return path;
}

std::wstring Widen(const std::string& value) {
  if (value.empty()) return std::wstring();
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                                       static_cast<int>(value.size()), nullptr,
                                       0);
  if (size <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                      &wide[0], size);
  return wide;
}

}  // namespace

std::string CaptureToPng(HWND hwnd) {
  if (hwnd == nullptr || !IsWindow(hwnd)) return std::string();

  RECT rect = {};
  if (!GetClientRect(hwnd, &rect)) return std::string();
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) return std::string();

  // The Flutter side scales the preview down for display; capturing at the
  // native size keeps text legible and avoids a resample on the capture path.
  const HDC screen_dc = GetDC(nullptr);
  if (screen_dc == nullptr) return std::string();
  const HDC memory_dc = CreateCompatibleDC(screen_dc);
  ReleaseDC(nullptr, screen_dc);
  if (memory_dc == nullptr) return std::string();

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
    return std::string();
  }

  const HGDIOBJ previous = SelectObject(memory_dc, bitmap);
  const BOOL captured = PrintWindow(hwnd, memory_dc, PW_RENDERFULLCONTENT);
  SelectObject(memory_dc, previous);
  DeleteDC(memory_dc);

  if (!captured) {
    DeleteObject(bitmap);
    return std::string();
  }

  const std::string path = TempPngPath(hwnd);
  if (path.empty()) {
    DeleteObject(bitmap);
    return std::string();
  }

  // Harmless if the engine already initialised COM on this thread.
  const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(factory.put()));
  if (FAILED(hr)) {
    DeleteObject(bitmap);
    if (SUCCEEDED(com)) CoUninitialize();
    return std::string();
  }

  ComPtr<IWICStream> stream;
  hr = factory->CreateStream(stream.put());
  if (SUCCEEDED(hr)) {
    hr = stream->InitializeFromFilename(Widen(path).c_str(), GENERIC_WRITE);
  }

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
    hr = frame->SetSize(static_cast<UINT>(width),
                        static_cast<UINT>(height));
  }

  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);

  if (SUCCEEDED(hr)) {
    const UINT stride = static_cast<UINT>(width) * 4u;
    const UINT buffer_size = stride * static_cast<UINT>(height);
    hr = frame->WritePixels(static_cast<UINT>(height), stride, buffer_size,
                            static_cast<BYTE*>(bits));
  }

  if (SUCCEEDED(hr)) hr = frame->Commit();
  if (SUCCEEDED(hr)) hr = encoder->Commit();

  // Drop the encoder chain so the Dart side can open the file immediately.
  frame.reset();
  properties.reset();
  encoder.reset();
  stream.reset();
  factory.reset();

  DeleteObject(bitmap);
  if (SUCCEEDED(com)) CoUninitialize();

  if (FAILED(hr)) {
    DeleteFileA(path.c_str());
    return std::string();
  }
  return path;
}

}  // namespace window_thumbnail