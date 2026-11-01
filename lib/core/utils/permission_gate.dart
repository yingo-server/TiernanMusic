import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'toast.dart';

/// 权限门卫：需要写公共存储 / 发通知前自动申请。
///
/// Android 版本差异：
/// - API ≤ 28：写公共目录必须 `WRITE_EXTERNAL_STORAGE`（运行时申请）
/// - API 29+：MediaStore 写入不需要权限；但 Android 13+ 发通知需要 `POST_NOTIFICATIONS`
/// - 用户拒绝后再次触发时，引导到系统设置
class PermissionGate {
  PermissionGate._();
  static final instance = PermissionGate._();

  /// 已请求过的权限不再重复弹窗
  final Set<Permission> _requested = <Permission>{};

  /// 写公共存储前调用。返回 true 表示可以写。
  Future<bool> ensureStorageWrite() async {
    if (!Platform.isAndroid) return true;

    final apiLevel = _apiLevel;
    if (apiLevel >= 29) {
      // Android 10+：MediaStore 写入无需存储权限
      return true;
    }

    final status = await Permission.storage.status;
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      await _guideToSettings();
      return false;
    }

    final result = await Permission.storage.request();
    if (result.isGranted) return true;
    if (result.isPermanentlyDenied) await _guideToSettings();
    return false;
  }

  /// 需要发通知时调用（Android 13+ 才有意义）
  Future<bool> ensureNotification() async {
    if (!Platform.isAndroid) return true;

    final apiLevel = _apiLevel;
    if (apiLevel < 33) return true;

    final status = await Permission.notification.status;
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      await _guideToSettings();
      return false;
    }
    final result = await Permission.notification.request();
    return result.isGranted;
  }

  /// 读取媒体（Android 13+ 需要细分权限；本 App 只读自己写入的文件，通常不需要）
  Future<bool> ensureMediaRead() async {
    if (!Platform.isAndroid) return true;
    final apiLevel = _apiLevel;
    if (apiLevel < 33) {
      final status = await Permission.storage.status;
      if (status.isGranted) return true;
      final result = await Permission.storage.request();
      return result.isGranted;
    }
    return true;
  }

  /// Android API 级别（Platform.operatingSystemVersion 的 Android 分支返回 "Android 13"）
  int get _apiLevel {
    if (!Platform.isAndroid) return 99;
    final match = RegExp(r'Android\s+(\d+)').firstMatch(Platform.operatingSystemVersion);
    return int.tryParse(match?.group(1) ?? '') ?? 29;
  }

  Future<void> _guideToSettings() async {
    try {
      await openAppSettings();
    } catch (e) {
      debugPrint('[PermissionGate] openAppSettings failed: $e');
    }
  }

  /// 带上下文提示地申请（UI 层用）
  Future<bool> requestWithPrompt(
    BuildContext context, {
    required Permission permission,
    required String reason,
  }) async {
    if (!Platform.isAndroid) return true;
    final status = await permission.status;
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      await _guideToSettings();
      return false;
    }
    final result = await permission.request();
    if (!result.isGranted) {
      Toast.show(context, reason);
      return false;
    }
    return true;
  }
}
