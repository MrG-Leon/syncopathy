#ifndef RUNNER_MPV_CAPTURE_PLUGIN_H_
#define RUNNER_MPV_CAPTURE_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>
#include <flutter_texture_registrar.h>

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <d3d11.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <wrl/client.h>

// Captures mpv's own gpu-next window with Windows Graphics Capture and exposes
// it to Flutter as an external GPU texture. This keeps mpv's full D3D11
// pipeline (including d3d11vpp / RTX VSR and gpu-next user shaders) while the
// video is displayed inside the normal Flutter widget tree.
class MpvCapturePlugin {
 public:
  MpvCapturePlugin(flutter::FlutterEngine* engine, HWND app_window);
  ~MpvCapturePlugin();

  MpvCapturePlugin(const MpvCapturePlugin&) = delete;
  MpvCapturePlugin& operator=(const MpvCapturePlugin&) = delete;

 private:
  using EncodableMap = flutter::EncodableMap;
  using EncodableValue = flutter::EncodableValue;

  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result);

  bool IsSupported() const;

  bool Start(int64_t window_id, double x, double y, double width,
             double height, double device_pixel_ratio, std::string* error);
  bool UpdateBounds(double x, double y, double width, double height,
                    double device_pixel_ratio, std::string* error);
  void Stop(bool hide_window = true);

  bool EnsureDevice();
  bool StartWinrtCapture(HWND window, std::string* error);
  void StopWinrtCapture();
  bool CreateSharedTextures(int width, int height);
  bool CreateTexturePair(int width, int height,
                         Microsoft::WRL::ComPtr<ID3D11Texture2D>* textures,
                         HANDLE* handles);
  bool AdoptFrameSizeLocked(int width, int height);
  void ReleaseSharedTextures();
  void UpdateDescriptor(int index);
  void OnFrame(
      const winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool&
          sender);
  void ConfigureWindow(HWND window, int x, int y, int width, int height,
                       bool recreate_item);
  bool ClampToAppWindow(int* x, int* y, int* width, int* height);
  void DropDevice();

  // Keeps the mpv window glued to the app window while the user drags it.
  static LRESULT CALLBACK AppWindowProc(HWND window, UINT message,
                                        WPARAM wparam, LPARAM lparam,
                                        UINT_PTR subclass_id,
                                        DWORD_PTR ref_data);
  void FollowAppWindow();

  static const FlutterDesktopGpuSurfaceDescriptor* ObtainDescriptor(
      size_t width, size_t height, void* user_data);

  void RegisterTexture();
  void UnregisterTexture();

  HWND app_window_ = nullptr;
  HWND mpv_window_ = nullptr;
  FlutterDesktopTextureRegistrarRef texture_registrar_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;

  Microsoft::WRL::ComPtr<ID3D11Device> d3d_device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> d3d_context_;
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice winrt_device_{
      nullptr};

  winrt::Windows::Graphics::Capture::GraphicsCaptureItem capture_item_{
      nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool frame_pool_{
      nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureSession capture_session_{
      nullptr};

  // Two shared textures are alternated so Flutter can keep reading the last
  // presented frame while the next one is being copied.
  Microsoft::WRL::ComPtr<ID3D11Texture2D> textures_[2];
  HANDLE shared_handles_[2] = {nullptr, nullptr};
  int active_texture_ = 0;
  int texture_width_ = 0;
  int texture_height_ = 0;

  // Textures retired on a size change. Keeping them alive keeps their shared
  // handles valid for any frame Flutter may still be opening.
  std::vector<Microsoft::WRL::ComPtr<ID3D11Texture2D>> retired_textures_;

  // Textures built for a new size but not yet on screen. The current pair stays
  // visible until a frame of the new size has actually been copied into these,
  // so a resize never points Flutter at an unwritten (black) texture.
  Microsoft::WRL::ComPtr<ID3D11Texture2D> pending_textures_[2];
  HANDLE pending_handles_[2] = {nullptr, nullptr};
  int pending_width_ = 0;
  int pending_height_ = 0;
  bool pending_valid_ = false;

  std::mutex texture_mutex_;
  FlutterDesktopGpuSurfaceDescriptor descriptors_[2]{};
  std::atomic<int> descriptor_index_{0};
  std::atomic<bool> capture_running_{false};

  // Incremented for every frame marked available to Flutter. Read through the
  // `frameCount` method by the Dart watchdog that detects a stalled session.
  std::atomic<uint64_t> frame_counter_{0};

  // Diagnostics for the stalled-session report: how many callbacks WGC raised
  // and how many of those could not be copied. A session that raises callbacks
  // but copies nothing has a size problem; one that raises none is not
  // delivering at all.
  std::atomic<uint64_t> frames_arrived_{0};
  std::atomic<uint64_t> frames_dropped_{0};
  int last_frame_width_ = 0;
  int last_frame_height_ = 0;

  int64_t texture_id_ = 0;
  int capture_width_ = 0;
  int capture_height_ = 0;

  // Rectangle last written to the window. While the app window is dragged the
  // Dart side reports bounds on every mouse-move event, most of which repeat
  // the previous values once the client origin has been accounted for; reissuing
  // SetWindowPos for those makes the desktop recomposite for nothing.
  int applied_x_ = 0;
  int applied_y_ = 0;
  int applied_width_ = 0;
  int applied_height_ = 0;
  bool applied_valid_ = false;

  // Size last requested by Dart, as opposed to capture_width_/height_, which
  // hold what the window actually became. Comparing the request against the
  // request is what decides whether the frame pool needs recreating: mpv can
  // round the window size, and comparing against the realised size then made
  // every bounds update look like a resize.
  int requested_width_ = 0;
  int requested_height_ = 0;

  // Bounds last requested by Dart, relative to the app window's client origin
  // and in physical pixels. The app-window subclass uses them to reposition the
  // mpv window from inside the window's own message, which is what keeps the
  // two in lockstep during a drag instead of a channel round trip behind.
  int client_x_ = 0;
  int client_y_ = 0;
  int client_width_ = 0;
  int client_height_ = 0;
  bool client_valid_ = false;
  POINT last_app_origin_{0, 0};
  int last_app_client_width_ = 0;
  int last_app_client_height_ = 0;
  bool subclass_installed_ = false;

  // Time of the last frame copied to the shared texture, as a steady_clock
  // value in nanoseconds. WGC delivers a frame for every desktop composition,
  // which is far above the video's own rate on a high-refresh display; copying
  // all of them competes with DWM for the GPU.
  std::atomic<int64_t> last_copy_tick_{0};

  // Time of the last texture adoption, as a steady_clock value in nanoseconds.
  // A frame whose size matches neither published nor pending textures means
  // something resized the window behind our back; textures are rebuilt for
  // that size, throttled so an oscillating size cannot allocate every frame.
  std::atomic<int64_t> last_adopt_tick_{0};
};

#endif  // RUNNER_MPV_CAPTURE_PLUGIN_H_
