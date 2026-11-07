import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/login_page.dart';
import '../../features/artist/presentation/artist_page.dart';
import '../../features/album/presentation/album_page.dart';
import '../../features/rank/presentation/rank_detail_page.dart';
import '../../features/auth/presentation/verification_listener.dart';
import '../../features/home/presentation/home_page.dart';
import '../../features/player/presentation/full_player_page.dart';
import '../../features/search/presentation/search_page.dart';
import '../../features/settings/presentation/settings_page.dart';
import '../../features/playlist/presentation/playlist_detail_page.dart';
import '../../features/comment/presentation/comments_page.dart';
import '../../features/mv/presentation/mv_player_page.dart';
import '../../features/library/presentation/library_page.dart';
import '../../features/player/presentation/mini_player.dart';
import '../../features/download/presentation/download_page.dart';
import '../../l10n/l10n.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => MainShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/home', builder: (_, __) => const HomePage()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/search', builder: (_, __) => const SearchPage()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/library', builder: (_, __) => const LibraryPage()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/settings', builder: (_, __) => const SettingsPage()),
          ]),
        ],
      ),
      GoRoute(path: '/login', builder: (_, __) => const LoginPage()),
      GoRoute(path: '/player', builder: (_, __) => const FullPlayerPage()),
      GoRoute(
        path: '/playlist/:id',
        builder: (_, state) => PlaylistDetailPage(
          id: state.pathParameters['id']!,
          // 用户（我的）歌单：数字 listid，走 /playlist/track/all/new
          userListId: state.uri.queryParameters['user'],
        ),
      ),
      GoRoute(
        path: '/comments/:type/:id',
        builder: (_, state) => CommentsPage(
          resourceType: state.pathParameters['type']!,
          resourceId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/downloads',
        builder: (_, __) => const DownloadPage(),
      ),
      GoRoute(
        path: '/artist/:id',
        builder: (_, state) =>
            ArtistPage(id: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/album/:id',
        builder: (_, state) => AlbumPage(id: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/rank/:rankId',
        builder: (context, state) {
          // V33-03（修复①，第 14 条）：B-39 深链 rankId 非法（空/非数字）时，
          // `?? 0` 会让 RankDetailPage 拿 rankId=0 去请求，上游返回空 → 用户
          // 看到空白榜且无提示。改为解析失败直接跳错误页，避免无意义的空请求。
          // V37-UI-10（P3）：builder 参数改名（_, state → context, state），
          // 此前错误分支用 context.l10n 但参数是 `_` → undefined_identifier。
          final rankId = int.tryParse(state.pathParameters['rankId'] ?? '');
          if (rankId == null || rankId <= 0) {
            // V37-UI-10（P3）：深链错误页原硬编码中文「排行榜参数无效」，
            // 且无脱出动作（本页无 AppBar 只能系统返回）。改走 l10n +
            // 「返回首页」出口（微文案维度 A / 易用性任务流 5）。
            return Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(context.l10n.rankParamsInvalid),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () => context.go('/home'),
                      icon: const Icon(Icons.home_outlined, size: 18),
                      label: Text(context.l10n.goHome),
                    ),
                  ],
                ),
              ),
            );
          }
          return RankDetailPage(
            rankId: rankId,
            name: state.uri.queryParameters['name'] ?? '',
          );
        },
      ),
      GoRoute(
        path: '/mv/:hash',
        builder: (_, state) => MvPlayerPage(
          hash: state.pathParameters['hash']!,
          videoId: state.uri.queryParameters['videoId'],
          title: state.uri.queryParameters['title'],
          artist: state.uri.queryParameters['artist'],
        ),
      ),
    ],
  );
});

class MainShell extends StatelessWidget {
  const MainShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    return VerificationListener(
      child: Scaffold(
        body: shell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(),
          NavigationBar(
            selectedIndex: shell.currentIndex,
            onDestinationSelected: (i) =>
                shell.goBranch(i, initialLocation: i == shell.currentIndex),
            destinations: [
              // F4-31（审查③-B，P2）：底部导航文案硬编码中文 → 走 l10n（原则 4/30：
              // 用户可见文案不得在路由层写死单一语言）。
              NavigationDestination(
                  icon: const Icon(Icons.home_outlined),
                  selectedIcon: const Icon(Icons.home),
                  label: context.l10n.home),
              NavigationDestination(
                  icon: const Icon(Icons.search), label: context.l10n.search),
              NavigationDestination(
                  icon: const Icon(Icons.library_music_outlined),
                  selectedIcon: const Icon(Icons.library_music),
                  label: context.l10n.library),
              NavigationDestination(
                  icon: const Icon(Icons.settings_outlined),
                  selectedIcon: const Icon(Icons.settings),
                  label: context.l10n.settings),
            ],
          ),
        ],
      ),
      ),
    );
  }
}
