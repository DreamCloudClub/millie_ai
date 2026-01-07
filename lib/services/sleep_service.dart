/// Simple sleep state tracking for the robot face
/// Used by WakeService to track whether robot is in sleep mode
class SleepService {
  static bool _isSleeping = false;

  static bool get isSleeping => _isSleeping;

  /// Put robot to sleep (stop listening for conversations)
  static void sleep() {
    _isSleeping = true;
  }

  /// Wake robot up (resume listening)
  static void wakeUp() {
    _isSleeping = false;
  }
}
