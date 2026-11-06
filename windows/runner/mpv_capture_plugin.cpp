#include "mpv_capture_plugin.h"

#include <commctrl.h>
#include <d3d11.h>
#include <dwmapi.h>
#include <dxgi.h>
#include <flutter_plugin_registrar.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/base.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iterator>
#include <string>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kChannelName[] = "syncopathy/mpv_capture";

// Subclass id for the app window hook that keeps the mpv window glued to it.
constexpr UINT_PTR kAppWindowSubclassId = 1;

// Minimum interval between two copies into the shared texture. WGC hands over a
// frame on every desktop composition — 240 a second on a high-refresh display —
// and each one ends with MarkExternalTextureFrameAvailable, so Flutter
// re-composites that many times for a video that presents at 60. 12ms keeps the
// captured stream above 60fps on any refresh rate while cutting the redundant
// copies that make dragging the window stutter. A high-resolution clock is
// required here: GetTickCount64 advances in 10-16ms jumps and cannot time this.
constexpr int64_t kMinFrameCopyIntervalNs = 12LL * 1000 * 1000;

// Minimum interval between two texture rebuilds caused by an unexpected frame
// size. mpv can resize its own window when a file is opened; adopting the size
// once is enough, and the throttle keeps an oscillating size from allocating a
// new texture pair per frame.
constexpr int64_t kMinAdoptIntervalNs = 300LL * 1000 * 1000;

int64_t SteadyClockNs() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// mpv may round the window size it is given, and the Flutter side can jitter by
// a pixel while a layout settles. Anything within this tolerance counts as the
// same size: rebuilding the frame pool and the shared textures for one pixel is
// far more disruptive than letting the picture be one pixel off.
constexpr int kSizeTolerancePx = 1;

bool GetDouble(const EncodableMap& map, const char* key, double* out) {
  auto it = map.find(EncodableValue(key));
  if (it == map.end()) return false;
  if (auto value = std::get_if<double>(&it->second)) {
    *out = *value;
    return true;
  }
  if (auto value = std::get_if<int32_t>(&it->second)) {
    *out = static_cast<double>(*value);
    return true;
  }
  if (auto value = std::get_if<int64_t>(&it->second)) {
    *out = static_cast<double>(*value);
    return true;
  }
  return false;
}

bool GetInt64(const EncodableMap& map, const char* key, int64_t* out) {
  auto it = map.find(EncodableValue(key));
  if (it == map.end()) return false;
  if (auto value = std::get_if<int64_t>(&it->second)) {
    *out = *value;
    return true;
  }
  if (auto value = std::get_if<int32_t>(&it->second)) {
    *out = *value;
    return true;
  }
  return false;
}

}  // namespace

MpvCapturePlugin::MpvCapturePlugin(flutter::FlutterEngine* engine,
                                   HWND app_window)
    : app_window_(app_window) {
  // Subclass the app window so the mpv window can be moved from inside the
  // same message that moves the app window. Going through the Dart side instead
  // costs a platform-channel round trip, which is visible as the video lagging
  // behind the frame while the user drags the window.
  if (app_window_ != nullptr) {
    subclass_installed_ =
        ::SetWindowSubclass(app_window_, &MpvCapturePlugin::AppWindowProc,
                            kAppWindowSubclassId,
                            reinterpret_cast<DWORD_PTR>(this)) != FALSE;
  }
  if (engine == nullptr) return;

  FlutterDesktopPluginRegistrarRef registrar =
      engine->GetRegistrarForPlugin("syncopathy_mpv_capture");
  if (registrar != nullptr) {
    texture_registrar_ = FlutterDesktopRegistrarGetTextureRegistrar(registrar);
  }

  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });
}

MpvCapturePlugin::~MpvCapturePlugin() {
  if (subclass_installed_ && app_window_ != nullptr) {
    ::RemoveWindowSubclass(app_window_, &MpvCapturePlugin::AppWindowProc,
                           kAppWindowSubclassId);
    subclass_installed_ = false;
  }
  Stop();
}

bool MpvCapturePlugin::IsSupported() const {
  try {
    return winrt::Windows::Graphics::Capture::GraphicsCaptureSession::
        IsSupported();
  } catch (...) {
    return false;
  }
}

bool MpvCapturePlugin::EnsureDevice() {
  if (d3d_device_) return true;
  D3D_FEATURE_LEVEL levels[] = {
      D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0,
      D3D_FEATURE_LEVEL_9_3,
  };
  HRESULT hr = D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels,
      static_cast<UINT>(std::size(levels)), D3D11_SDK_VERSION,
      d3d_device_.GetAddressOf(), nullptr, d3d_context_.GetAddressOf());
  if (FAILED(hr) || !d3d_device_ || !d3d_context_) return false;

  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
  hr = d3d_device_.As(&dxgi_device);
  if (FAILED(hr) || !dxgi_device) return false;

  IInspectable* inspectable = nullptr;
  hr = CreateDirect3D11DeviceFromDXGIDevice(dxgi_device.Get(), &inspectable);
  if (FAILED(hr) || inspectable == nullptr) return false;

  winrt_device_ =
      winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice{
          inspectable, winrt::take_ownership_from_abi};
  return true;
}

