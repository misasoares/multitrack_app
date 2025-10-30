import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/audio_providers.dart';
import '../../application/providers/device_provider.dart';
import '../../application/providers/song_providers.dart';
import '../../application/services/i_audio_device_service.dart';
import '../../domain/models/track_model.dart';
import 'track_level_meter.dart';

class TrackControlTile extends ConsumerStatefulWidget {
  final Track track;
  final int trackIndex;
  final int songId;
  const TrackControlTile(
      {super.key,
      required this.track,
      required this.trackIndex,
      required this.songId});

  @override
  ConsumerState<TrackControlTile> createState() => _TrackControlTileState();
}

class _TrackControlTileState extends ConsumerState<TrackControlTile> {
  late double _volume;
  late double _pan;
  late int _channel;
  Timer? _volumeDebounce;
  Timer? _panDebounce;

  @override
  void initState() {
    super.initState();
    _volume = widget.track.volume.clamp(0.0, 1.0);
    _pan = widget.track.pan.clamp(-1.0, 1.0);
    _channel = widget.track.outputChannel;
  }

  @override
  void dispose() {
    _volumeDebounce?.cancel();
    super.dispose();
  }

  void _debouncedSendPreviewVolume(double v) {
    _volumeDebounce?.cancel();
    _volumeDebounce = Timer(const Duration(milliseconds: 60), () async {
      final audioService = ref.read(audioDeviceServiceProvider);
      try {
        await audioService.setTrackVolume(widget.trackIndex, v);
      } catch (_) {
        // Ignora erros transitórios do canal nativo durante o arraste
      }
    });
  }

