import 'package:flutter/material.dart';

import 'screens/crypto_work_page.dart';
import 'screens/profile_page.dart';

void main() {
  runApp(const FileEncryptorApp());
}

const Color kBg = Color(0xFF0E1116);
const Color kCard = Color(0xFF161B22);
const Color kBorder = Color(0xFF2A313C);
const Color kText = Color(0xFFE6EDF3);
const Color kMuted = Color(0xFF8B949E);
const Color kAccent = Color(0xFF6366F1);
const Color kAccent2 = Color(0xFF8B5CF6);
const Color kDanger = Color(0xFFF85149);
const Color kSuccess = Color(0xFF3FB950);

class FileEncryptorApp extends StatelessWidget {
  const FileEncryptorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '文件加密',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          secondary: kAccent2,
          surface: kCard,
        ),
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: IndexedStack(
        index: _index,
        children: const [
          CryptoWorkPage(mode: WorkMode.encrypt),
          CryptoWorkPage(mode: WorkMode.decrypt),
          ProfilePage(),
        ],
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: kCard,
          indicatorColor: kAccent.withValues(alpha: 0.22),
          labelTextStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 12, color: kText),
          ),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return IconThemeData(
              size: 24,
              color: selected ? const Color(0xFFA5B4FC) : kMuted,
            );
          }),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          height: 64,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.lock_outline),
              selectedIcon: Icon(Icons.lock),
              label: '加密',
            ),
            NavigationDestination(
              icon: Icon(Icons.lock_open_outlined),
              selectedIcon: Icon(Icons.lock_open),
              label: '解密',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: '个人中心',
            ),
          ],
        ),
      ),
    );
  }
}
