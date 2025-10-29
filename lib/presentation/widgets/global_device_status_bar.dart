import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/device_provider.dart';

class GlobalDeviceStatusBar extends ConsumerWidget {
  const GlobalDeviceStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncDevice = ref.watch(currentDeviceProvider);
    return asyncDevice.when(
      data: (device) {
        final connected = device != null;
        return Container(
          height: 30,
          color: connected ? Colors.green : Colors.red,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(connected ? Icons.usb : Icons.usb_off, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(
                connected ? 'Conectado: ${device!.name}' : 'Desconectado',
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
        );
      },
      loading: () => Container(
        height: 30,
        color: Colors.orange,
        alignment: Alignment.center,
        child: const Text('Verificando dispositivo...', style: TextStyle(color: Colors.white)),
      ),
      error: (e, st) => Container(
        height: 30,
        color: Colors.grey,
        alignment: Alignment.center,
        child: Text('Erro: $e', style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}