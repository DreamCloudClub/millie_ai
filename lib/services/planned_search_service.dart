import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../utils/rosbridge.dart';
import 'local_cache_service.dart';

/// Map-Based Search Service
///
/// Uses the occupancy grid map to plan systematic coverage:
/// 1. Generate viewpoints from free space in the map
/// 2. Navigate to each viewpoint using Nav2 (path planning, obstacle avoidance)
/// 3. Scan 360° at each viewpoint with camera analysis
/// 4. Track and visualize coverage in RViz2
/// 5. Continue until target found or all viewpoints visited
class PlannedSearchService {
  final RosBridge rosBridge;

  // API configuration
  static String? _apiKey;
  static const String _apiUrl = 'https://api.openai.com/v1/chat/completions';
  static const String _model = 'gpt-4o-mini';
  static const String _cameraSnapshotUrl = 'http://192.168.0.157:8080/snapshot?topic=/oak/rgb/image_raw';

  // Search configuration
  static const double _viewpointSpacing = 1.5;  // meters between viewpoints
  static const double _minDistanceFromWalls = 0.4;  // meters clearance
  static const int _maxSearchSeconds = 300;  // 5 minute timeout
  static const int _scanSteps = 4;  // 4 × 90° = 360° scan at each viewpoint

  // Search state
  bool _isSearching = false;
  bool _isPaused = false;
  String? _searchTarget;
  bool _pendingVerification = false;
  DateTime? _searchStartTime;

  // Viewpoints and coverage
  List<MapViewpoint> _viewpoints = [];
  int _currentViewpointIndex = 0;
  final Set<int> _visitedViewpoints = {};
  final List<RobotPose> _pathHistory = [];

  // Callbacks
  void Function(String status)? onStatusChange;
  void Function(String message)? onProgress;
  void Function(String target, String location, double confidence, String scene)? onTargetPendingVerification;
  void Function(String target, String location)? onTargetConfirmed;
  void Function(String error)? onError;
  void Function()? onSearchEnd;

  PlannedSearchService({required this.rosBridge});

  // Getters
  bool get isSearching => _isSearching;
  bool get isPaused => _isPaused;
  bool get pendingVerification => _pendingVerification;
  String? get searchTarget => _searchTarget;

  Map<String, dynamic> get searchProgress => {
    'searching': _isSearching,
    'target': _searchTarget,
    'pending_verification': _pendingVerification,
    'elapsed_seconds': _searchStartTime != null
        ? DateTime.now().difference(_searchStartTime!).inSeconds
        : 0,
    'viewpoints_total': _viewpoints.length,
    'viewpoints_visited': _visitedViewpoints.length,
  };

  /// Coverage percentage based on viewpoints visited
  double get coveragePercent {
    if (_viewpoints.isEmpty) return 0.0;
    return (_visitedViewpoints.length / _viewpoints.length) * 100.0;
  }

  List<dynamic> get observations => [];

  /// Set API key
  static void setApiKey(String key) {
    _apiKey = key;
  }

  /// Load API key from cache
  Future<void> loadApiKey() async {
    final key = await LocalCacheService.loadOpenAIApiKey();
    if (key != null && key.isNotEmpty) {
      _apiKey = key;
    }
  }

  /// Pause search
  void pause() {
    if (!_isSearching || _isPaused) return;
    debugPrint('🔍 [Search] Pausing');
    _isPaused = true;
    rosBridge.publishCancelNav();
    onStatusChange?.call('paused');
  }

  /// Resume search
  void resume() {
    if (!_isSearching || !_isPaused) return;
    debugPrint('🔍 [Search] Resuming');
    _isPaused = false;
    onStatusChange?.call('searching');
    _runSearchLoop();
  }

  // ===========================================================================
  // MAIN SEARCH API
  // ===========================================================================

