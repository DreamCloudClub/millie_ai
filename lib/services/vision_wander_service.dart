import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../utils/rosbridge.dart';
import 'local_cache_service.dart';
import 'visual_coverage.dart';

/// @deprecated Use PlannedSearchService instead.
/// This service is no longer integrated and will be removed.
///
/// Vision Wander Service
/// Uses GPT-4o-mini with vision to analyze camera frames + LiDAR data
/// and autonomously decide where the robot should explore.
@Deprecated('Use PlannedSearchService instead. This service is no longer integrated.')
class VisionWanderService {
  final RosBridge rosBridge;

  // API configuration
  static String? _apiKey;
  static const String _apiUrl = 'https://api.openai.com/v1/chat/completions';
  static const String _model = 'gpt-4o-mini';

  // Camera snapshot URL (for frame capture)
  static const String _cameraSnapshotUrl = 'http://192.168.0.157:8080/snapshot?topic=/oak/rgb/image_raw';

  // Timing configuration
  int _analysisIntervalMs = 3000; // Default 3 seconds
  static const int _rateLimitedIntervalMs = 10000; // Slow down on 429

  // State
  bool _isActive = false;
  bool _isPaused = false;
  Timer? _analysisTimer;
  LaserScan? _currentScan;
  final List<String> _recentMoves = [];
  static const int _maxRecentMoves = 5;

  // Search state
  String? _searchTarget;
  bool _targetFound = false;
  bool _pendingVerification = false;
  String? _targetLocation;
  double _targetConfidence = 0.0;
  String? _pendingScene;

  // Visual coverage tracking
  VisualCoverageMap? _coverageMap;
  final List<VisualObservation> _observations = [];

  // Callbacks
  void Function(String status)? onStatusChange;
  void Function(String reason)? onMoveDecision;
  void Function(String error)? onError;
  void Function(String target, String location, double confidence)? onTargetFound;
  void Function(String target, String scene)? onSearchUpdate;
  /// Called when target might be found - user should verify
  void Function(String target, String location, double confidence, String scene)? onTargetPendingVerification;
  /// Called when all areas have been explored without finding target
  void Function(String target, double coverage)? onSearchExhausted;

  // LiDAR sector definitions (8 sectors, 45 degrees each)
  static const Map<String, List<double>> _sectorRanges = {
    'Front': [-22.5, 22.5],
    'Front-Right': [22.5, 67.5],
    'Right': [67.5, 112.5],
    'Back-Right': [112.5, 157.5],
    'Back': [157.5, -157.5], // Wraps around
    'Back-Left': [-157.5, -112.5],
    'Left': [-112.5, -67.5],
    'Front-Left': [-67.5, -22.5],
  };

  VisionWanderService({required this.rosBridge});

  /// Set the OpenAI API key
  static void setApiKey(String key) {
    _apiKey = key;
    debugPrint('👁️ [VisionWander] API key set');
  }

  /// Load API key from cache
  Future<void> loadApiKey() async {
    final key = await LocalCacheService.loadOpenAIApiKey();
    if (key != null && key.isNotEmpty) {
      _apiKey = key;
      debugPrint('👁️ [VisionWander] API key loaded from cache');
    }
  }

  /// Check if service is currently active
  bool get isActive => _isActive;

  /// Check if service is paused
  bool get isPaused => _isPaused;

  /// Check if searching for something
  bool get isSearching => _searchTarget != null;

  /// Current search target
  String? get searchTarget => _searchTarget;

  /// Start searching for a target (layered on top of wander)
  Future<void> startSearch(String target) async {
    debugPrint('👁️ [VisionWander] Starting search for: $target');
    _searchTarget = target;
    _targetFound = false;
    _targetLocation = null;
    _targetConfidence = 0.0;
    _observations.clear();

    // Initialize coverage map from current map data (waits for map if needed)
    await _initCoverageMap();
  }

  /// Stop searching (wander continues)
  void stopSearch() {
    debugPrint('👁️ [VisionWander] Stopping search');
    _searchTarget = null;
    _targetFound = false;
    _observations.clear();
    // Keep coverage map for continued exploration awareness
  }

  /// Initialize coverage map from ROS map data
  Future<void> _initCoverageMap() async {
    var mapData = rosBridge.mapData;

    // Wait up to 5 seconds for map to be available
    if (mapData == null) {
      debugPrint('👁️ [VisionWander] Waiting for map data...');
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        mapData = rosBridge.mapData;
        if (mapData != null) break;
      }
    }

