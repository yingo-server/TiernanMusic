import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/login_page.dart';
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
        builder: (_, state) =>
            PlaylistDetailPage(id: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/comments/:type/:id',
        builder: (_, state) => CommentsPage(
          resourceType: state.pathParameters['type']!,
          resourceId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/mv/:hash',
        builder: (_, state) => MvPlayerPage(
          hash: state.pathParameters['hash']!,
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
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '首页'),
              NavigationDestination(icon: Icon(Icons.search), label: '搜索'),
              NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: '音乐库'),
              NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '设置'),
            ],
          ),
        ],
      ),
      ),
    );
  }
}