  /// Start searching for a target
  Future<String?> startSearch(String target) async {
    if (_isSearching) {
      return 'Already searching for $_searchTarget';
    }

    debugPrint('🔍 [Search] ========================================');
    debugPrint('🔍 [Search] Starting map-based search for: "$target"');
    debugPrint('🔍 [Search] ========================================');

    // Immediately notify that search is starting
    onStatusChange?.call('searching');

    // Ensure API key
    if (_apiKey == null || _apiKey!.isEmpty) {
      await loadApiKey();
      if (_apiKey == null || _apiKey!.isEmpty) {
        onError?.call('No API key available');
        onStatusChange?.call('stopped');
        return 'No API key available. Please configure OpenAI API key in settings.';
      }
    }

    // Check for map
    final mapData = rosBridge.mapData;
    if (mapData == null) {
      onError?.call('No map available');
      onStatusChange?.call('stopped');
      return 'No map available. Please ensure SLAM is running.';
    }

    // Wait for robot pose if needed (up to 5 seconds)
    for (int i = 0; i < 10 && rosBridge.currentPose == null; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (rosBridge.currentPose == null) {
      onError?.call('No robot pose available');
      onStatusChange?.call('stopped');
      return 'Cannot determine robot position.';
    }

    // Generate viewpoints from map
    _viewpoints = _generateViewpoints(mapData);
    if (_viewpoints.isEmpty) {
      onError?.call('No searchable area found');
      onStatusChange?.call('stopped');
      return 'Could not find searchable area in map.';
    }

    debugPrint('🔍 [Search] Generated ${_viewpoints.length} viewpoints');

    // Sort viewpoints by distance from current position (nearest first)
    final currentPose = rosBridge.currentPose;
    if (currentPose != null) {
      _viewpoints.sort((a, b) {
        final distA = _distance(currentPose.x, currentPose.y, a.x, a.y);
        final distB = _distance(currentPose.x, currentPose.y, b.x, b.y);
        return distA.compareTo(distB);
      });
    }

    // Initialize search state
    _searchTarget = target;
    _isSearching = true;
    _isPaused = false;
    _pendingVerification = false;
    _searchStartTime = DateTime.now();
    _currentViewpointIndex = 0;
    _visitedViewpoints.clear();
    _pathHistory.clear();

    // Publish viewpoints to RViz2
    _publishViewpointsToRviz();

    onProgress?.call('Looking for $target... (${_viewpoints.length} areas to check)');

    // Start the search loop
    _runSearchLoop();

    return null; // Success
  }

  /// Stop searching
  void stopSearch() {
    if (!_isSearching) return;

    debugPrint('🔍 [Search] Stopping');
    _isSearching = false;
    _isPaused = false;
    _pendingVerification = false;
    _searchTarget = null;
    _searchStartTime = null;

    rosBridge.publishCancelNav();
    rosBridge.publishVelocity(linear: 0, angular: 0);

    // Clear RViz markers
    _clearRvizMarkers();

    onStatusChange?.call('stopped');
    onSearchEnd?.call();
  }

  /// User confirms the detected target
  void confirmTarget() {
    if (!_pendingVerification) return;

    debugPrint('🔍 [Search] Target confirmed!');
    final target = _searchTarget ?? 'target';

    _pendingVerification = false;
    stopSearch();

    onTargetConfirmed?.call(target, 'found');
    onStatusChange?.call('found');
  }

  /// User rejects the detected target - move to next viewpoint and resume
  void rejectTarget() {
    if (!_pendingVerification) return;

    debugPrint('🔍 [Search] Target rejected - moving to next viewpoint');
    _pendingVerification = false;

    // Move to next viewpoint so we don't re-scan the same spot
    _currentViewpointIndex++;

    onProgress?.call('Okay, checking somewhere else...');
    onStatusChange?.call('searching');

    _runSearchLoop();
  }

  // ===========================================================================
  // VIEWPOINT GENERATION
  // ===========================================================================

  /// Generate search viewpoints using flood-fill from robot's position
  /// Only includes reachable free space, not disconnected areas
  List<MapViewpoint> _generateViewpoints(MapData map) {
    final currentPose = rosBridge.currentPose;
    if (currentPose == null) {
      debugPrint('🔍 [Search] No robot pose available');
      return [];
    }

    // Convert robot position to grid coordinates
    final robotGridX = ((currentPose.x - map.originX) / map.resolution).round();
    final robotGridY = ((currentPose.y - map.originY) / map.resolution).round();

    debugPrint('🔍 [Search] Map: ${map.width}x${map.height}, resolution: ${map.resolution}m/cell');
    debugPrint('🔍 [Search] Robot at grid: ($robotGridX, $robotGridY)');

    // Flood-fill to find all reachable free cells from robot position
    final reachableCells = _floodFillReachable(map, robotGridX, robotGridY);
    debugPrint('🔍 [Search] Found ${reachableCells.length} reachable cells');

    if (reachableCells.isEmpty) {
      debugPrint('🔍 [Search] No reachable cells found!');
      return [];
    }

    // Sample viewpoints from reachable cells at regular spacing
    final viewpoints = <MapViewpoint>[];
    final cellSpacing = (_viewpointSpacing / map.resolution).round();
    final clearanceCells = (_minDistanceFromWalls / map.resolution).round();
    final visited = <String>{};

    for (final cell in reachableCells) {
      final x = cell[0];
      final y = cell[1];

      // Only sample at grid spacing intervals
      final gridKey = '${(x / cellSpacing).floor()},${(y / cellSpacing).floor()}';
      if (visited.contains(gridKey)) continue;
      visited.add(gridKey);

      // Check clearance from walls
      if (!_hasClearance(map, x, y, clearanceCells)) continue;

      // Convert to world coordinates
      final worldX = map.originX + (x * map.resolution);
      final worldY = map.originY + (y * map.resolution);

      viewpoints.add(MapViewpoint(
        x: worldX,
        y: worldY,
        gridX: x,
        gridY: y,
      ));
    }

    debugPrint('🔍 [Search] Generated ${viewpoints.length} viewpoints');
    return viewpoints;
  }

  /// Flood-fill to find all free cells reachable from start position
  Set<List<int>> _floodFillReachable(MapData map, int startX, int startY) {
    final reachable = <List<int>>{};
    final queue = <List<int>>[];
    final visited = <String>{};

    // Limit search to reasonable area (20m radius = ~400 cells at 0.05m resolution)
    const maxRadius = 400;
    const maxCells = 10000;  // Limit total cells to prevent memory issues

    // Start from robot position
    if (_isCellFree(map, startX, startY)) {
      queue.add([startX, startY]);
      visited.add('$startX,$startY');
    } else {
      // Robot might be on edge - search nearby for free cell
      for (int dy = -3; dy <= 3; dy++) {
        for (int dx = -3; dx <= 3; dx++) {
          final x = startX + dx;
          final y = startY + dy;
          if (_isCellFree(map, x, y)) {
            queue.add([x, y]);
            visited.add('$x,$y');
            break;
          }
        }
        if (queue.isNotEmpty) break;
      }
    }

    // BFS flood-fill
    while (queue.isNotEmpty && reachable.length < maxCells) {
      final cell = queue.removeAt(0);
      final x = cell[0];
      final y = cell[1];

      // Check distance from start
      final dist = math.sqrt(math.pow(x - startX, 2) + math.pow(y - startY, 2));
      if (dist > maxRadius) continue;

      reachable.add(cell);

      // Check 4 neighbors
      for (final dir in [[0, 1], [0, -1], [1, 0], [-1, 0]]) {
        final nx = x + dir[0];
        final ny = y + dir[1];
        final key = '$nx,$ny';

        if (visited.contains(key)) continue;
        visited.add(key);

        if (_isCellFree(map, nx, ny)) {
          queue.add([nx, ny]);
        }
      }
    }

    return reachable;
  }

  /// Check if a cell is free (not unknown, not occupied)
  bool _isCellFree(MapData map, int x, int y) {
    if (x < 0 || x >= map.width || y < 0 || y >= map.height) return false;
    final cellIndex = y * map.width + x;
    if (cellIndex >= map.data.length) return false;
    return map.data[cellIndex] == 0;  // 0 = free
  }

  /// Check if a point has sufficient clearance from obstacles
  bool _hasClearance(MapData map, int centerX, int centerY, int clearance) {
    for (int dy = -clearance; dy <= clearance; dy++) {
      for (int dx = -clearance; dx <= clearance; dx++) {
        final x = centerX + dx;
        final y = centerY + dy;

        if (x < 0 || x >= map.width || y < 0 || y >= map.height) {
          return false;  // Out of bounds
        }

        final cellIndex = y * map.width + x;
        final cellValue = map.data[cellIndex];

        // Obstacle (100) or unknown (-1) too close
        if (cellValue != 0) return false;
      }
    }
    return true;
  }

  // ===========================================================================
  // SEARCH LOOP
  // ===========================================================================

  Future<void> _runSearchLoop() async {
    debugPrint('🔍 [Search] Starting search loop');

    while (_isSearching && !_pendingVerification && _currentViewpointIndex < _viewpoints.length) {
      // Check timeout
      if (_searchStartTime != null) {
        final elapsed = DateTime.now().difference(_searchStartTime!).inSeconds;
        if (elapsed >= _maxSearchSeconds) {
          debugPrint('🔍 [Search] Timeout reached');
          onProgress?.call('Search timeout - $_searchTarget not found after checking ${_visitedViewpoints.length} areas');
          stopSearch();
          return;
        }
      }

      // Wait if paused
      while (_isPaused && _isSearching) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (!_isSearching) break;

      // Get next viewpoint
      final viewpoint = _viewpoints[_currentViewpointIndex];
      debugPrint('🔍 [Search] Navigating to viewpoint ${_currentViewpointIndex + 1}/${_viewpoints.length}: (${viewpoint.x.toStringAsFixed(2)}, ${viewpoint.y.toStringAsFixed(2)})');
      onProgress?.call('Checking area ${_currentViewpointIndex + 1} of ${_viewpoints.length}...');

      // Update RViz visualization
      _publishCurrentTarget(viewpoint);

      // Navigate to viewpoint
      final navSuccess = await _navigateToViewpoint(viewpoint);
      if (!_isSearching) break;

      if (navSuccess) {
        // Record position
        _recordPosition();
        _visitedViewpoints.add(_currentViewpointIndex);

        // Scan 360° at this viewpoint
        debugPrint('🔍 [Search] Scanning at viewpoint...');
        final found = await _scan360();
        if (found || _pendingVerification || !_isSearching) break;

        // Update coverage display
        _publishPathToRviz();
      } else {
        debugPrint('🔍 [Search] Navigation failed, skipping viewpoint');
      }

      _currentViewpointIndex++;
    }

    if (_isSearching && !_pendingVerification) {
      debugPrint('🔍 [Search] All viewpoints checked');
      onProgress?.call('Finished searching ${_visitedViewpoints.length} areas - $_searchTarget not found');
      stopSearch();
    }
  }

  /// Navigate to a viewpoint using Nav2
  Future<bool> _navigateToViewpoint(MapViewpoint viewpoint) async {
    final completer = Completer<NavStatus>();

    void listener(NavStatus status) {
      if (status == NavStatus.succeeded ||
          status == NavStatus.failed ||
          status == NavStatus.canceled) {
        if (!completer.isCompleted) {
          completer.complete(status);
        }
      }
    }

    rosBridge.addNavStatusListener(listener);

    // Send navigation goal
    rosBridge.publishNavGoal(viewpoint.x, viewpoint.y);

    try {
      // Wait for navigation with timeout
      final status = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          debugPrint('🔍 [Search] Navigation timeout');
          rosBridge.publishCancelNav();
          return NavStatus.failed;
        },
      );

      rosBridge.removeNavStatusListener(listener);
      return status == NavStatus.succeeded;
    } catch (e) {
      rosBridge.removeNavStatusListener(listener);
      debugPrint('🔍 [Search] Navigation error: $e');
      return false;
    }
  }

  /// Scan 360° at current position
  Future<bool> _scan360() async {
    const rotationPerStep = 360.0 / _scanSteps;

    for (int step = 0; step < _scanSteps; step++) {
      if (!_isSearching || _pendingVerification) break;

      // Analyze current view
      final found = await _captureAndAnalyze();
      if (found) return true;

      // Rotate to next position (unless last step)
      if (step < _scanSteps - 1) {
        await _rotate(rotationPerStep);
      }
    }

    return false;
  }

  /// Rotate by a given angle
  Future<void> _rotate(double degrees) async {
    // 4 seconds per rotation for testing
    const durationMs = 4000;

    const rotationSpeed = 0.8;  // rad/s
    debugPrint('🔄 [Search] Starting rotation: ${degrees}° for ${durationMs}ms');
    rosBridge.publishVelocity(linear: 0, angular: degrees > 0 ? rotationSpeed : -rotationSpeed);
    final startTime = DateTime.now();
    await Future.delayed(Duration(milliseconds: durationMs));
    final elapsed = DateTime.now().difference(startTime).inMilliseconds;
    debugPrint('🔄 [Search] Rotation complete: actually waited ${elapsed}ms');
    rosBridge.publishVelocity(linear: 0, angular: 0);
    await Future.delayed(const Duration(milliseconds: 200));  // Settle
  }

  /// Record current position in path history
  void _recordPosition() {
    final pose = rosBridge.currentPose;
    if (pose != null) {
      _pathHistory.add(pose);
    }
  }

  // ===========================================================================
  // VISION ANALYSIS
  // ===========================================================================

  Future<bool> _captureAndAnalyze() async {
    try {
      debugPrint('🔍 [Search] Capturing image...');

      final imageResponse = await http.get(Uri.parse(_cameraSnapshotUrl))
          .timeout(const Duration(seconds: 5));

      if (imageResponse.statusCode != 200) {
        debugPrint('🔍 [Search] Camera capture failed: ${imageResponse.statusCode}');
        return false;
      }

      final imageBytes = imageResponse.bodyBytes;
      final base64Image = base64Encode(imageBytes);

      debugPrint('🔍 [Search] Analyzing with GPT-4o-mini...');
      final result = await _analyzeWithVision(base64Image);
      if (result == null) return false;

      final targetVisible = result['target_visible'] as bool? ?? false;
      final confidence = (result['confidence'] as num?)?.toDouble() ?? 0.0;
      final location = result['location'] as String?;
      final scene = result['scene'] as String? ?? '';

      debugPrint('🔍 [Search] Analysis: visible=$targetVisible, confidence=${(confidence * 100).toStringAsFixed(0)}%, scene=$scene');

      // Check if target found with high confidence
      if (targetVisible && confidence >= 0.7) {
        debugPrint('🔍 [Search] 🎯 Target detected!');
        _pendingVerification = true;

        onProgress?.call('I think I found the $_searchTarget!');
        onTargetPendingVerification?.call(
          _searchTarget!,
          location ?? 'in view',
          confidence,
          scene,
        );
        onStatusChange?.call('pending_verification');
        return true;
      }

      return false;
    } catch (e) {
      debugPrint('🔍 [Search] Analysis error: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> _analyzeWithVision(String base64Image) async {
    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': _model,
          'messages': [
            {
              'role': 'system',
              'content': '''You are searching for: "$_searchTarget"

Respond with ONLY a JSON object:
{
  "target_visible": true/false,
  "confidence": 0.0-1.0,
  "location": "left/center/right/far" (if visible),
  "scene": "brief 5-word description"
}

Be accurate - only say target_visible=true if you clearly see "$_searchTarget".'''
            },
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'Do you see the $_searchTarget?'},
                {
                  'type': 'image_url',
                  'image_url': {
                    'url': 'data:image/jpeg;base64,$base64Image',
                    'detail': 'low',
                  },
                },
              ],
            },
          ],
          'max_tokens': 100,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('🔍 [Search] Vision API error: ${response.statusCode}');
        return null;
      }

      final data = jsonDecode(response.body);
      final content = data['choices']?[0]?['message']?['content'] as String? ?? '{}';

      // Parse JSON from response
      String jsonContent = content.trim();
      if (jsonContent.startsWith('```')) {
        jsonContent = jsonContent
            .replaceAll(RegExp(r'^```json?\n?'), '')
            .replaceAll(RegExp(r'\n?```$'), '');
      }

      return jsonDecode(jsonContent) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('🔍 [Search] Vision analysis error: $e');
      return null;
    }
  }

  // ===========================================================================
  // RVIZ VISUALIZATION
  // ===========================================================================

  /// Publish viewpoints as markers to RViz2
  void _publishViewpointsToRviz() {
    if (!rosBridge.isConnected) return;

    final markers = <Map<String, dynamic>>[];

    for (int i = 0; i < _viewpoints.length; i++) {
      final vp = _viewpoints[i];
      markers.add({
        'header': {'frame_id': 'map'},
        'ns': 'search_viewpoints',
        'id': i,
        'type': 2,  // SPHERE
        'action': 0,  // ADD
        'pose': {
          'position': {'x': vp.x, 'y': vp.y, 'z': 0.1},
          'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0},
        },
        'scale': {'x': 0.2, 'y': 0.2, 'z': 0.2},
        'color': {'r': 0.0, 'g': 0.5, 'b': 1.0, 'a': 0.6},  // Blue
      });
    }

    _publishMarkerArray(markers);
  }

  /// Publish current navigation target
  void _publishCurrentTarget(MapViewpoint viewpoint) {
    if (!rosBridge.isConnected) return;

    final marker = {
      'header': {'frame_id': 'map'},
      'ns': 'search_current',
      'id': 0,
      'type': 2,  // SPHERE
      'action': 0,  // ADD
      'pose': {
        'position': {'x': viewpoint.x, 'y': viewpoint.y, 'z': 0.3},
        'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0},
      },
      'scale': {'x': 0.4, 'y': 0.4, 'z': 0.4},
      'color': {'r': 1.0, 'g': 0.8, 'b': 0.0, 'a': 1.0},  // Yellow
    };

    _publishMarkerArray([marker]);
  }

  /// Publish search path history to RViz2
  void _publishPathToRviz() {
    if (!rosBridge.isConnected || _pathHistory.isEmpty) return;

    final poses = _pathHistory.map((pose) => {
      'pose': {
        'position': {'x': pose.x, 'y': pose.y, 'z': 0.0},
        'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0},
      },
    }).toList();

    final pathMsg = {
      'op': 'publish',
      'topic': '/search_path',
      'msg': {
        'header': {'frame_id': 'map'},
        'poses': poses,
      },
    };

    rosBridge.sendRaw(jsonEncode(pathMsg));

    // Also publish visited viewpoints as green markers
    final visitedMarkers = <Map<String, dynamic>>[];
    for (final idx in _visitedViewpoints) {
      final vp = _viewpoints[idx];
      visitedMarkers.add({
        'header': {'frame_id': 'map'},
        'ns': 'search_visited',
        'id': idx,
        'type': 2,  // SPHERE
        'action': 0,  // ADD
        'pose': {
          'position': {'x': vp.x, 'y': vp.y, 'z': 0.1},
          'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0},
        },
        'scale': {'x': 0.25, 'y': 0.25, 'z': 0.25},
        'color': {'r': 0.0, 'g': 1.0, 'b': 0.0, 'a': 0.8},  // Green
      });
    }

    if (visitedMarkers.isNotEmpty) {
      _publishMarkerArray(visitedMarkers);
    }
  }

  /// Clear all RViz markers
  void _clearRvizMarkers() {
    if (!rosBridge.isConnected) return;

    // Delete all markers in our namespaces
    for (final ns in ['search_viewpoints', 'search_current', 'search_visited']) {
      final deleteMarker = {
        'header': {'frame_id': 'map'},
        'ns': ns,
        'id': 0,
        'action': 3,  // DELETEALL
      };
      _publishMarkerArray([deleteMarker]);
    }
  }

  void _publishMarkerArray(List<Map<String, dynamic>> markers) {
    final msg = {
      'op': 'publish',
      'topic': '/search_markers',
      'msg': {
        'markers': markers,
      },
    };
    rosBridge.sendRaw(jsonEncode(msg));
  }

  // ===========================================================================
  // UTILITIES
  // ===========================================================================

  double _distance(double x1, double y1, double x2, double y2) {
    return math.sqrt(math.pow(x2 - x1, 2) + math.pow(y2 - y1, 2));
  }

  void dispose() {
    stopSearch();
  }
}

/// A viewpoint on the map to visit during search
class MapViewpoint {
  final double x;  // World X coordinate
  final double y;  // World Y coordinate
  final int gridX;  // Grid cell X
  final int gridY;  // Grid cell Y

  MapViewpoint({
    required this.x,
    required this.y,
    required this.gridX,
    required this.gridY,
  });
}
