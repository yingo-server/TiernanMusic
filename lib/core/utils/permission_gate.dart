import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../storage/storage_permission.dart';
import 'toast.dart';

/// 权限门卫：UI 层入口。
///
/// **判定逻辑统一由 [StoragePermissionService] 提供**（唯一权威），
/// 本类只负责：发起申请、给出用户提示、永久拒绝时引导系统设置。
class PermissionGate {
  PermissionGate._();
  static final instance = PermissionGate._();

  StoragePermissionService get _service => StoragePermissionService.instance;

  /// 写公共存储前调用。返回 true 表示可以写。
  Future<bool> ensureStorageWrite() async {
    if (!Platform.isAndroid) return true;
    return _service.requestStoragePermission();
  }

  /// 检查当前是否已具备公共存储写入能力（**不申请、不弹窗**）。
  ///
  /// 用于「只读展示」场景（如诊断页的状态显示）——
  /// 不能因为用户只是看了一眼状态就弹出权限框。
  Future<bool> hasStorageWriteAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      final strategy = await _service.currentStrategy();
      return strategy != StorageStrategy.appFallback;
    } catch (e) {
      debugPrint('[PermissionGate] hasStorageWriteAccess failed: $e');
      return false;
    }
  }

  /// 需要发通知时调用（Android 13+ 才有意义）
  Future<bool> ensureNotification() async {
    if (!Platform.isAndroid) return true;
    return _service.requestNotificationPermission();
  }

  /// 读取媒体（Android 13+ 细分权限；本 App 只读自己写入的文件，通常不需要）
  ///
  /// 仅查询、**不弹窗**；未授权时返回 false，由调用方决定是否引导用户。
  Future<bool> hasMediaReadAccess() async {
    if (!Platform.isAndroid) return true;
    final level = await _service.apiLevel();
    if (level < 33) return true;
    try {
      final status = await Permission.audio.status;
      return status.isGranted || status.isLimited;
    } catch (e) {
      debugPrint('[PermissionGate] media read check failed: $e');
      return false;
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
      await openAppSettings();
      return false;
    }
    final result = await permission.request();
    if (!result.isGranted) {
      Toast.show(context, reason);
      return false;
    }
    return true;
  }

  /// 打开系统设置（供 UI 层「去授权」按钮使用）
  Future<void> openSettings() async {
    try {
      await openAppSettings();
    } catch (e) {
      debugPrint('[PermissionGate] openAppSettings failed: $e');
    }
  }
}
