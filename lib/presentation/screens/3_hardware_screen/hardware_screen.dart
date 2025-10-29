import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers/device_provider.dart';

class HardwareScreen extends ConsumerWidget {
  const HardwareScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncDevice = ref.watch(currentDeviceProvider);
    return asyncDevice.when(
      data: (device) {
        if (device == null) {
          return const Center(child: Text('Aguardando conexão...'));
        }
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('Dispositivo Conectado: ${device.name}'),
              const SizedBox(height: 8),
              Text('Canais de Saída Encontrados: ${device.outputChannels}'),
              const SizedBox(height: 16),
              SizedBox(
                height: 300,
                child: SingleChildScrollView(
                  child: Column(
                    children: List.generate(
                      device.outputChannels,
                      (i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text('Canal de Saída ${i + 1}',
                            textAlign: TextAlign.center),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text('Canais de Entrada Encontrados: ${device.inputChannels}'),
              const SizedBox(height: 16),
              SizedBox(
                height: 300,
                child: SingleChildScrollView(
                  child: Column(
                    children: List.generate(
                      device.inputChannels,
                      (i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text('Canal de Entrada ${i + 1}',
                            textAlign: TextAlign.center),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, st) => Center(child: Text('Erro: $e')),
    );
  }
}
