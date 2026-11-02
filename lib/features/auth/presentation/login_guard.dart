import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/l10n.dart';
import '../data/auth_providers.dart';

/// 需要登录的操作守卫。
///
/// 匿名态下「收藏歌单 / 发评论 / 我的歌单」这类写操作会被服务端直接拒绝，
/// 旧实现让请求发出去再弹原始错误（用户观感：匿名处处受挫）。
/// 这里在**发起请求前**拦截并给出去登录的明确入口。
///
/// 返回值：true = 已登录，可以继续；false = 未登录，已提示（不要继续）。
bool ensureLoggedIn(BuildContext context, WidgetRef ref, {String? action}) {
  final user = ref.read(authStateProvider).valueOrNull;
  if (user != null) return true;
  final l10n = context.l10n;
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.account_circle_outlined),
      title: Text(l10n.loginRequiredTitle),
      content: Text(action == null
          ? l10n.loginRequiredHint
          : l10n.loginRequiredAction(action)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            context.push('/login');
          },
          child: Text(l10n.goLogin),
        ),
      ],
    ),
  );
  return false;
}
