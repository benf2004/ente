import 'dart:io';

import 'package:dio/dio.dart';
import 'package:ente_configuration/base_configuration.dart';
import 'package:ente_events/event_bus.dart';
import 'package:ente_events/models/endpoint_updated_event.dart';
import 'package:flutter/foundation.dart';
import 'package:native_dio_adapter/native_dio_adapter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:ua_client_hints/ua_client_hints.dart';
import 'package:uuid/uuid.dart';

int kConnectTimeout = 15000;

class Network {
  late Dio _dio;
  late Dio _enteDio;
  bool _initialized = false;
  BaseConfiguration? _configuration;
  String? _userAgent;
  String? _version;
  String? _packageName;

  // Fixed for the lifetime of the process, and each lookup is a platform
  // channel round trip, so they are resolved once rather than on every
  // account switch.
  Future<void> _resolveClientIdentity() async {
    if (_version != null) {
      return;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      _userAgent = await userAgent();
    }
    final packageInfo = await PackageInfo.fromPlatform();
    String packageName = packageInfo.packageName;

    // Fix package name for auth app on Windows/Linux only
    // On Linux, packageInfo returns "ente_auth" from pubspec.yaml (via version.json)
    // On Windows, packageInfo returns "Ente Auth" from Runner.rc InternalName field
    // We need to normalize both to "io.ente.auth" to match Android/iOS/macOS
    if (Platform.isWindows || Platform.isLinux) {
      if (packageName == 'ente_auth' || packageName == 'Ente Auth') {
        packageName = 'io.ente.auth';
      }
    }
    _packageName = packageName;
    _version = packageInfo.version;
  }

  // Safe to call again when the active account changes. The Dio instances are
  // created once and mutated in place, since many services capture them in
  // final fields at construction.
  Future<void> init(BaseConfiguration configuration) async {
    final bool isMobile = Platform.isAndroid || Platform.isIOS;
    await _resolveClientIdentity();
    final String? ua = _userAgent;
    final String version = _version!;
    final String packageName = _packageName!;

    // Validate package name for production endpoint
    // This ensures we catch any edge cases where the package name is still incorrect
    if (configuration.isEnteProduction()) {
      if (!packageName.startsWith('io.ente.')) {
        throw Exception(
          'Invalid client package name "$packageName" for production endpoint. '
          'Expected package name to start with "io.ente." but got "$packageName". '
          'This indicates the package name normalization failed. '
          'Please check the platform-specific configuration.',
        );
      }
    }

    final endpoint = configuration.getHttpEndpoint();
    _configuration = configuration;

    if (!_initialized) {
      _initialized = true;
      _dio = Dio(
        BaseOptions(
          connectTimeout: Duration(milliseconds: kConnectTimeout),
          headers: {
            HttpHeaders.userAgentHeader: isMobile
                ? ua!
                : Platform.operatingSystem,
            'X-Client-Version': version,
            'X-Client-Package': packageName,
          },
        ),
      );

      _enteDio = Dio(
        BaseOptions(
          baseUrl: endpoint,
          connectTimeout: Duration(milliseconds: kConnectTimeout),
          headers: {
            if (isMobile)
              HttpHeaders.userAgentHeader: ua!
            else
              HttpHeaders.userAgentHeader: Platform.operatingSystem,
            'X-Client-Version': version,
            'X-Client-Package': packageName,
          },
        ),
      );

      _dio.httpClientAdapter = NativeAdapter();
      _enteDio.httpClientAdapter = NativeAdapter();

      // Registered alongside the Dio instances it mutates, so switching
      // accounts cannot stack up duplicate listeners.
      Bus.instance.on<EndpointUpdatedEvent>().listen((event) {
        final config = _configuration;
        if (config == null) return;
        _enteDio.options.baseUrl = config.getHttpEndpoint();
        _setupInterceptors(config);
      });
    } else {
      _enteDio.options.baseUrl = endpoint;
    }

    _setupInterceptors(configuration);
  }

  Network._privateConstructor();

  static Network instance = Network._privateConstructor();

  Dio getDio() => _dio;
  Dio get enteDio => _enteDio;

  void _setupInterceptors(BaseConfiguration configuration) {
    _dio.interceptors.clear();
    _dio.interceptors.add(RequestIdInterceptor());

    _enteDio.interceptors.clear();
    _enteDio.interceptors.add(EnteRequestInterceptor(configuration));
  }
}

class RequestIdInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers.putIfAbsent(
      "x-request-id",
      () => const Uuid().v4().toString(),
    );
    return super.onRequest(options, handler);
  }
}

class EnteRequestInterceptor extends Interceptor {
  final BaseConfiguration configuration;

  EnteRequestInterceptor(this.configuration);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (kDebugMode) {
      assert(
        options.baseUrl == configuration.getHttpEndpoint(),
        "interceptor should only be used for API endpoint",
      );
    }
    options.headers.putIfAbsent(
      "x-request-id",
      () => const Uuid().v4().toString(),
    );
    final String? tokenValue = configuration.getToken();
    if (tokenValue != null) {
      options.headers.putIfAbsent("X-Auth-Token", () => tokenValue);
    }
    return super.onRequest(options, handler);
  }
}
