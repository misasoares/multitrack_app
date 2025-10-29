import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '1_stage_screen/stage_screen.dart';
import '2_library_screen/library_screen.dart';
import '3_hardware_screen/hardware_screen.dart';
import '../widgets/global_device_status_bar.dart';

class ShellScreen extends ConsumerStatefulWidget {
  const ShellScreen({super.key});

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends ConsumerState<ShellScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final screens = const [
      StageScreen(),
      LibraryScreen(),
      HardwareScreen(),
    ];

    return Scaffold(
      body: Column(
        children: [
          const GlobalDeviceStatusBar(),
          Expanded(child: screens[_currentIndex]),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.mic_external_on),
            label: 'Palco',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.library_music),
            label: 'Biblioteca',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_input_component),
            label: 'Hardware',
          ),
        ],
      ),
    );
  }
}