  void _debouncedSendPreviewPan(double p) {
    _panDebounce?.cancel();
    _panDebounce = Timer(const Duration(milliseconds: 60), () async {
      final audioService = ref.read(audioDeviceServiceProvider);
      try {
        await audioService.setTrackPan(widget.trackIndex, p);
      } catch (_) {
        // Ignora erros transitórios durante o arraste
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final previewingTrackId = ref.watch(previewingTrackIdProvider);
    final deviceAsync = ref.watch(currentDeviceProvider);
    final audioService = ref.read(audioDeviceServiceProvider);

    final isPreviewing = previewingTrackId == widget.track.id;

    // Estilo de um canal de mixer vertical
    return Container(
      width: 180, //largura do bus
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.black.withOpacity(0.4)),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Botão de metrônomo (quadrado com ícone de ampulheta)
            Consumer(
              builder: (context, ref, child) {
                final metronomeTrackId = ref.watch(metronomeTrackIdProvider);
                final shouldShowButton = metronomeTrackId == null ||
                    metronomeTrackId == widget.track.id;

                if (!shouldShowButton) {
                  return const SizedBox(
                      height: 32); // Espaço reservado quando oculto
                }

                final isMetronome = metronomeTrackId == widget.track.id;

                return Container(
                  width: 32,
                  height: 32,
                  margin: const EdgeInsets.only(bottom: 4),
                  child: Material(
                    color: isMetronome ? Colors.orange : Colors.grey[700],
                    borderRadius: BorderRadius.circular(4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () async {
                        // Usa operação atômica no repositório para garantir persistência e unicidade
                        if (isMetronome) {
                          // Desmarca metrônomo para todas as faixas da música
                          await ref
                              .read(songRepositoryProvider)
                              .setMetronomeTrack(widget.songId, null);
                          ref.read(metronomeTrackIdProvider.notifier).state =
                              null;
                        } else {
                          // Marca esta faixa como metrônomo e desmarca as demais na mesma transação
                          await ref
                              .read(songRepositoryProvider)
                              .setMetronomeTrack(
                                  widget.songId, widget.track.id);
                          ref.read(metronomeTrackIdProvider.notifier).state =
                              widget.track.id;
                        }
                      },
                      child: Icon(
                        Icons.hourglass_empty,
                        size: 18,
                        color: isMetronome ? Colors.white : Colors.grey[300],
                      ),
                    ),
                  ),
                );
              },
            ),

            // Cabeçalho com nome
            Text(
              widget.track.name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),

            // // Botão Preview
            // SizedBox(
            //   height: 36,
            //   child: ElevatedButton(
            //     onPressed: () async {
            //       await audioService.stopPreview();
            //       if (isPreviewing) {
            //         ref.read(previewingTrackIdProvider.notifier).state = null;
            //       } else {
            //         final path = widget.track.localFilePath;
            //         if (path.isEmpty) {
            //           ScaffoldMessenger.of(context).showSnackBar(
            //             const SnackBar(content: Text('Arquivo do track vazio')),
            //           );
            //           return;
            //         }
            //         try {
            //           final exists = await File(path).exists();
            //           if (!exists) {
            //             ScaffoldMessenger.of(context).showSnackBar(
            //               SnackBar(
            //                   content: Text('Arquivo não encontrado: $path')),
            //             );
            //             return;
            //           }
            //         } catch (_) {
            //           // Ignora erros de verificação de arquivo
            //         }
            //         debugPrint('Preview: path=' +
            //             path +
            //             ' channel=' +
            //             _channel.toString());
            //     try {
            //       // Ajusta volume atual antes de iniciar o preview
            //       await audioService.setPreviewVolume(_volume);
            //       await audioService.setPreviewPan(_pan);
            //       await audioService.playPreview(path, _channel);
            //     } catch (e) {
            //       ScaffoldMessenger.of(context).showSnackBar(
            //         SnackBar(content: Text('Erro ao iniciar preview: $e')),
            //       );
            //       return;
            //     }
            //         ref.read(previewingTrackIdProvider.notifier).state =
            //             widget.track.id;
            //       }
            //     },
            //     style: ElevatedButton.styleFrom(
            //       padding: const EdgeInsets.symmetric(horizontal: 10),
            //       backgroundColor:
            //           isPreviewing ? Colors.redAccent : Colors.blueGrey,
            //     ),
            //     child: Icon(isPreviewing ? Icons.stop : Icons.play_arrow,
            //         size: 18),
            //   ),
            // ),

            // const SizedBox(height: 10),
            //botao de play
            // Controle de Pan (estilo knob simplificado: valor e slider pequeno)
            Column(
              children: [
                Builder(builder: (context) {
                  final double p = _pan;
                  const double epsilon = 0.01; // ~1%
                  final String label;
                  if (p.abs() < epsilon) {
                    label = 'Pan: C';
                  } else {
                    final String dir = p < 0 ? 'L' : 'R';
                    final int percent = (p.abs() * 100).round();
                    label = 'Pan: $dir $percent%';
                  }
                  return Text(label);
                }),
                Slider(
                  value: _pan,
                  min: -1.0,
                  max: 1.0,
                  onChanged: (v) {
                    setState(() => _pan = v);
                    _debouncedSendPreviewPan(v);
                  },
                  onChangeEnd: (v) async {
                    final updated = widget.track.copyWith(pan: v);
                    await ref.read(songRepositoryProvider).updateTrack(updated);
                    final audioService = ref.read(audioDeviceServiceProvider);
                    try {
                      await audioService.setTrackPan(widget.trackIndex, v);
                    } catch (_) {}
                  },
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Fader vertical (responsivo) com slider da mesma altura do medidor
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final double height = constraints.maxHeight.isFinite
                      ? constraints.maxHeight
                      : 0.0;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // VU Meter dinâmico baseado no wave da faixa (isolado para repaints)
                      RepaintBoundary(
                        child: TrackLevelMeter(
                          filePath: widget.track.localFilePath,
                          volume: _volume,
                          height: height,
                          width: 25,
                          gain: 3,
                          gamma: 0.65,
                          segmented: false,
                          attack: 0.9,
                          release: 0.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Slider com altura igual ao medidor
                      Expanded(
                        child: SizedBox(
                          height: height,
                          child: Stack(
                            alignment: Alignment.bottomCenter,
                            children: [
                              // Valor no topo sem reduzir altura do slider
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                child: Center(
                                  child: Text(
                                    '${(_volume * 100).toStringAsFixed(0)}',
                                  ),
                                ),
                              ),
                              // Slider ocupando toda a altura (width = height antes de rotacionar)
                              Positioned.fill(
                                child: Center(
                                  child: RotatedBox(
                                    quarterTurns: -1,
                                    child: SizedBox(
                                      width: height,
                                      child: Slider(
                                        value: _volume,
                                        min: 0.0,
                                        max: 1.0,
                                        onChanged: (v) {
                                          setState(() => _volume = v);
                                          _debouncedSendPreviewVolume(v);
                                        },
                                        onChangeEnd: (v) async {
                                          final updated =
                                              widget.track.copyWith(volume: v);
                                          await ref
                                              .read(songRepositoryProvider)
                                              .updateTrack(updated);
                                          // Atualiza volume do preview atual
                                          final audioService = ref
                                              .read(audioDeviceServiceProvider);
                                          try {
                                            await audioService.setTrackVolume(
                                                widget.trackIndex, v);
                                          } catch (_) {}
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

            const SizedBox(height: 8),

            // Seletores de canais de entrada e saída
            deviceAsync.when(
              data: (device) {
                if (device == null) {
                  return const Text('Conecte o hardware');
                }
                final outputItems = <DropdownMenuItem<int>>[
                  for (int i = 0; i < device.outputChannels; i++)
                    DropdownMenuItem(value: i, child: Text('Saída ${i + 1}')),
                ];
                // Para dispositivos estéreo, adicionar par "Saída 1/2"
                if (device.outputChannels == 2) {
                  outputItems.add(const DropdownMenuItem(
                    value: 2,
                    child: Text('Saída 1/2'),
                  ));
                }
                return Column(
                  children: [
                    // Seletor de saída
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('Out:'),
                        const SizedBox(width: 8),
                        DropdownButton<int>(
                          value: _channel,
                          items: outputItems,
                          onChanged: (newChannel) async {
                            if (newChannel == null) return;
                            setState(() => _channel = newChannel);
                            final updated = widget.track
                                .copyWith(outputChannel: newChannel);
                            await ref
                                .read(songRepositoryProvider)
                                .updateTrack(updated);
                            // Se estiver em preview, reinicia no novo canal
                            if (isPreviewing) {
                              await audioService.stopPreview();
                              await audioService.playPreview(
                                  widget.track.localFilePath, _channel);
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                );
              },
              loading: () => const Text('Carregando dispositivo...'),
              error: (e, _) => Text('Erro no dispositivo: $e'),
            ),
          ],
        ),
      ),
    );
  }
}
