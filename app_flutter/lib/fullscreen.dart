export 'fullscreen_io.dart' if (dart.library.js_interop) 'fullscreen_web.dart';

/// Toggles the whole app into/out of browser fullscreen. Returns true when
/// the app is now fullscreen. No-op on desktop/mobile (handled by the watch
/// screen with SystemChrome / a full screen route).