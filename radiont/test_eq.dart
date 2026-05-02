import 'package:just_audio/just_audio.dart';

void main() async {
  final enhancer = AndroidLoudnessEnhancer();
  enhancer.setTargetGain(0.5);
  enhancer.setEnabled(true);
}
