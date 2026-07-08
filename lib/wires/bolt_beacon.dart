// ============================================================
// BOLT BEACON — FCM + local notification bridge
// ============================================================
// Cold-start push taps (app killed) are returned by [arm] AND
// mirrored to secure storage as a safety net. The router picks
// the returned URL up on the first frame and skips the loading
// screen entirely — this is what makes a push tap feel like it
// "opens the target" instead of "reboots the app" on OEMs that
// aggressively kill the backgrounded process.
//
// Warm taps (app in background or foreground) fire [onDeepLink]
// directly. [RootShell] installs a global default handler so
// taps land on the WebView even when the user is currently on
// the menu or in the game.
//
// The Android notification channel id must EXACTLY match the value
// of `com.google.firebase.messaging.default_notification_channel_id`
// in AndroidManifest.xml. The small icon references a dedicated
// flame drawable that is intentionally different from the launcher.
// ============================================================

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'peak_safe.dart';
import 'ua_forge.dart';

// [FINGERPRINT] Channel id — unique to this project. Must match
// AndroidManifest.xml → default_notification_channel_id.
const String kBeaconChannelId = 'thunder_beacons';
const String kBeaconChannelName = 'Storm Alerts';
const String _flameIcon = '@drawable/ic_notification';

@pragma('vm:entry-point')
Future<void> _backgroundIsolate(RemoteMessage message) async {
  // Nothing to do — the OS renders the notification; taps are
  // processed on resume via `onMessageOpenedApp` / `getInitialMessage`.
}

class BoltBeacon {
  BoltBeacon(this._safe);

  final PeakSafe _safe;
  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  FirebaseMessaging? _fm;
  String? _token;
  bool _armed = false;

  /// Warm (background/foreground) push URL delivered live to the WebView.
  void Function(String link)? onDeepLink;

  /// Fired when FCM rotates the token — the router re-POSTs the gate body.
  void Function(String token)? onTokenRotated;

  String? get token => _token;

  /// Boots the FCM subsystem AND returns the URL from a cold-tap push
  /// (i.e. a notification that woke the app from a killed state).
  /// Returns `null` when there was no cold-tap message. Warm taps fire
  /// [onDeepLink] instead — do not poll this method for them.
  ///
  /// The router uses the returned URL to skip the loading screen and
  /// mount the WebView on the first frame: on OEMs that aggressively
  /// kill backgrounded processes, this is the only way to make a push
  /// tap feel like "opens the target" instead of "reboots the app".
  Future<String?> arm() async {
    if (_armed) return null;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      _fm = FirebaseMessaging.instance;
      FirebaseMessaging.onBackgroundMessage(_backgroundIsolate);

      await _wireLocal();

      _token = await _fm!.getToken();
      _fm!.onTokenRefresh.listen((String t) {
        _token = t;
        onTokenRotated?.call(t);
      });

      FirebaseMessaging.onMessage.listen(_onForeground);
      FirebaseMessaging.onMessageOpenedApp.listen(_onWarmTap);

      _armed = true;

      final RemoteMessage? cold = await _fm!.getInitialMessage();
      if (cold != null) {
        final String? link = cold.data['url'] as String?;
        if (link != null && link.isNotEmpty) {
          // Stash as a safety net in case the caller ignores our
          // return value; the router prefers the returned URL.
          await _safe.stashPushUrl(link);
          return link;
        }
      }
    } catch (_) {
      // Firebase not configured yet — beacon stays dormant.
    }
    return null;
  }

  Future<void> _wireLocal() async {
    const AndroidInitializationSettings android =
        AndroidInitializationSettings(_flameIcon);
    const DarwinInitializationSettings darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _local.initialize(
      settings: const InitializationSettings(android: android, iOS: darwin),
      onDidReceiveNotificationResponse: (NotificationResponse r) {
        final String? payload = r.payload;
        if (payload == null || payload.isEmpty) return;
        try {
          final Map<String, dynamic> map =
              jsonDecode(payload) as Map<String, dynamic>;
          final String? link = map['url'] as String?;
          if (link != null && link.isNotEmpty) onDeepLink?.call(link);
        } catch (_) {}
      },
    );

    if (Platform.isAndroid) {
      final AndroidFlutterLocalNotificationsPlugin? plugin = _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await plugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          kBeaconChannelId,
          kBeaconChannelName,
          description: 'Updates from ThunderPeak',
          importance: Importance.high,
        ),
      );
    }
  }

  /// Fires the Android POST_NOTIFICATIONS system dialog. On denial
  /// we set the hard-denied flag so the invite screen never loops.
  Future<bool> requestPermission() async {
    if (_fm == null) return false;
    final NotificationSettings settings = await _fm!.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    final AuthorizationStatus status = settings.authorizationStatus;
    final bool granted = status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;
    await _safe.setPushGranted(granted);
    if (status == AuthorizationStatus.denied) {
      await _safe.markPushHardDenied();
    }
    return granted;
  }

  void _onForeground(RemoteMessage message) async {
    final RemoteNotification? n = message.notification;
    if (n == null || !Platform.isAndroid) return;

    AndroidNotificationDetails? details;
    final String? imageUrl = n.android?.imageUrl;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      final Uint8List? bytes = await _fetchImage(imageUrl);
      if (bytes != null) {
        details = AndroidNotificationDetails(
          kBeaconChannelId,
          kBeaconChannelName,
          importance: Importance.high,
          priority: Priority.high,
          icon: _flameIcon,
          styleInformation: BigPictureStyleInformation(
            ByteArrayAndroidBitmap(bytes),
            largeIcon:
                const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
          ),
        );
      }
    }

    details ??= const AndroidNotificationDetails(
      kBeaconChannelId,
      kBeaconChannelName,
      importance: Importance.high,
      priority: Priority.high,
      icon: _flameIcon,
    );

    await _local.show(
      id: n.hashCode,
      title: n.title,
      body: n.body,
      notificationDetails: NotificationDetails(android: details),
      payload: message.data.isNotEmpty ? jsonEncode(message.data) : null,
    );
  }

  void _onWarmTap(RemoteMessage message) {
    final String? link = message.data['url'] as String?;
    if (link != null && link.isNotEmpty) {
      onDeepLink?.call(link);
    }
  }

  Future<Uint8List?> _fetchImage(String url) async {
    try {
      final dynamic res = await peakHttp
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return res.bodyBytes as Uint8List;
    } catch (_) {}
    return null;
  }
}