void MpvCapturePlugin::ConfigureWindow(HWND window, int x, int y, int width,
                                       int height, bool recreate_item) {
  if (!window) return;

  if (recreate_item) {
    // Do not rewrite GWL_STYLE before WGC creates its item: Windows Graphics
    // Capture rejects popup/tool windows (CreateForWindow returns E_INVALIDARG).
    // It also rejects windows carrying WS_EX_NOACTIVATE, which media_kit's own
    // mpv window uses. Clear those extended styles only while (re)creating the
    // capture item; StartWinrtCapture reapplies them before StartCapture.
    LONG_PTR ex_style = GetWindowLongPtrW(window, GWL_EXSTYLE);
    ex_style &= ~(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
    SetWindowLongPtrW(window, GWL_EXSTYLE, ex_style);
    SetWindowPos(window, HWND_BOTTOM, x, y, width, height,
                 SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    ShowWindow(window, SW_SHOWNOACTIVATE);
    UpdateWindow(window);
  } else {
    // Position (and size) only: no SWP_FRAMECHANGED, no UpdateWindow, and no
    // z-order change. SWP_FRAMECHANGED forces a non-client recalculation and a
    // synchronous repaint on every call, which mpv answers by reconfiguring its
    // video output; doing that for each mouse-move event is what made dragging
    // the window stutter and drop capture frames. Reordering the window every
    // time has the same problem: DWM recomposites the desktop for a window that
    // did not move relative to the app window at all.
    if (applied_valid_ && applied_x_ == x && applied_y_ == y &&
        applied_width_ == width && applied_height_ == height) {
      return;
    }
    SetWindowPos(window, nullptr, x, y, width, height,
                 SWP_NOACTIVATE | SWP_NOZORDER | SWP_SHOWWINDOW);
  }

  applied_x_ = x;
  applied_y_ = y;
  applied_width_ = width;
  applied_height_ = height;
  applied_valid_ = true;
}

bool MpvCapturePlugin::ClampToAppWindow(int* x, int* y, int* width,
                                        int* height) {
  if (app_window_ == nullptr || !IsWindow(app_window_)) return false;
  RECT client{};
  if (!GetClientRect(app_window_, &client)) return false;
  POINT origin{0, 0};
  ClientToScreen(app_window_, &origin);

  int left = origin.x + client.left;
  int top = origin.y + client.top;
  int right = origin.x + client.right;
  int bottom = origin.y + client.bottom;
  if (right <= left || bottom <= top) return false;

  int nx = *x;
  int ny = *y;
  int nw = *width;
  int nh = *height;

  // The video rectangle lives inside the app window, so it can never extend
  // past its client area. When the app window shrinks — leaving fullscreen is
  // the common case — the mpv window keeps its previous size until the Dart
  // side reports the new rectangle, which takes a debounce plus a route
  // settle. For that moment the oversized window sits outside the app window
  // and its video is visible as a leftover strip along the right and bottom
  // edges of the screen.
  if (nx + nw > right) nw = right - nx;
  if (ny + nh > bottom) nh = bottom - ny;
  if (nx < left) {
    nw -= left - nx;
    nx = left;
  }
  if (ny < top) {
    nh -= top - ny;
    ny = top;
  }

  // Fully outside: there is nothing left to show.
  if (nw < 1 || nh < 1) return false;

  *x = nx;
  *y = ny;
  *width = nw;
  *height = nh;
  return true;
}

void MpvCapturePlugin::FollowAppWindow() {
  if (!capture_running_.load(std::memory_order_acquire)) return;
  if (app_window_ == nullptr || mpv_window_ == nullptr ||
      !IsWindow(mpv_window_)) {
    return;
  }
  if (!client_valid_) return;

  POINT origin{0, 0};
  ClientToScreen(app_window_, &origin);
  RECT client{};
  GetClientRect(app_window_, &client);
  int client_width = client.right - client.left;
  int client_height = client.bottom - client.top;

  if (origin.x == last_app_origin_.x && origin.y == last_app_origin_.y &&
      client_width == last_app_client_width_ &&
      client_height == last_app_client_height_) {
    return;
  }
  last_app_origin_ = origin;
  last_app_client_width_ = client_width;
  last_app_client_height_ = client_height;

  int x = origin.x + client_x_;
  int y = origin.y + client_y_;
  int width = client_width_;
  int height = client_height_;

  // Runs inside the app window's own WM_WINDOWPOSCHANGED, so both windows land
  // on the same compositor frame rather than a channel round trip later.
  if (!ClampToAppWindow(&x, &y, &width, &height)) {
    // The app window is smaller than the video rectangle or gone entirely;
    // keeping the mpv window visible would leave video outside it.
    ShowWindow(mpv_window_, SW_HIDE);
    return;
  }
  ShowWindow(mpv_window_, SW_SHOWNOACTIVATE);
  ConfigureWindow(mpv_window_, x, y, width, height, false);

  // The requested rectangle is intentionally left as-is: it is the target to
  // restore once the app window grows again, and the capture textures still
  // hold that size. Only the window that is on screen right now is clamped.
}

LRESULT CALLBACK MpvCapturePlugin::AppWindowProc(HWND window, UINT message,
                                                 WPARAM wparam, LPARAM lparam,
                                                 UINT_PTR subclass_id,
                                                 DWORD_PTR ref_data) {
  auto* self = reinterpret_cast<MpvCapturePlugin*>(ref_data);
  if (self != nullptr &&
      (message == WM_WINDOWPOSCHANGED || message == WM_MOVE)) {
    self->FollowAppWindow();
  }
  return ::DefSubclassProc(window, message, wparam, lparam);
}

bool MpvCapturePlugin::CreateTexturePair(
    int width, int height,
    Microsoft::WRL::ComPtr<ID3D11Texture2D>* textures, HANDLE* handles) {
  if (width <= 0 || height <= 0) return false;
  if (!EnsureDevice()) return false;

  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = static_cast<UINT>(width);
  desc.Height = static_cast<UINT>(height);
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  desc.CPUAccessFlags = 0;
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

  for (int i = 0; i < 2; ++i) {
    HRESULT hr = d3d_device_->CreateTexture2D(&desc, nullptr,
                                              textures[i].GetAddressOf());
    if (FAILED(hr) || !textures[i]) return false;
    Microsoft::WRL::ComPtr<IDXGIResource> resource;
    hr = textures[i].As(&resource);
    if (FAILED(hr) || !resource) return false;
    if (FAILED(resource->GetSharedHandle(&handles[i])) ||
        handles[i] == nullptr) {
      return false;
    }
  }
  return true;
}

bool MpvCapturePlugin::AdoptFrameSizeLocked(int width, int height) {
  int64_t now = SteadyClockNs();
  int64_t last = last_adopt_tick_.load(std::memory_order_relaxed);
  if (last != 0 && now - last < kMinAdoptIntervalNs) return false;
  last_adopt_tick_.store(now, std::memory_order_relaxed);

  Microsoft::WRL::ComPtr<ID3D11Texture2D> pair[2];
  HANDLE handles[2] = {nullptr, nullptr};
  if (!CreateTexturePair(width, height, pair, handles)) return false;

  for (int i = 0; i < 2; ++i) {
    if (textures_[i]) retired_textures_.push_back(textures_[i]);
    textures_[i] = std::move(pair[i]);
    shared_handles_[i] = handles[i];
    pending_textures_[i].Reset();
    pending_handles_[i] = nullptr;
  }
  while (retired_textures_.size() > 2) {
    retired_textures_.erase(retired_textures_.begin());
  }
  texture_width_ = width;
  texture_height_ = height;
  capture_width_ = width;
  capture_height_ = height;
  active_texture_ = 0;
  pending_valid_ = false;
  pending_width_ = 0;
  pending_height_ = 0;
  descriptor_index_.store(0, std::memory_order_release);
  for (int i = 0; i < 2; ++i) {
    FlutterDesktopGpuSurfaceDescriptor& descriptor = descriptors_[i];
    descriptor = FlutterDesktopGpuSurfaceDescriptor{};
    descriptor.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
    descriptor.handle = shared_handles_[i];
    descriptor.width = static_cast<size_t>(width);
    descriptor.height = static_cast<size_t>(height);
    descriptor.visible_width = static_cast<size_t>(width);
    descriptor.visible_height = static_cast<size_t>(height);
    descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
    descriptor.release_callback = nullptr;
    descriptor.release_context = nullptr;
  }
  return true;
}

bool MpvCapturePlugin::CreateSharedTextures(int width, int height) {
  Microsoft::WRL::ComPtr<ID3D11Texture2D> new_textures[2];
  HANDLE new_handles[2] = {nullptr, nullptr};

  bool created = CreateTexturePair(width, height, new_textures, new_handles);
  if (!created && !capture_running_.load(std::memory_order_acquire)) {
    // A device removed by a driver reset leaves every later allocation failing
    // the same way, so the Dart side would burn its whole retry budget and then
    // report that capture cannot start. Rebuild once — only while nothing is
    // capturing, because a live frame pool is bound to the device it was
    // created with.
    new_textures[0].Reset();
    new_textures[1].Reset();
    DropDevice();
    if (!EnsureDevice()) return false;
    created = CreateTexturePair(width, height, new_textures, new_handles);
  }
  if (!created) return false;

  std::lock_guard<std::mutex> lock(texture_mutex_);

  if (texture_width_ <= 0 || !textures_[0] || !textures_[1]) {
    // Nothing is on screen yet (first start, or the session was stopped).
    // Install immediately so the first frame has a target.
    for (int i = 0; i < 2; ++i) {
      textures_[i] = std::move(new_textures[i]);
      shared_handles_[i] = new_handles[i];
    }
    texture_width_ = width;
    texture_height_ = height;
    active_texture_ = 0;
    pending_valid_ = false;
    pending_width_ = 0;
    pending_height_ = 0;
    descriptor_index_.store(0, std::memory_order_release);
    for (int i = 0; i < 2; ++i) {
      FlutterDesktopGpuSurfaceDescriptor& descriptor = descriptors_[i];
      descriptor = FlutterDesktopGpuSurfaceDescriptor{};
      descriptor.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
      descriptor.handle = shared_handles_[i];
      descriptor.width = static_cast<size_t>(width);
      descriptor.height = static_cast<size_t>(height);
      descriptor.visible_width = static_cast<size_t>(width);
      descriptor.visible_height = static_cast<size_t>(height);
      descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
      descriptor.release_callback = nullptr;
      descriptor.release_context = nullptr;
    }
    return true;
  }

  // A resize. The old pair stays published until OnFrame has copied a frame of
  // the new size into the pending pair. Swapping the descriptor straight away
  // pointed Flutter at a texture nothing had written yet, which is the black
  // flash every fullscreen toggle used to produce.
  if (pending_valid_) {
    pending_textures_[0].Reset();
    pending_textures_[1].Reset();
  }
  for (int i = 0; i < 2; ++i) {
    pending_textures_[i] = std::move(new_textures[i]);
    pending_handles_[i] = new_handles[i];
  }
  pending_width_ = width;
  pending_height_ = height;
  pending_valid_ = true;
  return true;
}

void MpvCapturePlugin::DropDevice() {
  // Callers of the D3D resource must not race a release; the frame callback
  // copies into the shared textures under this lock.
  std::lock_guard<std::mutex> lock(texture_mutex_);
  d3d_context_.Reset();
  d3d_device_.Reset();
  winrt_device_ = nullptr;
}

void MpvCapturePlugin::ReleaseSharedTextures() {
  std::lock_guard<std::mutex> lock(texture_mutex_);
  for (int i = 0; i < 2; ++i) {
    textures_[i].Reset();
    shared_handles_[i] = nullptr;
    pending_textures_[i].Reset();
    pending_handles_[i] = nullptr;
  }
  retired_textures_.clear();
  texture_width_ = 0;
  texture_height_ = 0;
  pending_width_ = 0;
  pending_height_ = 0;
  pending_valid_ = false;
}

void MpvCapturePlugin::UpdateDescriptor(int index) {
  FlutterDesktopGpuSurfaceDescriptor& descriptor = descriptors_[index];
  descriptor.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
  descriptor.handle = shared_handles_[index];
  descriptor.width = static_cast<size_t>(texture_width_);
  descriptor.height = static_cast<size_t>(texture_height_);
  descriptor.visible_width = static_cast<size_t>(texture_width_);
  descriptor.visible_height = static_cast<size_t>(texture_height_);
  descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
  descriptor_index_.store(index, std::memory_order_release);
}

const FlutterDesktopGpuSurfaceDescriptor* MpvCapturePlugin::ObtainDescriptor(
    size_t width, size_t height, void* user_data) {
  auto* self = static_cast<MpvCapturePlugin*>(user_data);
  if (self == nullptr) return nullptr;
  std::lock_guard<std::mutex> lock(self->texture_mutex_);
  if (self->texture_width_ <= 0 || self->texture_height_ <= 0) {
    return nullptr;
  }
  int index = self->descriptor_index_.load(std::memory_order_acquire);
  return &self->descriptors_[index];
}

void MpvCapturePlugin::RegisterTexture() {
  if (texture_registrar_ == nullptr || texture_id_ != 0) return;

  FlutterDesktopTextureInfo info{};
  info.type = kFlutterDesktopGpuSurfaceTexture;
  info.gpu_surface_config.struct_size =
      sizeof(FlutterDesktopGpuSurfaceTextureConfig);
  info.gpu_surface_config.type =
      kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle;
  info.gpu_surface_config.callback = &MpvCapturePlugin::ObtainDescriptor;
  info.gpu_surface_config.user_data = this;
  texture_id_ = FlutterDesktopTextureRegistrarRegisterExternalTexture(
      texture_registrar_, &info);
}

void MpvCapturePlugin::UnregisterTexture() {
  if (texture_registrar_ == nullptr || texture_id_ == 0) return;
  FlutterDesktopTextureRegistrarUnregisterExternalTexture(
      texture_registrar_, texture_id_, nullptr, nullptr);
  texture_id_ = 0;
}

bool MpvCapturePlugin::StartWinrtCapture(HWND window, std::string* error) {
  if (!window || !IsWindow(window)) {
    if (error) *error = "Invalid mpv window handle";
    return false;
  }
  if (!IsSupported()) {
    if (error) *error = "Windows Graphics Capture is not supported";
    return false;
  }
  if (!EnsureDevice()) {
    if (error) *error = "Could not create the D3D11 capture device";
    return false;
  }
  // A device removed by a driver reset keeps being handed back by EnsureDevice,
  // and every allocation against it fails. Rebuild it before trying again.
  if (FAILED(d3d_device_->GetDeviceRemovedReason())) {
    DropDevice();
    if (!EnsureDevice()) {
      if (error) *error = "Could not recreate the D3D11 capture device";
      return false;
    }
  }

  StopWinrtCapture();

  try {
    auto interop = winrt::get_activation_factory<
        winrt::Windows::Graphics::Capture::GraphicsCaptureItem,
        IGraphicsCaptureItemInterop>();
    winrt::Windows::Graphics::Capture::GraphicsCaptureItem item{nullptr};
    HRESULT hr = interop->CreateForWindow(
        window,
        winrt::guid_of<
            winrt::Windows::Graphics::Capture::GraphicsCaptureItem>(),
        winrt::put_abi(item));
    if (FAILED(hr) || !item) {
      if (error) *error = "Could not capture the mpv window";
      return false;
    }

    auto size = item.Size();
    if (size.Width <= 0 || size.Height <= 0) {
      if (error) *error = "The mpv window has no capture area";
      return false;
    }

    if (!CreateSharedTextures(size.Width, size.Height)) {
      if (error) *error = "Could not create the capture textures";
      return false;
    }

    RegisterTexture();
    if (texture_id_ == 0) {
      if (error) *error = "Could not register the Flutter texture";
      return false;
    }

    frame_pool_ =
        winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool::
            CreateFreeThreaded(
                winrt_device_,
                winrt::Windows::Graphics::DirectX::DirectXPixelFormat::
                    B8G8R8A8UIntNormalized,
                2, size);
    if (!frame_pool_) {
      if (error) *error = "Could not create the capture frame pool";
      return false;
    }

    frame_pool_.FrameArrived(
        [this](
            winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool
                const& sender,
            winrt::Windows::Foundation::IInspectable const&) {
          OnFrame(sender);
        });

    capture_session_ = frame_pool_.CreateCaptureSession(item);
    if (!capture_session_) {
      if (error) *error = "Could not create the capture session";
      return false;
    }
    capture_session_.IsCursorCaptureEnabled(false);
    if (auto session3 =
            capture_session_.try_as<
                winrt::Windows::Graphics::Capture::IGraphicsCaptureSession3>()) {
      session3.IsBorderRequired(false);
    }

    capture_item_ = item;
    capture_width_ = size.Width;
    capture_height_ = size.Height;
    // Hide the mpv window from the taskbar and the Alt+Tab list. This cannot
    // happen before CreateForWindow (WGC rejects tool / no-activate windows)
    // and changing the styles once the session is already running makes WGC
    // stop delivering frames, so it has to happen here, after the item exists
    // but before StartCapture.
    SetWindowLongPtrW(mpv_window_, GWL_EXSTYLE,
                      GetWindowLongPtrW(mpv_window_, GWL_EXSTYLE) |
                          WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
    frames_arrived_.store(0, std::memory_order_relaxed);
    frames_dropped_.store(0, std::memory_order_relaxed);
    last_frame_width_ = 0;
    last_frame_height_ = 0;
    capture_running_.store(true, std::memory_order_release);
    capture_session_.StartCapture();
    return true;
  } catch (const winrt::hresult_error& ex) {
    if (error) {
      *error = winrt::to_string(ex.message());
    }
    capture_running_.store(false, std::memory_order_release);
    return false;
  } catch (...) {
    if (error) *error = "Unknown Windows Graphics Capture error";
    capture_running_.store(false, std::memory_order_release);
    return false;
  }
}

void MpvCapturePlugin::StopWinrtCapture() {
  capture_running_.store(false, std::memory_order_release);
  try {
    if (capture_session_) {
      capture_session_.Close();
      capture_session_ = nullptr;
    }
    if (frame_pool_) {
      frame_pool_.Close();
      frame_pool_ = nullptr;
    }
    capture_item_ = nullptr;
  } catch (...) {
  }
  capture_width_ = 0;
  capture_height_ = 0;
  last_copy_tick_ = 0;
}

void MpvCapturePlugin::OnFrame(
    const winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool&
        sender) {
  if (!capture_running_.load(std::memory_order_acquire)) return;
  frames_arrived_.fetch_add(1, std::memory_order_relaxed);

  try {
    auto frame = sender.TryGetNextFrame();
    if (!frame) {
      frames_dropped_.fetch_add(1, std::memory_order_relaxed);
      return;
    }
    // A Direct3D11CaptureFrame must be closed before the pool can hand out the
    // next one, so release it explicitly on every path out of this callback.
    struct FrameGuard {
      winrt::Windows::Graphics::Capture::Direct3D11CaptureFrame& frame;
      ~FrameGuard() {
        try {
          if (frame) frame.Close();
        } catch (...) {
        }
      }
    } frame_guard{frame};

    auto surface = frame.Surface();

    Microsoft::WRL::ComPtr<
        ::Windows::Graphics::DirectX::Direct3D11::
            IDirect3DDxgiInterfaceAccess>
        access;
    HRESULT hr = winrt::get_unknown(surface)->QueryInterface(
        __uuidof(::Windows::Graphics::DirectX::Direct3D11::
                     IDirect3DDxgiInterfaceAccess),
        reinterpret_cast<void**>(access.GetAddressOf()));
    if (FAILED(hr) || !access) return;

    Microsoft::WRL::ComPtr<ID3D11Texture2D> frame_texture;
    hr = access->GetInterface(
        __uuidof(ID3D11Texture2D),
        reinterpret_cast<void**>(frame_texture.GetAddressOf()));
    if (FAILED(hr) || !frame_texture) return;

    D3D11_TEXTURE2D_DESC desc{};
    frame_texture->GetDesc(&desc);
    if (desc.Width == 0 || desc.Height == 0) return;

    int64_t texture_id = 0;
    {
      std::lock_guard<std::mutex> lock(texture_mutex_);
      if (!capture_running_.load(std::memory_order_acquire)) return;
      if (!d3d_context_) return;

      const int frame_width = static_cast<int>(desc.Width);
      const int frame_height = static_cast<int>(desc.Height);
      last_frame_width_ = frame_width;
      last_frame_height_ = frame_height;
      const bool matches_pending =
          pending_valid_ && frame_width == pending_width_ &&
          frame_height == pending_height_;
      const bool matches_active = frame_width == texture_width_ &&
                                  frame_height == texture_height_;
      // Frames that still carry the previous size keep updating the visible
      // pair. A size that matches neither means something changed the window
      // without telling us — mpv enforces the video's aspect ratio on its own
      // window when a file is opened. Adopt that size instead of dropping
      // every frame, which otherwise froze the picture until the watchdog
      // restarted the session, giving one frame every few seconds.
      if (!matches_pending && !matches_active) {
        if (!AdoptFrameSizeLocked(frame_width, frame_height)) {
          frames_dropped_.fetch_add(1, std::memory_order_relaxed);
          return;
        }
      }

      // WGC raises FrameArrived for every desktop composition, so on a
      // high-refresh display this runs several times per video frame. Each copy
      // ends with MarkExternalTextureFrameAvailable, which makes Flutter
      // re-composite, and all of it competes with DWM for the same GPU. The
      // frame is still taken and closed above, so the pool keeps flowing; only
      // the redundant copy is skipped.
      int64_t now = SteadyClockNs();
      int64_t last_copy = last_copy_tick_.load(std::memory_order_relaxed);
      if (last_copy != 0 && now - last_copy < kMinFrameCopyIntervalNs) return;
      last_copy_tick_.store(now, std::memory_order_relaxed);

      if (matches_pending) {
        if (!pending_textures_[0] || !pending_textures_[1]) return;
        d3d_context_->CopyResource(pending_textures_[0].Get(),
                                   frame_texture.Get());
        for (int i = 0; i < 2; ++i) {
          if (textures_[i]) retired_textures_.push_back(textures_[i]);
          textures_[i] = std::move(pending_textures_[i]);
          shared_handles_[i] = pending_handles_[i];
        }
        while (retired_textures_.size() > 2) {
          retired_textures_.erase(retired_textures_.begin());
        }
        texture_width_ = pending_width_;
        texture_height_ = pending_height_;
        active_texture_ = 0;
        pending_valid_ = false;
        pending_width_ = 0;
        pending_height_ = 0;
        UpdateDescriptor(active_texture_);
        texture_id = texture_id_;
      } else {
        if (!textures_[0] || !textures_[1]) return;
        int back = 1 - active_texture_;
        d3d_context_->CopyResource(textures_[back].Get(),
                                   frame_texture.Get());
        active_texture_ = back;
        UpdateDescriptor(back);
        texture_id = texture_id_;
      }
    }

    if (texture_id != 0 && texture_registrar_ != nullptr) {
      FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
          texture_registrar_, texture_id);
      frame_counter_.fetch_add(1, std::memory_order_relaxed);
    }
  } catch (...) {
    // A dropped frame must not take down the capture thread.
  }
}

bool MpvCapturePlugin::Start(int64_t window_id, double x, double y,
                             double width, double height,
                             double device_pixel_ratio, std::string* error) {
  if (width <= 0 || height <= 0) {
    if (error) *error = "Invalid video bounds";
    return false;
  }
  if (app_window_ == nullptr) {
    if (error) *error = "No application window";
    return false;
  }

  HWND window = reinterpret_cast<HWND>(static_cast<intptr_t>(window_id));
  if (!IsWindow(window)) {
    if (error) *error = "Invalid mpv window";
    return false;
  }
  HWND root = GetAncestor(window, GA_ROOT);
  if (root != nullptr) window = root;

  if (mpv_window_ != nullptr && mpv_window_ != window) {
    Stop();
  }
  mpv_window_ = window;

  RECT client_rect;
  POINT origin{0, 0};
  GetClientRect(app_window_, &client_rect);
  ClientToScreen(app_window_, &origin);

  double scale = device_pixel_ratio > 0.0 ? device_pixel_ratio : 1.0;
  int relative_x = static_cast<int>(std::lround(x * scale));
  int relative_y = static_cast<int>(std::lround(y * scale));
  int physical_width =
      std::max(1, static_cast<int>(std::lround(width * scale)));
  int physical_height =
      std::max(1, static_cast<int>(std::lround(height * scale)));

  // Remember the rectangle relative to the client origin: the app-window
  // subclass re-applies it whenever the window moves, without a round trip.
  client_x_ = relative_x;
  client_y_ = relative_y;
  client_width_ = physical_width;
  client_height_ = physical_height;
  client_valid_ = true;
  last_app_origin_ = origin;
  last_app_client_width_ = client_rect.right - client_rect.left;
  last_app_client_height_ = client_rect.bottom - client_rect.top;
  requested_width_ = physical_width;
  requested_height_ = physical_height;

  ConfigureWindow(window, origin.x + relative_x, origin.y + relative_y,
                  physical_width, physical_height, true);

  if (!StartWinrtCapture(window, error)) {
    StopWinrtCapture();
    UnregisterTexture();
    ReleaseSharedTextures();
    ShowWindow(window, SW_HIDE);
    mpv_window_ = nullptr;
    return false;
  }
  // Whatever size the window actually took is the one later position-only
  // updates keep, so it stays in sync with the captured frames.
  client_width_ = capture_width_;
  client_height_ = capture_height_;
  return true;
}

bool MpvCapturePlugin::UpdateBounds(double x, double y, double width,
                                    double height,
                                    double device_pixel_ratio,
                                    std::string* error) {
  if (mpv_window_ == nullptr || !IsWindow(mpv_window_)) {
    if (error) *error = "Capture has not started";
    return false;
  }
  if (width <= 0 || height <= 0) {
    if (error) *error = "Invalid video bounds";
    return false;
  }

  RECT client_rect;
  POINT origin{0, 0};
  GetClientRect(app_window_, &client_rect);
  ClientToScreen(app_window_, &origin);
  (void)client_rect;

  double scale = device_pixel_ratio > 0.0 ? device_pixel_ratio : 1.0;
  int relative_x = static_cast<int>(std::lround(x * scale));
  int relative_y = static_cast<int>(std::lround(y * scale));
  int physical_width =
      std::max(1, static_cast<int>(std::lround(width * scale)));
  int physical_height =
      std::max(1, static_cast<int>(std::lround(height * scale)));

  // The rectangle is measured from the Flutter layout, so a measurement taken
  // while the app window was still larger arrives after it has shrunk (leaving
  // fullscreen). Applying it would push the mpv window outside the app window
  // until the next measurement — the leftover strip along the screen edges.
  // Ignore it; the follow path has already clamped what is on screen.
  {
    int target_x = origin.x + relative_x;
    int target_y = origin.y + relative_y;
    int target_width = physical_width;
    int target_height = physical_height;
    if (!ClampToAppWindow(&target_x, &target_y, &target_width, &target_height) ||
        std::abs(target_width - physical_width) > 2 ||
        std::abs(target_height - physical_height) > 2) {
      return true;
    }
  }

  bool running = capture_running_.load(std::memory_order_acquire);
  // A size change needs a fresh frame pool; a position-only change does not.
  // Either dimension changing is enough: a width-only change (for example a
  // pillarboxed video becoming wider) otherwise kept the old frame pool and
  // OnFrame dropped every new frame as size-mismatched, leaving the last frame
  // frozen on screen.
  //
  // The comparison is against the size last *requested*, not the size the
  // window actually took. mpv rounds its window to its own constraints, so
  // comparing against the realised size made every single bounds update look
  // like a resize and tore the capture session down on each mouse-move event.
  bool resized =
      running && (std::abs(physical_width - requested_width_) >
                      kSizeTolerancePx ||
                  std::abs(physical_height - requested_height_) >
                      kSizeTolerancePx);

  // Position-only updates keep the size the window already has. Re-applying the
  // exact request would undo mpv's own rounding, and the captured frames would
  // then never match the shared textures again.
  int apply_width = physical_width;
  int apply_height = physical_height;
  if (resized) {
    requested_width_ = physical_width;
    requested_height_ = physical_height;
  } else if (client_valid_) {
    apply_width = client_width_;
    apply_height = client_height_;
  }

  client_x_ = relative_x;
  client_y_ = relative_y;
  client_width_ = apply_width;
  client_height_ = apply_height;
  client_valid_ = true;
  last_app_origin_ = origin;

  // Clearing WS_EX_NOACTIVATE / WS_EX_TOOLWINDOW is only required while WGC
  // creates its capture item, so keep the window's existing styles for
  // position-only updates. The resize below keeps the existing session alive,
  // which is why it must not touch the styles either; the fallback restart does
  // that itself, immediately before creating the new item.
  ConfigureWindow(mpv_window_, origin.x + relative_x, origin.y + relative_y,
                  apply_width, apply_height, false);

  if (!running || !resized) {
    return true;
  }

  // Read back what the window actually became. The frame pool has to match the
  // size WGC will hand us, which is the window's client area, not the size we
  // asked for.
  RECT client{};
  GetClientRect(mpv_window_, &client);
  int actual_width = client.right - client.left;
  int actual_height = client.bottom - client.top;
  if (actual_width <= 0 || actual_height <= 0) {
    if (error) *error = "The mpv window has no capture area";
    return false;
  }

  // Resizing used to close the session and build a new capture item, which
  // stops frame delivery, allocates a new texture pair and can fail outright
  // while the window is still moving. Recreating the frame pool is the
  // documented way to follow a size change: the item, the session and the
  // Flutter texture registration all stay in place.
  if (CreateSharedTextures(actual_width, actual_height)) {
    try {
      frame_pool_.Recreate(
          winrt_device_,
          winrt::Windows::Graphics::DirectX::DirectXPixelFormat::
              B8G8R8A8UIntNormalized,
          2, winrt::Windows::Graphics::SizeInt32{actual_width,
                                                 actual_height});
      capture_width_ = actual_width;
      capture_height_ = actual_height;
      client_width_ = actual_width;
      client_height_ = actual_height;
      return true;
    } catch (...) {
      // Fall through to a full restart, which is known to work.
    }
  }

  ConfigureWindow(mpv_window_, origin.x + relative_x, origin.y + relative_y,
                  physical_width, physical_height, true);
  if (!StartWinrtCapture(mpv_window_, error)) {
    StopWinrtCapture();
    UnregisterTexture();
    ReleaseSharedTextures();
    ShowWindow(mpv_window_, SW_HIDE);
    mpv_window_ = nullptr;
    return false;
  }
  // The window may not have taken the exact size that was requested; from now
  // on, position updates keep whatever it did take.
  client_width_ = capture_width_;
  client_height_ = capture_height_;
  return true;
}

void MpvCapturePlugin::Stop(bool hide_window) {
  StopWinrtCapture();
  UnregisterTexture();
  ReleaseSharedTextures();
  if (hide_window && mpv_window_ && IsWindow(mpv_window_)) {
    ShowWindow(mpv_window_, SW_HIDE);
  }
  mpv_window_ = nullptr;
  client_valid_ = false;
  applied_valid_ = false;
  requested_width_ = 0;
  requested_height_ = 0;
}

void MpvCapturePlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "isSupported") {
    result->Success(EncodableValue(IsSupported()));
    return;
  }

  if (method == "stop") {
    bool hide_window = true;
    if (const EncodableMap* args =
            std::get_if<EncodableMap>(method_call.arguments())) {
      auto it = args->find(EncodableValue("hideWindow"));
      if (it != args->end()) {
        if (auto value = std::get_if<bool>(&it->second)) hide_window = *value;
      }
    }
    Stop(hide_window);
    result->Success(EncodableValue(true));
    return;
  }

  if (method == "diagnostics") {
    // Reported by the Dart watchdog when it sees the frame count stop
    // advancing: whether WGC is delivering at all is the first thing to know.
    EncodableMap map;
    map[EncodableValue("running")] =
        EncodableValue(capture_running_.load(std::memory_order_acquire));
    map[EncodableValue("visible")] = EncodableValue(
        mpv_window_ != nullptr && IsWindowVisible(mpv_window_));
    map[EncodableValue("iconic")] =
        EncodableValue(mpv_window_ != nullptr && IsIconic(mpv_window_));
    int cloaked = 0;
    if (mpv_window_ != nullptr && IsWindow(mpv_window_)) {
      DWORD value = 0;
      if (SUCCEEDED(DwmGetWindowAttribute(mpv_window_, DWMWA_CLOAKED, &value,
                                          sizeof(value)))) {
        cloaked = static_cast<int>(value);
      }
    }
    map[EncodableValue("cloaked")] = EncodableValue(cloaked);
    int window_width = 0;
    int window_height = 0;
    if (mpv_window_ != nullptr && IsWindow(mpv_window_)) {
      RECT rect{};
      GetClientRect(mpv_window_, &rect);
      window_width = rect.right - rect.left;
      window_height = rect.bottom - rect.top;
    }
    map[EncodableValue("winW")] = EncodableValue(window_width);
    map[EncodableValue("winH")] = EncodableValue(window_height);
    map[EncodableValue("wantW")] = EncodableValue(client_width_);
    map[EncodableValue("wantH")] = EncodableValue(client_height_);
    map[EncodableValue("applyW")] = EncodableValue(applied_width_);
    map[EncodableValue("applyH")] = EncodableValue(applied_height_);
    map[EncodableValue("session")] = EncodableValue(!!capture_session_);
    map[EncodableValue("pool")] = EncodableValue(frame_pool_ != nullptr);
    int item_width = 0;
    int item_height = 0;
    if (capture_item_) {
      try {
        auto size = capture_item_.Size();
        item_width = size.Width;
        item_height = size.Height;
      } catch (...) {
      }
    }
    map[EncodableValue("itemW")] = EncodableValue(item_width);
    map[EncodableValue("itemH")] = EncodableValue(item_height);
    map[EncodableValue("texW")] = EncodableValue(texture_width_);
    map[EncodableValue("texH")] = EncodableValue(texture_height_);
    map[EncodableValue("pending")] = EncodableValue(pending_valid_);
    map[EncodableValue("pendingW")] = EncodableValue(pending_width_);
    map[EncodableValue("pendingH")] = EncodableValue(pending_height_);
    map[EncodableValue("lastFrameW")] = EncodableValue(last_frame_width_);
    map[EncodableValue("lastFrameH")] = EncodableValue(last_frame_height_);
    map[EncodableValue("arrived")] = EncodableValue(static_cast<int64_t>(
        frames_arrived_.load(std::memory_order_relaxed)));
    map[EncodableValue("copied")] = EncodableValue(static_cast<int64_t>(
        frame_counter_.load(std::memory_order_relaxed)));
    map[EncodableValue("dropped")] = EncodableValue(static_cast<int64_t>(
        frames_dropped_.load(std::memory_order_relaxed)));
    result->Success(EncodableValue(map));
    return;
  }

  if (method == "frameCount") {
    // Monotonic count of frames handed to Flutter. The Dart side watches it
    // while a video is playing and restarts the capture session if it stops
    // advancing, which recovers a stalled WGC session without a resize.
    result->Success(EncodableValue(
        static_cast<int64_t>(frame_counter_.load(std::memory_order_relaxed))));
    return;
  }

  if (method == "hide") {
    int64_t window_id = 0;
    const EncodableMap* hide_arguments =
        std::get_if<EncodableMap>(method_call.arguments());
    if (hide_arguments != nullptr &&
        GetInt64(*hide_arguments, "windowId", &window_id)) {
      HWND window = reinterpret_cast<HWND>(static_cast<intptr_t>(window_id));
      HWND root = GetAncestor(window, GA_ROOT);
      if (IsWindow(root != nullptr ? root : window)) {
        ShowWindow(root != nullptr ? root : window, SW_HIDE);
      }
    }
    result->Success(EncodableValue(true));
    return;
  }

  const EncodableMap* arguments =
      std::get_if<EncodableMap>(method_call.arguments());
  if (arguments == nullptr) {
    result->Error("bad_arguments", "Expected a map of arguments");
    return;
  }

  double x = 0, y = 0, width = 0, height = 0, dpr = 1;
  if (!GetDouble(*arguments, "x", &x) ||
      !GetDouble(*arguments, "y", &y) ||
      !GetDouble(*arguments, "width", &width) ||
      !GetDouble(*arguments, "height", &height) ||
      !GetDouble(*arguments, "devicePixelRatio", &dpr)) {
    result->Error("bad_arguments", "Missing video bounds");
    return;
  }

  if (method == "start") {
    int64_t window_id = 0;
    if (!GetInt64(*arguments, "windowId", &window_id)) {
      result->Error("bad_arguments", "Missing windowId");
      return;
    }
    std::string error;
    if (!Start(window_id, x, y, width, height, dpr, &error) ||
        texture_id_ == 0) {
      result->Error("capture_failed",
                    error.empty() ? "Could not start capture" : error);
      return;
    }
    result->Success(EncodableValue(texture_id_));
    return;
  }

  if (method == "updateBounds") {
    std::string error;
    if (!UpdateBounds(x, y, width, height, dpr, &error)) {
      result->Error("capture_failed",
                    error.empty() ? "Could not update capture bounds" : error);
      return;
    }
    result->Success(EncodableValue(true));
    return;
  }

  result->NotImplemented();
}