    if (mapData != null) {
      _coverageMap = VisualCoverageMap.fromMapData(mapData);
      final totalFree = _countFreeCells(mapData);
      debugPrint('👁️ [VisionWander] ✅ Coverage map initialized: ${mapData.width}x${mapData.height}, ~${totalFree} free cells');
    } else {
      debugPrint('👁️ [VisionWander] ⚠️ NO MAP DATA - coverage tracking DISABLED');
      debugPrint('👁️ [VisionWander] Robot will wander without knowing explored areas');
      onError?.call('No map available - exploration will be less efficient');
    }
  }

  /// Count free cells in map for logging
  int _countFreeCells(MapData mapData) {
    int count = 0;
    for (final val in mapData.data) {
      if (val >= 0 && val <= 50) count++;
    }
    return count;
  }

  /// Check if target was found
  bool get targetFound => _targetFound;

  /// Get all stored observations (with images and poses)
  List<VisualObservation> get observations => List.unmodifiable(_observations);

  /// Get current coverage percentage
  double get coveragePercent => _coverageMap?.getCoveragePercent() ?? 0.0;

  /// Get the coverage map for visualization
  VisualCoverageMap? get coverageMap => _coverageMap;

  /// Check if waiting for user verification
  bool get pendingVerification => _pendingVerification;

  /// Check if there are still unseen areas to explore
  bool get hasUnseenAreas {
    if (_coverageMap == null) return true; // Assume yes if no map
    final pose = rosBridge.currentPose;
    if (pose == null) return true;
    final headingDeg = pose.theta * 180.0 / 3.14159;
    final regions = _coverageMap!.findUnseenRegions(pose.x, pose.y, headingDeg);
    return regions.isNotEmpty;
  }

  /// Get search progress info for AI context
  Map<String, dynamic> get searchProgress {
    return {
      'searching': _searchTarget != null,
      'target': _searchTarget,
      'found': _targetFound,
      'pending_verification': _pendingVerification,
      'coverage_percent': coveragePercent.round(),
      'observations_count': _observations.length,
      'has_unseen_areas': hasUnseenAreas,
      'is_active': _isActive,
      'is_paused': _isPaused,
    };
  }

  /// User confirms the target was found
  void confirmTarget() {
    if (!_pendingVerification) return;

    debugPrint('👁️ [VisionWander] ✅ Target confirmed by user');
    _pendingVerification = false;
    _targetFound = true;

    // Notify that target is confirmed
    onTargetFound?.call(_searchTarget!, _targetLocation ?? 'in view', _targetConfidence);
    onStatusChange?.call('found');
  }

  /// User rejects the detection - resume searching
  void rejectTarget() {
    if (!_pendingVerification) return;

    debugPrint('👁️ [VisionWander] ❌ Target rejected by user - resuming search');
    _pendingVerification = false;
    _pendingScene = null;

    // Resume the analysis loop
    _startAnalysisLoop();
    onStatusChange?.call('searching');
  }

  /// Start vision wander mode
  Future<void> start() async {
    if (_isActive) {
      debugPrint('👁️ [VisionWander] Already active');
      return;
    }

    // Ensure API key is available
    if (_apiKey == null || _apiKey!.isEmpty) {
      await loadApiKey();
      if (_apiKey == null || _apiKey!.isEmpty) {
        onError?.call('No API key available');
        debugPrint('👁️ [VisionWander] No API key - cannot start');
        return;
      }
    }

    debugPrint('👁️ [VisionWander] Starting vision wander mode');
    _isActive = true;
    _isPaused = false;
    _recentMoves.clear();
    _observations.clear();

    // Initialize coverage map for spatial awareness (waits for map if needed)
    await _initCoverageMap();

    // Subscribe to LiDAR data
    rosBridge.addLaserScanListener(_handleLaserScan);

    // Enable LiDAR subscription on rosbridge (uncomment the line)
    _enableLidarSubscription();

    // Start analysis loop
    _startAnalysisLoop();

    onStatusChange?.call('active');
  }

  /// Stop vision wander mode
  Future<void> stop() async {
    if (!_isActive) return;

    debugPrint('👁️ [VisionWander] Stopping vision wander mode');
    _isActive = false;
    _isPaused = false;

    // Stop analysis loop
    _analysisTimer?.cancel();
    _analysisTimer = null;

    // Unsubscribe from LiDAR
    rosBridge.removeLaserScanListener(_handleLaserScan);

    // Stop robot movement
    rosBridge.publishMove('stop');

    onStatusChange?.call('stopped');
  }

  /// Pause vision wander (e.g., when person detected or conversation starts)
  void pause() {
    if (!_isActive || _isPaused) return;

    debugPrint('👁️ [VisionWander] Pausing');
    _isPaused = true;
    _analysisTimer?.cancel();
    _analysisTimer = null;

    // Stop robot movement
    rosBridge.publishMove('stop');

    onStatusChange?.call('paused');
  }

  /// Resume vision wander
  void resume() {
    if (!_isActive || !_isPaused) return;

    debugPrint('👁️ [VisionWander] Resuming');
    _isPaused = false;
    _startAnalysisLoop();

    onStatusChange?.call('active');
  }

  /// Enable LiDAR subscription on rosbridge
  void _enableLidarSubscription() {
    // The rosbridge.dart has this line commented out:
    // _subscribeThrottled('/scan_filtered', 'sensor_msgs/msg/LaserScan', 500);
    // We need to subscribe to it for vision wander
    // This is done by calling the private method or by modifying rosbridge
    // For now, we'll rely on the modification to rosbridge.dart
    debugPrint('👁️ [VisionWander] LiDAR subscription should be enabled in rosbridge');
  }

  /// Handle incoming LiDAR scan data
  void _handleLaserScan(LaserScan scan) {
    _currentScan = scan;
  }

  /// Start the analysis loop
  void _startAnalysisLoop() {
    _analysisTimer?.cancel();
    _analysisTimer = Timer.periodic(
      Duration(milliseconds: _analysisIntervalMs),
      (_) => _runAnalysisCycle(),
    );

    // Run first analysis immediately
    _runAnalysisCycle();
  }

  /// Run a single analysis cycle
  Future<void> _runAnalysisCycle() async {
    if (!_isActive || _isPaused) return;

    debugPrint('👁️ [VisionWander] Running analysis cycle');

    // Check if search is exhausted (all areas explored, target not found)
    if (_searchTarget != null && !_targetFound && _coverageMap != null) {
      final coverage = _coverageMap!.getCoveragePercent();
      if (coverage > 95.0 && !hasUnseenAreas) {
        debugPrint('👁️ [VisionWander] 📍 Search exhausted - ${coverage.toStringAsFixed(0)}% coverage, no unseen areas');
        onSearchExhausted?.call(_searchTarget!, coverage);
        // Don't stop - keep looking in case we missed something
        // But notify so the AI can inform the user
      }
    }

    try {
      // Capture camera frame
      final imageData = await _captureFrame();

      // Get LiDAR summary
      final lidarSummary = _getLidarSummary();

      // Call GPT-4o-mini vision API
      final decision = await _analyzeWithVision(imageData, lidarSummary);

      if (decision != null) {
        _executeDecision(decision, imageData);
      }
    } catch (e) {
      debugPrint('👁️ [VisionWander] Analysis error: $e');

      // Handle specific errors
      if (e.toString().contains('429')) {
        // Rate limited - slow down
        _analysisIntervalMs = _rateLimitedIntervalMs;
        debugPrint('👁️ [VisionWander] Rate limited - slowing to ${_analysisIntervalMs}ms');
        onError?.call('Rate limited - slowing down');
      } else if (e.toString().contains('Camera')) {
        // Camera unavailable - use LiDAR only
        debugPrint('👁️ [VisionWander] Camera unavailable - using LiDAR fallback');
        _lidarOnlyFallback();
      } else {
        // Other error - stop and retry next cycle
        rosBridge.publishMove('stop');
        onError?.call(e.toString());
      }
    }
  }

  /// Capture a frame from the camera stream
  Future<Uint8List?> _captureFrame() async {
    try {
      final response = await http.get(Uri.parse(_cameraSnapshotUrl))
          .timeout(const Duration(seconds: 2));

      if (response.statusCode == 200) {
        return response.bodyBytes;
      } else {
        throw Exception('Camera returned ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('👁️ [VisionWander] Camera capture failed: $e');
      throw Exception('Camera unavailable: $e');
    }
  }

  /// Get LiDAR summary as text
  String _getLidarSummary() {
    if (_currentScan == null) {
      return 'LIDAR: No data available\n';
    }

    final scan = _currentScan!;
    final buffer = StringBuffer('LIDAR DISTANCES (meters):\n');

    // Process each sector
    for (final entry in _sectorRanges.entries) {
      final sectorName = entry.key;
      final angleRange = entry.value;
      final minDistance = _getMinDistanceInSector(scan, angleRange[0], angleRange[1]);

      if (minDistance == null || minDistance > 10.0) {
        buffer.writeln('- $sectorName: clear');
      } else {
        buffer.writeln('- $sectorName: ${minDistance.toStringAsFixed(1)}m');
      }
    }

    return buffer.toString();
  }

  /// Get minimum distance in a sector
  double? _getMinDistanceInSector(LaserScan scan, double startAngleDeg, double endAngleDeg) {
    final startAngle = startAngleDeg * 3.14159 / 180.0;
    final endAngle = endAngleDeg * 3.14159 / 180.0;

    double? minDistance;

    for (int i = 0; i < scan.ranges.length; i++) {
      final angle = scan.angleMin + (i * scan.angleIncrement);

      // Handle wrap-around for back sector
      bool inSector;
      if (startAngleDeg > endAngleDeg) {
        // Wraps around (e.g., 157.5 to -157.5)
        inSector = angle >= startAngle || angle <= endAngle;
      } else {
        inSector = angle >= startAngle && angle <= endAngle;
      }

      if (inSector) {
        final range = scan.ranges[i];
        if (range > 0.1 && range < 10.0) { // Valid range
          if (minDistance == null || range < minDistance) {
            minDistance = range;
          }
        }
      }
    }

    return minDistance;
  }

  /// Analyze with GPT-4o-mini vision
  Future<Map<String, dynamic>?> _analyzeWithVision(Uint8List? imageData, String lidarSummary) async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw Exception('No API key');
    }

    // Build user prompt
    final userPrompt = StringBuffer();
    userPrompt.writeln(lidarSummary);
    userPrompt.writeln();
    userPrompt.writeln('RECENT MOVES: ${_recentMoves.isEmpty ? "none" : _recentMoves.join(", ")}');
    userPrompt.writeln();
    if (imageData != null) {
      userPrompt.writeln('[IMAGE attached]');
      userPrompt.writeln();
    }
    userPrompt.writeln('Analyze and decide your next move.');

    // Build messages
    final List<Map<String, dynamic>> messages = [
      {
        'role': 'system',
        'content': _buildSystemPrompt(),
      },
      {
        'role': 'user',
        'content': _buildUserContent(userPrompt.toString(), imageData),
      },
    ];

    // Build tools - include target detection fields when searching
    final properties = <String, dynamic>{
      'direction': {
        'type': 'string',
        'enum': ['forward', 'back', 'left', 'right', 'slight_left', 'slight_right', 'stop'],
        'description': 'The direction to move',
      },
      'reason': {
        'type': 'string',
        'description': 'Brief explanation of why this direction was chosen',
      },
      'scene': {
        'type': 'string',
        'description': 'Brief description of what you see (room type, notable objects, people)',
      },
    };

    final required = ['direction', 'reason', 'scene'];

    if (_searchTarget != null) {
      properties['target_visible'] = {
        'type': 'boolean',
        'description': 'TRUE ONLY if "$_searchTarget" is clearly visible with correct color and shape. When uncertain, use false.',
      };
      properties['target_confidence'] = {
        'type': 'number',
        'description': 'Confidence 0.0-1.0. Use 0.9+ only when color AND shape clearly match. Be skeptical.',
      };
      properties['target_location'] = {
        'type': 'string',
        'description': 'Where in the image: left/center/right, near/mid/far (only if target_visible)',
      };
      required.addAll(['target_visible']);
    }

    final tools = [
      {
        'type': 'function',
        'function': {
          'name': 'move_robot',
          'description': _searchTarget != null
              ? 'Analyze the image for "$_searchTarget", then decide movement direction'
              : 'Move the robot in a direction',
          'parameters': {
            'type': 'object',
            'properties': properties,
            'required': required,
          },
        },
      },
    ];

    // Make API call
    final response = await http.post(
      Uri.parse(_apiUrl),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': messages,
        'tools': tools,
        'tool_choice': {'type': 'function', 'function': {'name': 'move_robot'}},
        'max_tokens': 150,
      }),
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode == 429) {
      throw Exception('429 Rate Limited');
    }

    if (response.statusCode != 200) {
      throw Exception('API error: ${response.statusCode}');
    }

    // Parse response
    final data = jsonDecode(response.body);
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      return null;
    }

    final message = choices[0]['message'];
    final toolCalls = message['tool_calls'] as List?;
    if (toolCalls == null || toolCalls.isEmpty) {
      return null;
    }

    final toolCall = toolCalls[0];
    final function = toolCall['function'];
    final arguments = jsonDecode(function['arguments']);

    return arguments as Map<String, dynamic>;
  }

  /// Build user content with optional image
  List<Map<String, dynamic>> _buildUserContent(String text, Uint8List? imageData) {
    final content = <Map<String, dynamic>>[
      {'type': 'text', 'text': text},
    ];

    if (imageData != null) {
      final base64Image = base64Encode(imageData);
      content.add({
        'type': 'image_url',
        'image_url': {
          'url': 'data:image/jpeg;base64,$base64Image',
          // Use high detail when searching, low for regular exploration
          'detail': _searchTarget != null ? 'high' : 'low',
        },
      });
    }

    return content;
  }

  /// Build system prompt
  String _buildSystemPrompt() {
    final buffer = StringBuffer();

    buffer.writeln('You are an exploration AI controlling a mobile robot with camera and LiDAR.');
    buffer.writeln();

    if (_searchTarget != null) {
      buffer.writeln('🔍 ACTIVE SEARCH: Looking for "$_searchTarget"');
      buffer.writeln('Continue searching until you find it or have checked all areas.');
      buffer.writeln();
      buffer.writeln('DETECTION RULES:');
      buffer.writeln('- Describe what you see in "scene" field');
      buffer.writeln('- target_visible=true ONLY if object clearly matches "$_searchTarget"');
      buffer.writeln('- Check COLOR (brown ≠ blue) and SHAPE (box ≠ suitcase)');
      buffer.writeln('- When uncertain: target_visible=false, keep searching');
      buffer.writeln('- Be skeptical - false positives waste time');
      buffer.writeln();
    }

    // Add coverage info - this is CRITICAL for exploration
    final pose = rosBridge.currentPose;
    if (_coverageMap != null && pose != null) {
      final headingDeg = pose.theta * 180.0 / 3.14159;
      final coverage = _coverageMap!.getCoveragePercent();
      final suggestedDir = _coverageMap!.suggestDirection(pose.x, pose.y, headingDeg);
      final regions = _coverageMap!.findUnseenRegions(pose.x, pose.y, headingDeg);

      buffer.writeln('=== EXPLORATION STATUS ===');
      buffer.writeln('Coverage: ${coverage.toStringAsFixed(0)}% of area explored');
      buffer.writeln();

      if (regions.isNotEmpty) {
        buffer.writeln('UNSEEN AREAS (MUST explore these):');
        for (final region in regions.take(4)) {
          buffer.writeln('  • ${region.directionFromRobot}: ${region.areaSqMeters.toStringAsFixed(1)}m², ${region.distanceFromRobot.toStringAsFixed(1)}m away');
        }
        buffer.writeln();
        if (suggestedDir != null) {
          buffer.writeln('>>> PRIORITY: Go $suggestedDir to explore unseen area <<<');
        }
      } else {
        buffer.writeln('All areas explored - search complete.');
      }
      buffer.writeln();
    }

    // Detect stuck patterns
    if (_recentMoves.length >= 4) {
      final uniqueMoves = _recentMoves.toSet();
      if (uniqueMoves.length <= 2) {
        buffer.writeln('⚠️ STUCK PATTERN DETECTED: ${_recentMoves.join(", ")}');
        buffer.writeln('Try a DIFFERENT direction to break out!');
        buffer.writeln();
      }
    }

    buffer.writeln('''EXPLORATION RULES:
1. ALWAYS move toward UNSEEN areas listed above
2. DO NOT revisit areas you've already seen
3. When front is blocked, turn toward the largest unseen area
4. Keep moving - stopping wastes time

SAFETY (LiDAR-verified):
- Obstacles <0.6m: forbidden direction
- Obstacles <1.0m: prefer other direction
- Clear >1.5m: safe to proceed

OUTPUT: move_robot(direction, reason, scene)''');

    return buffer.toString();
  }

  // Movement pulse duration (brief movement, then stop)
  static const int _movePulseDurationMs = 600;

  // Safety thresholds (meters)
  static const double _minSafeDistance = 0.6;  // Stop if closer than this
  static const double _cautionDistance = 1.0;  // Slow down / prefer other direction

  /// Check if a direction is safe based on LiDAR data
  /// Returns the direction to use (may override to safer direction)
  String _getSafeDirection(String requestedDirection) {
    if (_currentScan == null) {
      debugPrint('👁️ [VisionWander] ⚠️ No LiDAR - stopping for safety');
      return 'stop';
    }

    final scan = _currentScan!;

    // Get distances in all key directions
    final frontDist = _getMinDistanceInSector(scan, -22.5, 22.5) ?? 10.0;
    final frontLeftDist = _getMinDistanceInSector(scan, -67.5, -22.5) ?? 10.0;
    final frontRightDist = _getMinDistanceInSector(scan, 22.5, 67.5) ?? 10.0;
    final leftDist = _getMinDistanceInSector(scan, -112.5, -67.5) ?? 10.0;
    final rightDist = _getMinDistanceInSector(scan, 67.5, 112.5) ?? 10.0;
    final backDist = _getMinDistanceInSector(scan, 157.5, -157.5) ?? 10.0;

    // Map requested direction to required clearance check
    double requiredClearance;
    switch (requestedDirection) {
      case 'forward':
        requiredClearance = frontDist;
        break;
      case 'slight_left':
        requiredClearance = (frontDist + frontLeftDist) / 2;
        break;
      case 'slight_right':
        requiredClearance = (frontDist + frontRightDist) / 2;
        break;
      case 'left':
        requiredClearance = frontLeftDist;
        break;
      case 'right':
        requiredClearance = frontRightDist;
        break;
      case 'back':
        requiredClearance = backDist;
        break;
      case 'stop':
        return 'stop';
      default:
        requiredClearance = frontDist;
    }

    // If requested direction is safe, allow it
    if (requiredClearance > _minSafeDistance) {
      return requestedDirection;
    }

    debugPrint('👁️ [VisionWander] ⚠️ SAFETY OVERRIDE: $requestedDirection blocked (${requiredClearance.toStringAsFixed(2)}m < ${_minSafeDistance}m)');

    // Find safest alternative direction
    final distances = {
      'forward': frontDist,
      'slight_left': (frontDist + frontLeftDist) / 2,
      'slight_right': (frontDist + frontRightDist) / 2,
      'left': leftDist,
      'right': rightDist,
      'back': backDist,
    };

    // Sort by distance (safest first)
    final sorted = distances.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Pick the safest direction that's actually safe
    for (final entry in sorted) {
      if (entry.value > _minSafeDistance) {
        debugPrint('👁️ [VisionWander] ✅ Safe alternative: ${entry.key} (${entry.value.toStringAsFixed(2)}m)');
        return entry.key;
      }
    }

    // Everything blocked - stop
    debugPrint('👁️ [VisionWander] 🛑 All directions blocked - stopping');
    return 'stop';
  }

  /// Execute the movement decision with brief pulse
  void _executeDecision(Map<String, dynamic> decision, Uint8List? imageData) {
    final requestedDirection = decision['direction'] as String? ?? 'stop';
    final reason = decision['reason'] as String? ?? '';
    final scene = decision['scene'] as String? ?? '';

    // Get current pose for observation recording
    final pose = rosBridge.currentPose;
    final headingDeg = pose != null ? pose.theta * 180.0 / 3.14159 : 0.0;

    // Mark this observation on the coverage map
    if (_coverageMap != null && pose != null) {
      _coverageMap!.markVisibilityCone(pose.x, pose.y, headingDeg);
      final coverage = _coverageMap!.getCoveragePercent();
      debugPrint('👁️ [VisionWander] Coverage: ${coverage.toStringAsFixed(1)}%');
    }

    // Handle search target detection
    if (_searchTarget != null) {
      final targetVisible = decision['target_visible'] as bool? ?? false;
      final confidence = (decision['target_confidence'] as num?)?.toDouble() ?? 0.0;
      final location = decision['target_location'] as String?;

      debugPrint('👁️ [VisionWander] Search update - visible: $targetVisible, confidence: $confidence, scene: $scene');

      // Record observation with image
      if (pose != null) {
        _observations.add(VisualObservation(
          timestamp: DateTime.now(),
          x: pose.x,
          y: pose.y,
          headingDegrees: headingDeg,
          searchTarget: _searchTarget,
          targetVisible: targetVisible,
          confidence: confidence,
          targetLocation: location,
          scene: scene,
          imageBytes: imageData,
        ));
        debugPrint('👁️ [VisionWander] Stored observation #${_observations.length} at (${pose.x.toStringAsFixed(1)}, ${pose.y.toStringAsFixed(1)}) heading ${headingDeg.toStringAsFixed(0)}° ${imageData != null ? "with image (${imageData.length} bytes)" : "no image"}');
      }

      // Report search progress
      onSearchUpdate?.call(_searchTarget!, scene);

      if (targetVisible && confidence > 0.85) {
        _targetLocation = location;
        _targetConfidence = confidence;
        _pendingScene = scene;
        _pendingVerification = true;

        debugPrint('👁️ [VisionWander] 🔍 POSSIBLE TARGET: $_searchTarget at $location (${(confidence * 100).toStringAsFixed(0)}% confidence) - awaiting verification');

        // Stop movement and pause analysis while waiting for verification
        rosBridge.publishMove('stop');
        _analysisTimer?.cancel();
        _analysisTimer = null;

        // Request user verification
        onTargetPendingVerification?.call(_searchTarget!, location ?? 'in view', confidence, scene);
        onMoveDecision?.call('stop: Possible $_searchTarget - verify?');
        return;
      }
    }

    // ========== SAFETY CHECK ==========
    // Validate direction against LiDAR before sending
    final safeDirection = _getSafeDirection(requestedDirection);

    if (safeDirection != requestedDirection) {
      debugPrint('👁️ [VisionWander] Direction changed: $requestedDirection → $safeDirection');
    }

    debugPrint('👁️ [VisionWander] Decision: $safeDirection - $reason');

    // Track recent moves
    _recentMoves.add(safeDirection);
    if (_recentMoves.length > _maxRecentMoves) {
      _recentMoves.removeAt(0);
    }

    // Execute brief movement pulse, then stop
    // This prevents continuous movement for full 3 second cycle
    rosBridge.publishMove(safeDirection);

    if (safeDirection != 'stop') {
      Future.delayed(const Duration(milliseconds: _movePulseDurationMs), () {
        if (_isActive && !_isPaused) {
          rosBridge.publishMove('stop');
        }
      });
    }

    onMoveDecision?.call('$safeDirection: $reason');
  }

  /// LiDAR-only fallback when camera is unavailable
  void _lidarOnlyFallback() {
    if (_currentScan == null) {
      rosBridge.publishMove('stop');
      return;
    }

    // Find the safest direction based on LiDAR
    final scan = _currentScan!;

    // Get distances in key directions
    final frontDist = _getMinDistanceInSector(scan, -22.5, 22.5) ?? 10.0;
    final leftDist = _getMinDistanceInSector(scan, -67.5, -22.5) ?? 10.0;
    final rightDist = _getMinDistanceInSector(scan, 22.5, 67.5) ?? 10.0;

    String direction;
    String reason;

    if (frontDist > 1.5) {
      direction = 'forward';
      reason = 'LiDAR fallback: clear ahead';
    } else if (leftDist > rightDist && leftDist > 1.0) {
      direction = 'slight_left';
      reason = 'LiDAR fallback: more space on left';
    } else if (rightDist > 1.0) {
      direction = 'slight_right';
      reason = 'LiDAR fallback: more space on right';
    } else {
      direction = 'back';
      reason = 'LiDAR fallback: blocked, backing up';
    }

    debugPrint('👁️ [VisionWander] LiDAR fallback: $direction - $reason');

    // Brief movement pulse, then stop
    rosBridge.publishMove(direction);
    if (direction != 'stop') {
      Future.delayed(const Duration(milliseconds: _movePulseDurationMs), () {
        if (_isActive && !_isPaused) {
          rosBridge.publishMove('stop');
        }
      });
    }

    onMoveDecision?.call('$direction: $reason (LiDAR only)');
  }

  /// Dispose of resources
  void dispose() {
    stop();
  }
}
