// Audio module for realtime voice streaming
//
// Architecture:
// - AssistantAudioBuffer: Ring buffer with response tracking and jitter buffering
// - ContinuousPcmPlayer: flutter_sound-based continuous PCM output
// - InterruptionController: VAD debouncing and barge-in detection

export 'assistant_audio_buffer.dart';
export 'continuous_pcm_player.dart';
export 'interruption_controller.dart';
