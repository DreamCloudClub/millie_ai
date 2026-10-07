import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../utils/rosbridge.dart';
import 'local_cache_service.dart';
import 'planned_search_service.dart';
import 'visual_coverage.dart';

/// Result from executing an AI tool
class ToolResult {
  final bool success;
  final String message;
  final Map<String, dynamic>? data;

  ToolResult({required this.success, required this.message, this.data});

  Map<String, dynamic> toJson() => {
    'success': success,
    'message': message,
    if (data != null) 'data': data,
  };

  @override
  String toString() => 'ToolResult(success: $success, message: $message)';
}

/// A tool call from the AI
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  ToolCall({required this.id, required this.name, required this.arguments});

  factory ToolCall.fromJson(Map<String, dynamic> json) {
    return ToolCall(
      id: json['id'] as String? ?? '',
      name: json['function']?['name'] as String? ?? json['name'] as String? ?? '',
      arguments: json['function']?['arguments'] is String
          ? jsonDecode(json['function']['arguments'] as String) as Map<String, dynamic>
          : (json['function']?['arguments'] as Map<String, dynamic>? ?? json['arguments'] as Map<String, dynamic>? ?? {}),
    );
  }
}

// VisualObservation, UnseenRegion, and VisualCoverageMap moved to visual_coverage.dart

/// Active search session - tracks ongoing visual search
class SearchSession {
  final String target;
  final DateTime startTime;
  final List<VisualObservation> observations = [];
  VisualCoverageMap? coverage;
  bool targetFound = false;
  VisualObservation? foundObservation;

  SearchSession({required this.target}) : startTime = DateTime.now();

  /// Record a new observation and update coverage
  void recordObservation(VisualObservation obs) {
    observations.add(obs);

    // Update coverage map
    coverage?.markVisibilityCone(obs.x, obs.y, obs.headingDegrees);

    // Check if target was found
    if (obs.targetVisible && obs.confidence > 0.75) {
      targetFound = true;
      foundObservation = obs;
    }
  }

  /// Get current search status as structured data for AI
  Map<String, dynamic> getStatus(double robotX, double robotY, double robotHeading) {
    final coveragePercent = coverage?.getCoveragePercent() ?? 0.0;
    final unseenRegions = coverage?.findUnseenRegions(robotX, robotY, robotHeading) ?? [];
    final suggestedViewpoint = coverage?.suggestNextViewpoint(robotX, robotY, robotHeading);

    return {
      'search_target': target,
      'target_found': targetFound,
      'coverage_percent': coveragePercent.round(),
      'observations_count': observations.length,
      'search_duration_seconds': DateTime.now().difference(startTime).inSeconds,
      'current_pose': {
        'x': robotX,
        'y': robotY,
        'heading': robotHeading,
      },
      'unseen_regions': unseenRegions.map((r) => r.toJson()).toList(),
      'suggested_next_viewpoint': suggestedViewpoint,
      'recent_observations': observations.reversed.take(5).map((o) => {
        'x': o.x,
        'y': o.y,
        'heading': o.headingDegrees,
        'result': o.targetVisible ? 'FOUND' : (o.possibleMatch ? 'possible' : 'not visible'),
        'confidence': o.confidence,
        'scene': o.scene,
      }).toList(),
      if (targetFound && foundObservation != null) 'found_at': {
        'x': foundObservation!.x,
        'y': foundObservation!.y,
        'heading': foundObservation!.headingDegrees,
        'location_in_image': foundObservation!.targetLocation,
        'description': foundObservation!.description,
      },
    };
  }
}

/// Workflow Tools for AI function calling
/// Gives the Default Action full control over the robot:
/// - Navigate to any waypoint
/// - Execute any action
/// - Control workflow (pause, resume, stop, etc.)
class WorkflowTools {
  final RosBridge rosBridge;

  // Planned search service reference (for object search)
  PlannedSearchService? plannedSearchService;

  // Callback when workflow is confirmed and conversation should end
  void Function()? onWorkflowConfirmed;

  // Callback when task starts - pause AI, navigate, speak message on arrival, resume silently
  // Parameters: destination waypoint, message to speak on arrival
  void Function(String destination, String messageToSpeak)? onTaskStart;
  
  // Local cache from listener updates
  List<Waypoint> _waypoints = [];
  List<SavedSequence> _sequences = [];
  List<ActionDefinition> _actions = [];
  RobotPose? _pose;
  
  // Current workflow state from robot
  String _workflowState = 'idle';
  int _currentStep = 0;
  int _totalSteps = 0;
  List<Map<String, dynamic>> _remainingSteps = [];
  String? _defaultHome;

  // Saved position for "go away" / "come back"
  RobotPose? _goAwayPose;

  // Person detection state (updated from conversation_service)
  bool _personDetected = false;
  double? _personDistance;
  bool _personCentered = false;

  // Following mode state (updated from conversation_service)
  bool _followingActive = false;
  String _followingStatus = 'disabled';  // disabled, searching, tracking, approaching, arrived, lost

  // Wander mode state (updated from conversation_service)
  bool _wanderActive = false;
  String _wanderStatus = 'disabled';  // disabled, enabled, navigating, paused_person, etc.

  // Vision configuration
  static const String _cameraSnapshotUrl = 'http://192.168.0.157:8080/snapshot?topic=/oak/rgb/image_raw';
  static const String _visionApiUrl = 'https://api.openai.com/v1/chat/completions';
  static const String _visionModel = 'gpt-4o-mini';
  static String? _apiKey;

  // LiDAR data (updated from rosbridge)
  LaserScan? _currentScan;

  // Visual search session
  SearchSession? _searchSession;

  // Track if wander was active before search (to resume after)
  bool _wanderActiveBeforeSearch = false;

  /// Set the OpenAI API key for vision
  static void setApiKey(String key) {
    _apiKey = key;
  }

  /// Update LiDAR scan data
  void updateLaserScan(LaserScan scan) {
    _currentScan = scan;
  }

  /// Update person detection status (called from conversation_service)
  void updatePersonStatus({required bool detected, double? distance, bool centered = false}) {
    _personDetected = detected;
    _personDistance = distance;
    _personCentered = centered;
  }

  /// Update following mode status (called from conversation_service)
  void updateFollowingStatus({required String status}) {
    _followingStatus = status;
    _followingActive = status != 'disabled' && status != 'lost';
  }

  /// Update wander mode status (called from conversation_service)
  void updateWanderStatus({required String status}) {
    _wanderStatus = status;
    _wanderActive = status == 'enabled' || status == 'navigating' || status == 'paused_person';
  }

  // Callback for wander mode (wander only, AI stays active)
  void Function()? onWanderModeStart;
  void Function()? onWanderModeStop;

  // Callback for go_away to trigger Wander Mode
  void Function()? onGoAwayRequested;

  // Callback for approach_user to move toward detected person
  void Function()? onApproachUserRequested;

  // Callback when a temp task is queued (navigate + action)
  // Parameters: action definition (temp), origin pose (for return-to-origin)
  void Function(ActionDefinition action, RobotPose? originPose)? onTempTaskQueued;

  // Callback when AI wants to end the conversation naturally
  void Function()? onConversationEnd;

  // Callback when AI wants to show a different page
  // Parameters: page name (face, dashboard, notes, schedule, settings, chat, identity)
  void Function(String pageName)? onShowPage;


  // Callback to speak only if in ready/idle state (not during active conversation)
  void Function(String text)? onSpeakIfIdle;




  // Pending task ready to execute (set by queue_task, executed by go)
  Map<String, dynamic>? _pendingTask;

  // Pending steps to be executed (queued locally until confirm_and_execute)
  List<Map<String, String>> _pendingSteps = [];
  
  // Listener references for cleanup
  late final void Function(List<Waypoint>) _waypointListener;
  late final void Function(List<SavedSequence>) _sequenceListener;
  late final void Function(List<ActionDefinition>) _actionListener;
  late final void Function(RobotPose) _poseListener;
  late final void Function(String, int, int, List<Map<String, dynamic>>?) _workflowStatusListener;
  
  WorkflowTools(this.rosBridge) {
    _setupListeners();
  }
  
  void _setupListeners() {
    _waypointListener = (waypoints) {
      _waypoints = waypoints;
      debugPrint('🧭 [WorkflowTools] ${waypoints.length} waypoints loaded');
    };
    
    _sequenceListener = (sequences) {
      _sequences = sequences;
      debugPrint('🧭 [WorkflowTools] ${sequences.length} sequences loaded');
    };
    
    _actionListener = (actions) {
      _actions = actions;
      debugPrint('🧭 [WorkflowTools] ${actions.length} actions loaded');
    };
    
    _poseListener = (pose) {
      _pose = pose;
    };
    
    _workflowStatusListener = (status, step, total, steps) {
      _workflowState = status;
      _currentStep = step;
      _totalSteps = total;
      if (steps != null) {
        _remainingSteps = steps;
      }
    };
    
    rosBridge.addWaypointListener(_waypointListener);
    rosBridge.addSequenceListener(_sequenceListener);
    rosBridge.addActionListener(_actionListener);
    rosBridge.addPoseListener(_poseListener);
    rosBridge.addWorkflowStatusListener(_workflowStatusListener);
    
    // Request initial data
    rosBridge.requestWaypoints();
    rosBridge.requestSequences();
    rosBridge.requestActions();
  }
  
  void dispose() {
    rosBridge.removeWaypointListener(_waypointListener);
    rosBridge.removeSequenceListener(_sequenceListener);
    rosBridge.removeActionListener(_actionListener);
    rosBridge.removePoseListener(_poseListener);
    rosBridge.removeWorkflowStatusListener(_workflowStatusListener);
  }
  
  /// Clear pending steps (called when conversation is cancelled/reset)
  /// NOTE: Does NOT clear _pendingTask - that persists until executed or explicitly cancelled
  void clear() {
    if (_pendingSteps.isNotEmpty) {
      debugPrint('🧹 [WorkflowTools] Clearing ${_pendingSteps.length} pending steps');
      _pendingSteps.clear();
    }
    // Log but don't clear pending task - it should persist across conversation states
    if (_pendingTask != null) {
      debugPrint('📋 [WorkflowTools] Pending task preserved: ${_pendingTask!['recipient']}');
    }
    _currentRecipient = null;
  }
  
  // ===========================================================================
  // TOOL DEFINITIONS
  // ===========================================================================
  
  static List<Map<String, dynamic>> get toolDefinitions => [
    // NAVIGATION
    {
      'type': 'function',
      'function': {
        'name': 'navigate_to_waypoint',
        'description': 'Navigate to a saved location. Use when user says "go to X", "drive to X".',
        'parameters': {
          'type': 'object',
          'properties': {
            'waypoint_name': {
              'type': 'string',
              'description': 'The name of the waypoint to navigate to',
            },
          },
          'required': ['waypoint_name'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'navigate_to_position',
        'description': 'Navigate to specific map coordinates with optional heading. Use for search viewpoints suggested by get_search_status(). Set wait=true to wait for arrival before returning.',
        'parameters': {
          'type': 'object',
          'properties': {
            'x': {
              'type': 'number',
              'description': 'X coordinate in meters (map frame)',
            },
            'y': {
              'type': 'number',
              'description': 'Y coordinate in meters (map frame)',
            },
            'heading': {
              'type': 'number',
              'description': 'Optional: target heading in degrees (0 = +X axis, 90 = +Y axis)',
            },
            'wait': {
              'type': 'boolean',
              'description': 'If true, wait for navigation to complete before returning. Default: true.',
            },
          },
          'required': ['x', 'y'],
        },
      },
    },
    // DIRECT MOVEMENT
    {
      'type': 'function',
      'function': {
        'name': 'move_robot',
        'description': '''Move the robot directly. Only back up when front is blocked - camera is front-facing so backing up is blind. Match user words to directions:
- "go forward" / "back up" → forward/back
- "turn left/right" → left/right (90 degrees)
- "turn a little" / "slightly" / "small turn" → slight_left/slight_right (45 degrees)
- "turn around" → turn_around_left/turn_around_right (180 degrees)
- "spin" / "do a spin" → spin_left/spin_right (360 degrees full rotation)
- "stop" → stop''',
        'parameters': {
          'type': 'object',
          'properties': {
            'direction': {
              'type': 'string',
              'enum': ['forward', 'back', 'slight_left', 'slight_right', 'left', 'right', 'turn_around_left', 'turn_around_right', 'spin_left', 'spin_right', 'stop'],
              'description': 'Movement: forward, back, slight_left/right (45°), left/right (90°), turn_around_left/right (180°), spin_left/right (360°), stop',
            },
          },
          'required': ['direction'],
        },
      },
    },
    // VISION
    {
      'type': 'function',
      'function': {
        'name': 'look',
        'description': '''Look through the camera. Returns structured perception data.

Without search_target: General scene description.
With search_target: Focused search for specific object/feature.

Returns JSON with:
- target: what was searched for (if any)
- visible: true/false (is target visible?)
- confidence: 0.0-1.0
- possible_match: true if something similar but uncertain
- location: where in image (left/center/right, near/far)
- description: brief description of target or scene
- scene: room type and notable features (doors, furniture, openings)''',
        'parameters': {
          'type': 'object',
          'properties': {
            'search_target': {
              'type': 'string',
              'description': 'Optional: specific object to search for (e.g., "blue suitcase", "person", "doorway")',
            },
          },
          'required': [],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'get_surroundings',
        'description': 'Get LiDAR distance readings in all directions. Returns distances to obstacles: Front, Front-Left, Left, Back-Left, Back, Back-Right, Right, Front-Right. Use to check for obstacles before moving.',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    // VISUAL SEARCH
    {
      'type': 'function',
      'function': {
        'name': 'start_search',
        'description': '''Start an AUTONOMOUS visual search. The robot will:
- Wander around exploring the area on its own
- Analyze camera frames every 3 seconds looking for the target
- Track which areas have been checked
- Ask for verification when it thinks it found something

After calling this, DO NOT say "I can't find it" - the search runs automatically in the background.
You will be notified when the robot needs your input (verification) or finds the target.''',
        'parameters': {
          'type': 'object',
          'properties': {
            'target': {
              'type': 'string',
              'description': 'What to search for (e.g., "blue suitcase", "cat", "red book")',
            },
          },
          'required': ['target'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'get_search_status',
        'description': 'Check progress of the autonomous search. Returns coverage percentage and unseen areas.',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'end_search',
        'description': 'ONLY use when USER explicitly asks to stop searching (e.g., "stop looking", "never mind", "cancel search"). NEVER call this just because you haven\'t found it yet.',
        'parameters': {
          'type': 'object',
          'properties': {
            'found': {
              'type': 'boolean',
              'description': 'Whether the target was found',
            },
            'summary': {
              'type': 'string',
              'description': 'Brief summary of search result',
            },
          },
          'required': ['found'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'confirm_search_target',
        'description': 'ONLY use when USER explicitly confirms "yes", "that\'s it", "correct". NEVER call this unless the user has clearly confirmed.',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'reject_search_target',
        'description': 'ONLY use when USER explicitly says "no", "that\'s not it", "wrong one", "keep looking". Resumes autonomous search.',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    // QUERIES
    {
      'type': 'function',
      'function': {
        'name': 'get_available_waypoints',
        'description': 'Get list of saved locations. Use when user asks "where can you go?", "what locations do you know?"',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'get_robot_status',
        'description': 'Get robot status including location, current task, and whether a person is detected nearby (with distance). Use when user asks "where are you?", "can you see me?", "am I in view?", or to check if someone is nearby.',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    // HOME
    {
      'type': 'function',
      'function': {
        'name': 'go_home',
        'description': 'Navigate to home location. Use when user says "go home", "return home".',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'set_home_location',
        'description': 'Set the home location.',
        'parameters': {
          'type': 'object',
          'properties': {
            'waypoint_name': {
              'type': 'string',
              'description': 'The waypoint to set as home',
            },
          },
          'required': ['waypoint_name'],
        },
      },
    },
    // STOP
    {
      'type': 'function',
      'function': {
        'name': 'stop_robot',
        'description': 'Stop the robot immediately. Use when user says "stop", "halt", "freeze".',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    // WANDER MODE (wander only, AI stays active)
    {
      'type': 'function',
      'function': {
        'name': 'wander',
        'description': 'Start wandering/exploring without person detection. Robot moves around while you can still talk. Use when user says "wander around", "explore", "go explore".',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'stop_wandering',
        'description': 'Stop wandering. Use when user says "stop wandering", "stop exploring".',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    // GO AWAY / COME BACK
    {
      'type': 'function',
      'function': {
        'name': 'go_away',
        'description': 'Robot goes away and wanders. Saves current position to return to later. Use when user says "go away", "leave me alone".',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'come_back',
        'description': 'Robot returns to where it was when told to go away. Use when user says "come back" or "return" after being told to go away.',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    // APPROACH USER
    {
      'type': 'function',
      'function': {
        'name': 'approach_user',
        'description': 'Robot approaches the user until within 1 meter. Use when user says "come here", "come closer", "come over here", "approach me".',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    // FOLLOW USER
    {
      'type': 'function',
      'function': {
        'name': 'follow_user',
        'description': 'Robot follows the user, maintaining distance and keeping them centered. Use when user says "follow me", "come with me", "tag along".',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'stop_following',
        'description': 'Stop following the user. Use when user says "stop following", "stay here", "wait here", "don\'t follow".',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'watch_user',
        'description': 'Camera tracks and centers on the user (robot stays still). Use when user says "watch me", "keep your eyes on me", "look at me", "keep me in frame".',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'stop_watching',
        'description': 'Stop tracking the user with camera. Use when user says "stop watching", "look away", "you can look around".',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    // SHOW PAGE
    {
      'type': 'function',
      'function': {
        'name': 'show_page',
        'description': 'Show a different page/screen on the display. Use when user says "show me the dashboard", "open notes", "show schedule", "show your face", etc.',
        'parameters': {
          'type': 'object',
          'properties': {
            'page': {
              'type': 'string',
              'enum': ['face', 'dashboard', 'notes', 'schedule'],
              'description': 'The page to show: face (conversation view), dashboard (AI control center), notes, schedule',
            },
          },
          'required': ['page'],
        },
      },
    },
    // TASK CREATION (two-step: queue_task prepares, go executes)
    {
      'type': 'function',
      'function': {
        'name': 'queue_task',
        'description': 'Deliver a message to someone. If missing the message, ask only "What should I tell [name]?" - nothing more.',
        'parameters': {
          'type': 'object',
          'properties': {
            'recipient': {
              'type': 'string',
              'description': 'Name of person (matches waypoint name)',
            },
            'message': {
              'type': 'string',
              'description': 'User\'s exact words - no confirmation needed',
            },
          },
          'required': ['recipient', 'message'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'go',
        'description': 'Start the prepared task. Call this when user says "go", "go ahead", "let\'s go", or similar. Do NOT call for just "ok", "sure", "yes" without "go".',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
  ];
  
  // ===========================================================================
  // TOOL EXECUTION
  // ===========================================================================
  
  Future<ToolResult> executeTool(ToolCall toolCall) async {
    debugPrint('🧭 [WorkflowTools] Executing: ${toolCall.name}');

    switch (toolCall.name) {
      // Navigation
      case 'navigate_to_waypoint':
        return _navigateToWaypoint(toolCall.arguments);
      case 'navigate_to_position':
        return await _navigateToPosition(toolCall.arguments);

      // Direct movement
      case 'move_robot':
        return _moveRobot(toolCall.arguments);

      // Vision
      case 'look':
        return await _look(toolCall.arguments);
      case 'get_surroundings':
        return _getSurroundings();

      // Visual Search
      case 'start_search':
        return await _startSearch(toolCall.arguments);
      case 'get_search_status':
        return _getSearchStatus();
      case 'end_search':
        return _endSearch(toolCall.arguments);
      case 'confirm_search_target':
        return _confirmSearchTarget();
      case 'reject_search_target':
        return _rejectSearchTarget();

      // Queries
      case 'get_available_waypoints':
        return _getAvailableWaypoints();
      case 'get_robot_status':
        return _getRobotStatus();

      // Home
      case 'go_home':
        return _goHome();
      case 'set_home_location':
        return _setHomeLocation(toolCall.arguments);

      // Stop
      case 'stop_robot':
        return _stopRobot();

      // Wander mode (wander only, AI active)
      case 'wander':
        return _startWanderMode();
      case 'stop_wandering':
        return _stopWanderMode();

      // Go away / Come back / Approach
      case 'go_away':
        return _goAway();
      case 'come_back':
        return _comeBack();
      case 'approach_user':
        return _approachUser();
      case 'follow_user':
        return _followUser();
      case 'stop_following':
        return _stopFollowing();
      case 'watch_user':
        return _watchUser();
      case 'stop_watching':
        return _stopWatching();

      // Task creation (two-step)
      case 'queue_task':
        return _queueTask(toolCall.arguments);
      case 'go':
        return await _go();

      // Show page
      case 'show_page':
        return _showPage(toolCall.arguments);

      default:
        return ToolResult(
          success: false,
          message: 'Unknown tool: ${toolCall.name}',
        );
    }
  }
  
  // ===========================================================================
  // NAVIGATION
  // ===========================================================================
  
  ToolResult _navigateToWaypoint(Map<String, dynamic> args) {
    final name = args['waypoint_name'] as String? ?? '';

    // Find waypoint (case-insensitive)
    final waypoint = _waypoints.firstWhere(
      (w) => w.name.toLowerCase() == name.toLowerCase(),
      orElse: () => Waypoint(name: '', x: 0, y: 0),
    );

    if (waypoint.name.isEmpty) {
      final available = _waypoints.map((w) => w.name).join(', ');
      return ToolResult(
        success: false,
        message: 'Location "$name" not found. Available: $available',
      );
    }

    // Navigate directly
    rosBridge.publishGoToWaypoint(waypoint.name);
    debugPrint('🧭 [WorkflowTools] Navigating to ${waypoint.name}');

    return ToolResult(
      success: true,
      message: 'Navigating to ${waypoint.name}.',
    );
  }

  Future<ToolResult> _navigateToPosition(Map<String, dynamic> args) async {
    final x = (args['x'] as num?)?.toDouble();
    final y = (args['y'] as num?)?.toDouble();
    final headingDegrees = (args['heading'] as num?)?.toDouble();
    final wait = args['wait'] as bool? ?? true; // Default to waiting

    if (x == null || y == null) {
      return ToolResult(
        success: false,
        message: 'Missing x or y coordinates.',
      );
    }

    // Convert heading to radians if provided
    final theta = headingDegrees != null ? headingDegrees * 3.14159 / 180.0 : 0.0;

    // Navigate using Nav2
    rosBridge.publishNavGoal(x, y, theta: theta);
    debugPrint('🧭 [WorkflowTools] Navigating to position ($x, $y) heading ${headingDegrees ?? 0}°, wait=$wait');

    if (!wait) {
      // Return immediately without waiting
      return ToolResult(
        success: true,
        message: 'Navigation started to (${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})${headingDegrees != null ? ' facing ${headingDegrees.toStringAsFixed(0)}°' : ''}. Not waiting for arrival.',
      );
    }

    // Wait for navigation to complete
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

    try {
      // Wait for completion with timeout (60 seconds max for navigation)
      bool timedOut = false;
      final finalStatus = await completer.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          debugPrint('🧭 [WorkflowTools] Navigation timeout after 60 seconds');
          timedOut = true;
          return NavStatus.failed;
        },
      );

      rosBridge.removeNavStatusListener(listener);

      // Handle timeout separately so AI knows the difference
      if (timedOut) {
        return ToolResult(
          success: false,
          message: 'Navigation timed out after 60 seconds. Viewpoint (${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)}) may be unreachable or blocked.',
          data: {'status': 'timeout', 'x': x, 'y': y},
        );
      }

      switch (finalStatus) {
        case NavStatus.succeeded:
          return ToolResult(
            success: true,
            message: 'Arrived at position (${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})${headingDegrees != null ? ' facing ${headingDegrees.toStringAsFixed(0)}°' : ''}.',
            data: {'status': 'succeeded', 'x': x, 'y': y},
          );
        case NavStatus.canceled:
          return ToolResult(
            success: false,
            message: 'Navigation to (${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)}) was canceled.',
            data: {'status': 'canceled', 'x': x, 'y': y},
          );
        case NavStatus.failed:
        default:
          return ToolResult(
            success: false,
            message: 'Navigation to (${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)}) failed. Path may be blocked.',
            data: {'status': 'failed', 'x': x, 'y': y},
          );
      }
    } catch (e) {
      rosBridge.removeNavStatusListener(listener);
      return ToolResult(
        success: false,
        message: 'Navigation error: $e',
        data: {'status': 'error', 'x': x, 'y': y},
      );
    }
  }

  // ===========================================================================
  // ACTIONS
  // ===========================================================================
  
  ToolResult _executeAction(Map<String, dynamic> args) {
    final name = args['action_name'] as String? ?? '';
    
    // Find action (case-insensitive)
    final action = _actions.firstWhere(
      (a) => a.name.toLowerCase() == name.toLowerCase(),
      orElse: () => ActionDefinition(name: '', description: ''),
    );
    
    if (action.name.isEmpty) {
      final available = _actions.map((a) => a.name).join(', ');
      return ToolResult(
        success: false,
        message: 'Action "$name" not found. Available: $available',
      );
    }
    
    // Queue locally - will be sent to robot on confirm_and_execute
    _pendingSteps.add({'type': 'action', 'value': action.name});
    debugPrint('📋 [WorkflowTools] Queued: action ${action.name}');
    
    return ToolResult(
      success: true,
      message: 'Added "${action.name}" action. Call confirm_and_execute to start.',
    );
  }
  
  // ===========================================================================
  // DISPLAY
  // ===========================================================================
  
  ToolResult _showDisplay(Map<String, dynamic> args) {
    final name = args['display_name'] as String? ?? '';

    if (name.isEmpty) {
      return ToolResult(
        success: false,
        message: 'No display specified. Options: "Show Face", "Show Dashboard"',
      );
    }

    // Queue locally - will be sent to robot on confirm_and_execute
    _pendingSteps.add({'type': 'display', 'value': name});
    debugPrint('📋 [WorkflowTools] Queued: display $name');

    return ToolResult(
      success: true,
      message: 'Added display "$name". Call confirm_and_execute to start.',
    );
  }
  
  // ===========================================================================
  // SHOW PAGE
  // ===========================================================================

  ToolResult _showPage(Map<String, dynamic> args) {
    final page = args['page'] as String? ?? '';

    const validPages = ['face', 'dashboard', 'notes', 'schedule'];
    if (!validPages.contains(page)) {
      return ToolResult(
        success: false,
        message: 'Unknown page "$page". Available: ${validPages.join(", ")}',
      );
    }

    if (onShowPage != null) {
      onShowPage!(page);
      debugPrint('📺 [WorkflowTools] Showing page: $page');

      return ToolResult(
        success: true,
        message: 'Showing $page.',
      );
    }

    return ToolResult(
      success: false,
      message: 'Page navigation not available.',
    );
  }

  // ===========================================================================
  // SAVED TASKS
  // ===========================================================================
  
  ToolResult _executeSavedTask(Map<String, dynamic> args) {
    final name = args['task_name'] as String? ?? '';
    
    // Find saved task (case-insensitive)
    final task = _sequences.firstWhere(
      (t) => t.name.toLowerCase() == name.toLowerCase(),
      orElse: () => SavedSequence(name: '', waypointNames: []),
    );
    
    if (task.name.isEmpty || task.waypointNames.isEmpty) {
      final available = _sequences.map((t) => t.name).join(', ');
      return ToolResult(
        success: false,
        message: 'Task "$name" not found. Available Tasks: $available',
      );
    }
    
    // Convert saved task steps to workflow
    // Each step could be a waypoint name, action name, or display name
    final steps = <Map<String, String>>[];
    for (final stepName in task.waypointNames) {
      // Check if it's a waypoint
      final isWaypoint = _waypoints.any((w) => w.name == stepName);
      if (isWaypoint) {
        steps.add({'type': 'navigate', 'value': stepName});
        continue;
      }
      
      // Check if it's an action
      final isAction = _actions.any((a) => a.name == stepName);
      if (isAction) {
        steps.add({'type': 'action', 'value': stepName});
        continue;
      }
      
      // Otherwise treat as display
      steps.add({'type': 'display', 'value': stepName});
    }
    
    // Queue locally - will be sent to robot on confirm_and_execute
    _pendingSteps.addAll(steps);
    debugPrint('📋 [WorkflowTools] Queued task "${task.name}" with ${steps.length} steps');
    
    return ToolResult(
      success: true,
      message: 'Added Task "${task.name}" with ${steps.length} steps. Call confirm_and_execute to start.',
    );
  }
  
  // ===========================================================================
  // CONFIRM AND EXECUTE
  // ===========================================================================
  
  /// Execute workflow immediately - no confirmation needed
  ToolResult _executeNow(Map<String, dynamic> args) {
    final stepsArg = args['steps'];
    if (stepsArg == null || stepsArg is! List || stepsArg.isEmpty) {
      return ToolResult(
        success: false,
        message: 'No steps provided.',
      );
    }
    
    final steps = <Map<String, String>>[];
    for (final step in stepsArg) {
      if (step is Map) {
        final type = step['type'] as String? ?? '';
        final value = step['value'] as String? ?? '';
        
        if (type.isNotEmpty && value.isNotEmpty) {
          // Validate the step
          if (type == 'navigate') {
            final wp = _waypoints.firstWhere(
              (w) => w.name.toLowerCase() == value.toLowerCase(),
              orElse: () => Waypoint(name: '', x: 0, y: 0),
            );
            if (wp.name.isEmpty) {
              return ToolResult(
                success: false,
                message: 'Unknown location: $value. Available: ${_waypoints.map((w) => w.name).join(", ")}',
              );
            }
            steps.add({'type': 'navigate', 'value': wp.name});
          } else if (type == 'action') {
            final action = _actions.firstWhere(
              (a) => a.name.toLowerCase() == value.toLowerCase(),
              orElse: () => ActionDefinition(name: '', description: ''),
            );
            if (action.name.isEmpty) {
              return ToolResult(
                success: false,
                message: 'Unknown action: $value. Available: ${_actions.map((a) => a.name).join(", ")}',
              );
            }
            steps.add({'type': 'action', 'value': action.name});
          } else if (type == 'display' || type == 'speak') {
            steps.add({'type': type, 'value': value});
          }
        }
      }
    }
    
    if (steps.isEmpty) {
      return ToolResult(
        success: false,
        message: 'No valid steps to execute.',
      );
    }
    
    debugPrint('🚀 [WorkflowTools] EXECUTE NOW: ${steps.length} steps');
    
    // Send directly to robot - starts immediately
    rosBridge.publishWorkflow(steps, source: 'robot');
    
    // Trigger the callback to end the conversation immediately
    onWorkflowConfirmed?.call();
    
    return ToolResult(
      success: true,
      message: 'Executing ${steps.length} steps.',
    );
  }
  
  ToolResult _confirmAndExecute(Map<String, dynamic> args) {
    final summary = args['summary'] as String? ?? 'Executing workflow';
    
    if (_pendingSteps.isEmpty) {
      return ToolResult(
        success: false,
        message: 'No steps queued. Use execute_now instead.',
      );
    }
    
    debugPrint('✅ [WorkflowTools] Confirming workflow: $summary');
    debugPrint('📤 [WorkflowTools] Sending ${_pendingSteps.length} steps to robot');
    
    // Send all queued steps to the robot - this starts the workflow
    rosBridge.publishWorkflow(_pendingSteps, source: 'robot');
    
    // Clear the pending queue
    _pendingSteps.clear();
    
    // Trigger the callback to end the conversation immediately
    onWorkflowConfirmed?.call();
    
    return ToolResult(
      success: true,
      message: summary,
    );
  }
  
  // ===========================================================================
  // WORKFLOW BUILDING
  // ===========================================================================
  
  ToolResult _addWorkflowSteps(Map<String, dynamic> args) {
    final stepsArg = args['steps'];
    if (stepsArg == null || stepsArg is! List) {
      return ToolResult(
        success: false,
        message: 'No steps provided.',
      );
    }
    
    final steps = <Map<String, String>>[];
    for (final step in stepsArg) {
      if (step is Map) {
        final type = step['type'] as String? ?? '';
        final value = step['value'] as String? ?? '';
        
        if (type.isNotEmpty && value.isNotEmpty) {
          // Validate the step
          if (type == 'navigate') {
            final wp = _waypoints.firstWhere(
              (w) => w.name.toLowerCase() == value.toLowerCase(),
              orElse: () => Waypoint(name: '', x: 0, y: 0),
            );
            if (wp.name.isEmpty) {
              return ToolResult(
                success: false,
                message: 'Unknown waypoint: $value',
              );
            }
            steps.add({'type': 'navigate', 'value': wp.name});
          } else if (type == 'action') {
            final action = _actions.firstWhere(
              (a) => a.name.toLowerCase() == value.toLowerCase(),
              orElse: () => ActionDefinition(name: '', description: ''),
            );
            if (action.name.isEmpty) {
              return ToolResult(
                success: false,
                message: 'Unknown action: $value',
              );
            }
            steps.add({'type': 'action', 'value': action.name});
          } else if (type == 'display' || type == 'speak') {
            steps.add({'type': type, 'value': value});
          }
        }
      }
    }
    
    if (steps.isEmpty) {
      return ToolResult(
        success: false,
        message: 'No valid steps to add.',
      );
    }
    
    // Queue locally - will be sent to robot on confirm_and_execute
    _pendingSteps.addAll(steps);
    debugPrint('📋 [WorkflowTools] Queued ${steps.length} steps');
    
    final summary = steps.map((s) => '${s['type']}: ${s['value']}').join(', ');
    return ToolResult(
      success: true,
      message: 'Added ${steps.length} steps: $summary. Call confirm_and_execute to start.',
    );
  }
  
  // ===========================================================================
  // WORKFLOW CONTROL
  // ===========================================================================
  
  ToolResult _pauseWorkflow() {
    rosBridge.publishWorkflowPause();
    return ToolResult(
      success: true,
      message: 'Workflow paused. Say "resume" to continue.',
    );
  }
  
  ToolResult _resumeWorkflow() {
    rosBridge.publishWorkflowResume();
    return ToolResult(
      success: true,
      message: 'Resuming workflow.',
    );
  }
  
  ToolResult _stopWorkflow() {
    rosBridge.publishWorkflowCancel();
    return ToolResult(
      success: true,
      message: 'Workflow stopped.',
    );
  }
  
  ToolResult _clearWorkflow() {
    rosBridge.publishWorkflowClear();
    return ToolResult(
      success: true,
      message: 'Workflow cleared. Ready for new commands.',
    );
  }

  // ===========================================================================
  // DIRECT MOVEMENT
  // ===========================================================================

  ToolResult _moveRobot(Map<String, dynamic> args) {
    final direction = args['direction'] as String? ?? '';

    const validDirections = [
      'forward', 'back',
      'slight_left', 'slight_right',
      'left', 'right',
      'turn_around_left', 'turn_around_right',
      'spin_left', 'spin_right',
      'stop'
    ];
    if (!validDirections.contains(direction)) {
      return ToolResult(
        success: false,
        message: 'Invalid direction "$direction". Use: ${validDirections.join(", ")}',
      );
    }

    rosBridge.publishMove(direction);
    debugPrint('🚗 [WorkflowTools] Moving: $direction');

    // Friendly response based on direction
    final responses = {
      'forward': 'Moving forward.',
      'back': 'Backing up.',
      'slight_left': 'Turning slightly left.',
      'slight_right': 'Turning slightly right.',
      'left': 'Turning left.',
      'right': 'Turning right.',
      'turn_around_left': 'Turning around.',
      'turn_around_right': 'Turning around.',
      'spin_left': 'Doing a spin!',
      'spin_right': 'Doing a spin!',
      'stop': 'Stopping.',
    };

    return ToolResult(
      success: true,
      message: responses[direction] ?? 'Moving $direction.',
    );
  }

  // ===========================================================================
  // VISION
  // ===========================================================================

  /// Look through the camera - returns structured perception data
  /// If search_target is provided, focuses on finding that specific object
  Future<ToolResult> _look(Map<String, dynamic> args) async {
    final searchTarget = args['search_target'] as String?;

    // Capture pose at observation time
    final observationPose = _pose;
    final headingDegrees = observationPose != null
        ? observationPose.theta * 180.0 / 3.14159
        : 0.0;

    if (_apiKey == null || _apiKey!.isEmpty) {
      // Try loading from cache
      final key = await LocalCacheService.loadOpenAIApiKey();
      if (key != null && key.isNotEmpty) {
        _apiKey = key;
      } else {
        return ToolResult(
          success: false,
          message: 'Vision not available - no API key configured.',
        );
      }
    }

    try {
      // Capture camera frame
      final imageResponse = await http.get(Uri.parse(_cameraSnapshotUrl))
          .timeout(const Duration(seconds: 3));

      if (imageResponse.statusCode != 200) {
        return ToolResult(
          success: false,
          message: 'Camera unavailable.',
        );
      }

      final imageBytes = imageResponse.bodyBytes;
      final base64Image = base64Encode(imageBytes);

      // Build prompt based on whether we're searching for something specific
      String systemPrompt;
      String userPrompt;

      if (searchTarget != null && searchTarget.isNotEmpty) {
        // Target-aware search mode
        systemPrompt = '''You are a robot's visual perception system. Your job is ONLY to report what you see - not to suggest actions.

Analyze the image and respond with ONLY a JSON object (no markdown, no explanation):
{
  "target": "<the search target>",
  "visible": true/false,
  "confidence": 0.0-1.0,
  "possible_match": true/false (something similar but uncertain),
  "location": "left/center/right of image, near/mid/far" (only if visible or possible_match),
  "description": "brief description of the target if found, or why you're uncertain",
  "scene": "room type and notable features: doors, openings, furniture, obstacles"
}

Be precise about confidence:
- 0.9+ = clearly visible and identifiable
- 0.7-0.9 = likely match but partially obscured or at angle
- 0.5-0.7 = possible match, uncertain
- <0.5 = probably not the target

Always describe the scene context even if target not found.''';
        userPrompt = 'Search for: $searchTarget';
      } else {
        // General observation mode
        systemPrompt = '''You are a robot's visual perception system. Analyze the image and respond with ONLY a JSON object (no markdown, no explanation):
{
  "target": null,
  "visible": false,
  "confidence": 0.0,
  "possible_match": false,
  "location": null,
  "description": "brief description of what you see",
  "scene": "room type and notable features: doors, openings, furniture, people, obstacles, colors"
}

Focus on: room layout, doorways/openings, obstacles, people, notable objects, spatial features.''';
        userPrompt = 'Describe what you see.';
      }

      // Call GPT-4o-mini vision
      final response = await http.post(
        Uri.parse(_visionApiUrl),
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': _visionModel,
          'messages': [
            {
              'role': 'system',
              'content': systemPrompt,
            },
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': userPrompt},
                {
                  'type': 'image_url',
                  'image_url': {
                    'url': 'data:image/jpeg;base64,$base64Image',
                    'detail': 'high',
                  },
                },
              ],
            },
          ],
          'max_tokens': 250,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return ToolResult(
          success: false,
          message: 'Vision API error: ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body);
      final rawContent = data['choices']?[0]?['message']?['content'] as String? ?? '{}';

      // Clean up the response (remove markdown code blocks if present)
      String jsonContent = rawContent.trim();
      if (jsonContent.startsWith('```')) {
        jsonContent = jsonContent.replaceAll(RegExp(r'^```json?\n?'), '').replaceAll(RegExp(r'\n?```$'), '');
      }

      debugPrint('👁️ [WorkflowTools] Vision response: $jsonContent');

      // Parse and validate the JSON
      try {
        final parsed = jsonDecode(jsonContent) as Map<String, dynamic>;

        // Ensure all expected fields exist
        final result = {
          'target': parsed['target'] ?? searchTarget,
          'visible': parsed['visible'] ?? false,
          'confidence': parsed['confidence'] ?? 0.0,
          'possible_match': parsed['possible_match'] ?? false,
          'location': parsed['location'],
          'description': parsed['description'] ?? 'No description',
          'scene': parsed['scene'] ?? 'Unknown scene',
        };

        // Add pose to result
        if (observationPose != null) {
          result['pose'] = {
            'x': observationPose.x,
            'y': observationPose.y,
            'heading': headingDegrees,
          };
        }

        // Log for debugging
        if (searchTarget != null) {
          final visible = result['visible'] as bool;
          final confidence = result['confidence'];
          debugPrint('👁️ [WorkflowTools] Search "$searchTarget": visible=$visible, confidence=$confidence');
        }

        // Record observation in active search session
        if (_searchSession != null && observationPose != null) {
          final observation = VisualObservation(
            timestamp: DateTime.now(),
            x: observationPose.x,
            y: observationPose.y,
            headingDegrees: headingDegrees,
            searchTarget: searchTarget ?? _searchSession!.target,
            targetVisible: result['visible'] as bool? ?? false,
            confidence: (result['confidence'] as num?)?.toDouble() ?? 0.0,
            targetLocation: result['location'] as String?,
            possibleMatch: result['possible_match'] as bool? ?? false,
            scene: result['scene'] as String? ?? '',
            description: result['description'] as String? ?? '',
          );
          _searchSession!.recordObservation(observation);
          debugPrint('👁️ [WorkflowTools] Recorded observation at (${observationPose.x.toStringAsFixed(1)}, ${observationPose.y.toStringAsFixed(1)}) heading ${headingDegrees.toStringAsFixed(0)}°');
          debugPrint('👁️ [WorkflowTools] Coverage now: ${_searchSession!.coverage?.getCoveragePercent().toStringAsFixed(1)}%');
        }

        return ToolResult(
          success: true,
          message: jsonEncode(result),
          data: result,
        );
      } catch (parseError) {
        // If JSON parsing fails, return raw content wrapped in structure
        debugPrint('👁️ [WorkflowTools] JSON parse error, returning raw: $parseError');
        return ToolResult(
          success: true,
          message: jsonContent,
        );
      }
    } catch (e) {
      debugPrint('👁️ [WorkflowTools] Vision error: $e');
      return ToolResult(
        success: false,
        message: 'Vision error: $e',
      );
    }
  }

  /// Get LiDAR surroundings summary
  ToolResult _getSurroundings() {
    if (_currentScan == null) {
      return ToolResult(
        success: false,
        message: 'LiDAR data not available.',
      );
    }

    final scan = _currentScan!;
    final buffer = StringBuffer('Distances to obstacles:\n');

    // 8 sectors, 45 degrees each
    final sectors = {
      'Front': [-22.5, 22.5],
      'Front-Right': [22.5, 67.5],
      'Right': [67.5, 112.5],
      'Back-Right': [112.5, 157.5],
      'Back': [157.5, -157.5],
      'Back-Left': [-157.5, -112.5],
      'Left': [-112.5, -67.5],
      'Front-Left': [-67.5, -22.5],
    };

    for (final entry in sectors.entries) {
      final minDist = _getMinDistanceInSector(scan, entry.value[0], entry.value[1]);
      if (minDist == null || minDist > 10.0) {
        buffer.writeln('- ${entry.key}: clear (>10m)');
      } else if (minDist < 0.5) {
        buffer.writeln('- ${entry.key}: BLOCKED (${minDist.toStringAsFixed(1)}m)');
      } else if (minDist < 1.0) {
        buffer.writeln('- ${entry.key}: close (${minDist.toStringAsFixed(1)}m)');
      } else {
        buffer.writeln('- ${entry.key}: ${minDist.toStringAsFixed(1)}m');
      }
    }

    return ToolResult(
      success: true,
      message: buffer.toString(),
    );
  }

  /// Get minimum distance in a LiDAR sector
  double? _getMinDistanceInSector(LaserScan scan, double startAngleDeg, double endAngleDeg) {
    final startAngle = startAngleDeg * 3.14159 / 180.0;
    final endAngle = endAngleDeg * 3.14159 / 180.0;

    double? minDistance;

    for (int i = 0; i < scan.ranges.length; i++) {
      final angle = scan.angleMin + (i * scan.angleIncrement);

      bool inSector;
      if (startAngleDeg > endAngleDeg) {
        // Wraps around (e.g., 157.5 to -157.5 for Back)
        inSector = angle >= startAngle || angle <= endAngle;
      } else {
        inSector = angle >= startAngle && angle <= endAngle;
      }

      if (inSector) {
        final range = scan.ranges[i];
        if (range > 0.1 && range < 10.0) {
          if (minDistance == null || range < minDistance) {
            minDistance = range;
          }
        }
      }
    }

    return minDistance;
  }

  // ===========================================================================
  // VISUAL SEARCH
  // ===========================================================================

  /// Start a visual search session for a specific target
  Future<ToolResult> _startSearch(Map<String, dynamic> args) async {
    debugPrint('🔍 [WorkflowTools] *** start_search TOOL CALLED *** args=$args');

    final target = args['target'] as String?;
    if (target == null || target.isEmpty) {
      debugPrint('🔍 [WorkflowTools] ⚠️ No target specified');
      return ToolResult(
        success: false,
        message: 'No search target specified.',
      );
    }

    debugPrint('🔍 [WorkflowTools] Target: "$target"');

    // Use planned search service (Nav2 navigation + GPT vision analysis)
    if (plannedSearchService == null) {
      debugPrint('🔍 [WorkflowTools] ⚠️ Planned search service not available');
      return ToolResult(
        success: false,
        message: 'Search service not initialized. Try again in a moment.',
      );
    }

    // Remember if wander was active (to resume after search)
    _wanderActiveBeforeSearch = _wanderActive;

    // Pause wander if active - search takes over navigation
    if (_wanderActive) {
      debugPrint('🔍 [WorkflowTools] Pausing wander mode for search');
      rosBridge.deactivateWanderMode();
      // Brief delay to let wander stop
      await Future.delayed(const Duration(milliseconds: 200));
    }

    // Try to start the search - it returns an error message if it fails
    final error = await plannedSearchService!.startSearch(target);

    if (error != null) {
      debugPrint('🔍 [WorkflowTools] Search failed to start: $error');
      return ToolResult(
        success: false,
        message: 'Could not start search: $error',
      );
    }

    debugPrint('🔍 [WorkflowTools] Started planned search for: $target');
    return ToolResult(
      success: true,
      message: 'Search started. I\'m looking for "$target". I\'ll let you know when I find something.',
      data: {
        'target': target,
        'search_active': true,
      },
    );
  }

  /// Get current visual search status
  ToolResult _getSearchStatus() {
    if (plannedSearchService == null || !plannedSearchService!.isSearching) {
      return ToolResult(
        success: false,
        message: 'No active search.',
      );
    }

    final progress = plannedSearchService!.searchProgress;
    final buffer = StringBuffer();
    buffer.writeln('Search target: ${progress['target']}');
    buffer.writeln('Coverage: ${progress['coverage_percent']}%');
    buffer.writeln('Observations: ${progress['observations_count']}');

    if (progress['pending_verification'] == true) {
      buffer.writeln('Status: AWAITING YOUR VERIFICATION');
    } else if (progress['is_paused'] == true) {
      buffer.writeln('Status: Paused');
    } else {
      buffer.writeln('Status: Searching...');
    }

    return ToolResult(
      success: true,
      message: buffer.toString(),
      data: progress,
    );
  }

  /// End the current visual search session
  ToolResult _endSearch(Map<String, dynamic> args) {
    if (plannedSearchService == null || !plannedSearchService!.isSearching) {
      return ToolResult(
        success: false,
        message: 'No active search to end.',
      );
    }

    final coverage = plannedSearchService!.coveragePercent;
    final observations = plannedSearchService!.observations.length;

    plannedSearchService!.stopSearch();
    debugPrint('🔍 [WorkflowTools] Search stopped by user');

    // Resume wander if it was active before search
    _resumeWanderIfNeeded();

    return ToolResult(
      success: true,
      message: 'Search stopped. Checked ${coverage.toStringAsFixed(0)}% of area with $observations observations.',
    );
  }

  /// User confirms the detected object IS the search target
  ToolResult _confirmSearchTarget() {
    if (plannedSearchService == null) {
      return ToolResult(
        success: false,
        message: 'Search service not available.',
      );
    }

    if (!plannedSearchService!.pendingVerification) {
      return ToolResult(
        success: false,
        message: 'No pending detection to confirm.',
      );
    }

    plannedSearchService!.confirmTarget();
    debugPrint('✅ [WorkflowTools] User confirmed search target');

    // Resume wander if it was active before search
    _resumeWanderIfNeeded();

    return ToolResult(
      success: true,
      message: 'Target confirmed! Search complete.',
    );
  }

  /// User rejects the detected object - resume searching
  ToolResult _rejectSearchTarget() {
    if (plannedSearchService == null) {
      return ToolResult(
        success: false,
        message: 'Search service not available.',
      );
    }

    if (!plannedSearchService!.pendingVerification) {
      return ToolResult(
        success: false,
        message: 'No pending detection to reject.',
      );
    }

    plannedSearchService!.rejectTarget();
    debugPrint('❌ [WorkflowTools] User rejected detection - resuming search');

    return ToolResult(
      success: true,
      message: 'Got it, that\'s not it. Continuing to search...',
    );
  }

  /// Resume wander mode if it was active before search started
  void _resumeWanderIfNeeded() {
    if (_wanderActiveBeforeSearch) {
      debugPrint('🔍 [WorkflowTools] Resuming wander mode after search');
      if (onWanderModeStart != null) {
        onWanderModeStart!();
      } else {
        rosBridge.activateWanderMode();
      }
      _wanderActiveBeforeSearch = false;
    }
  }

  /// Public method to resume wander after search (called by PlannedSearchService callback)
  void resumeWanderAfterSearch() {
    _resumeWanderIfNeeded();
  }

  // ===========================================================================
  // QUERIES
  // ===========================================================================
  
  ToolResult _getAvailableWaypoints() {
    if (_waypoints.isEmpty) {
      return ToolResult(
        success: true,
        message: 'No waypoints saved yet.',
      );
    }
    
    final names = _waypoints.map((w) => w.name).join(', ');
    return ToolResult(
      success: true,
      message: 'Available locations: $names',
    );
  }
  
  ToolResult _getAvailableActions() {
    if (_actions.isEmpty) {
      return ToolResult(
        success: true,
        message: 'No actions configured yet.',
      );
    }
    
    final names = _actions.map((a) => a.name).join(', ');
    return ToolResult(
      success: true,
      message: 'Available actions: $names',
    );
  }
  
  ToolResult _getSavedTasks() {
    if (_sequences.isEmpty) {
      return ToolResult(
        success: true,
        message: 'No saved Tasks yet. Tasks can be created in the Task Manager.',
      );
    }
    
    final descriptions = _sequences
        .map((t) => '${t.name} (${t.waypointNames.length} steps)')
        .join(', ');
    return ToolResult(
      success: true,
      message: 'Saved Tasks: $descriptions',
    );
  }
  
  ToolResult _getRobotStatus() {
    final buffer = StringBuffer();
    
    // Location
    if (_pose != null) {
      String nearestWaypoint = 'unknown';
      double minDist = double.infinity;
      
      for (final wp in _waypoints) {
        final dx = wp.x - _pose!.x;
        final dy = wp.y - _pose!.y;
        final dist = dx * dx + dy * dy;
        if (dist < minDist) {
          minDist = dist;
          nearestWaypoint = wp.name;
        }
      }
      
      final distStr = minDist < 0.5 ? 'at' : '${(minDist).toStringAsFixed(1)}m from';
      buffer.write('Location: $distStr $nearestWaypoint. ');
    } else {
      buffer.write('Location: unknown. ');
    }
    
    // Workflow state
    buffer.write('State: $_workflowState');
    if (_totalSteps > 0) {
      buffer.write(' (step $_currentStep/$_totalSteps)');
    }
    buffer.write('. ');

    // Following mode
    if (_followingActive) {
      buffer.write('Following mode: $_followingStatus. ');
    }

    // Person detection
    if (_personDetected) {
      final distStr = _personDistance != null
          ? '${_personDistance!.toStringAsFixed(1)}m away'
          : 'nearby';
      buffer.write('Person detected $distStr');
      if (_personCentered) {
        buffer.write(' (centered in view)');
      }
      buffer.write('.');
    } else {
      buffer.write('No person detected.');
    }

    return ToolResult(
      success: true,
      message: buffer.toString(),
    );
  }
  
  // ===========================================================================
  // HOME LOCATION
  // ===========================================================================
  
  ToolResult _goHome() {
    // First check for waypoint marked as default (isDefault = true)
    final defaultWaypoint = _waypoints.where((w) => w.isDefault).firstOrNull;

    if (defaultWaypoint != null) {
      rosBridge.publishGoToWaypoint(defaultWaypoint.name);
      debugPrint('🏠 [WorkflowTools] Navigating home to ${defaultWaypoint.name}');
      return ToolResult(
        success: true,
        message: 'Navigating home to ${defaultWaypoint.name}.',
      );
    }

    // Fallback: check for manually set home
    if (_defaultHome != null && _defaultHome!.isNotEmpty) {
      rosBridge.publishGoToWaypoint(_defaultHome!);
      debugPrint('🏠 [WorkflowTools] Navigating home to $_defaultHome');
      return ToolResult(
        success: true,
        message: 'Navigating home to $_defaultHome.',
      );
    }

    // Last fallback: look for waypoint with "home", "charging", or "base" in name
    final homeWp = _waypoints.firstWhere(
      (w) => w.name.toLowerCase().contains('home') ||
             w.name.toLowerCase().contains('charging') ||
             w.name.toLowerCase().contains('base'),
      orElse: () => Waypoint(name: '', x: 0, y: 0),
    );

    if (homeWp.name.isEmpty) {
      return ToolResult(
        success: false,
        message: 'No home location set.',
      );
    }

    rosBridge.publishGoToWaypoint(homeWp.name);
    debugPrint('🏠 [WorkflowTools] Navigating home to ${homeWp.name}');
    return ToolResult(
      success: true,
      message: 'Navigating home to ${homeWp.name}.',
    );
  }

  ToolResult _stopRobot() {
    // Full stop: disable ALL modes (wander, follow, track), cancel nav, zero velocity
    rosBridge.deactivateAllModes();  // Stops wander, follow, AND track
    rosBridge.publishEstop();         // Cancel nav, zero velocity, pause mode
    rosBridge.publishWorkflowCancel();
    debugPrint('🛑 [WorkflowTools] Stop command - full stop');

    // Clear any stale error state and notify controller
    _workflowState = 'idle';
    rosBridge.publishWorkflowIdle();

    return ToolResult(
      success: true,
      message: 'Stopped.',
    );
  }

  // ===========================================================================
  // WANDER MODE (wander only, AI stays active and robot keeps moving while talking)
  // ===========================================================================

  ToolResult _startWanderMode() {
    debugPrint('🚶 [WorkflowTools] Starting wander mode (wander only)');

    // Use callback if available (conversation_service handles mode coordination)
    if (onWanderModeStart != null) {
      onWanderModeStart!();
    } else {
      // Fallback: direct rosbridge call
      rosBridge.activateWanderMode();
    }

    // Speak only if in ready/idle state (not during conversation)
    onSpeakIfIdle?.call('Wandering mode activated.');

    return ToolResult(
      success: true,
      message: 'Wandering mode activated.',
    );
  }

  ToolResult _stopWanderMode() {
    debugPrint('🛑 [WorkflowTools] Stopping wander mode');

    // Always disable wander directly
    rosBridge.deactivateWanderMode();

    // Also notify conversation service if callback is set
    onWanderModeStop?.call();

    // Clear any stale error state and notify controller
    _workflowState = 'idle';
    rosBridge.publishWorkflowIdle();

    return ToolResult(
      success: true,
      message: 'Stopped wandering.',
    );
  }

  // ===========================================================================
  // GO AWAY / COME BACK
  // ===========================================================================

  ToolResult _goAway() {
    // Save current position
    if (_pose != null) {
      _goAwayPose = _pose;
      debugPrint('👋 [WorkflowTools] Saved position: (${_pose!.x}, ${_pose!.y})');
    }

    // Trigger Wander Mode via callback
    if (onGoAwayRequested != null) {
      debugPrint('👋 [WorkflowTools] Go away - triggering wander mode');
      onGoAwayRequested!();
    } else {
      // Fallback: activate wander mode directly
      rosBridge.activateWanderMode();
      debugPrint('👋 [WorkflowTools] Go away - wander mode enabled (fallback)');
    }

    return ToolResult(
      success: true,
      message: 'Going away. Say "come back" when you want me to return.',
    );
  }

  ToolResult _comeBack() {
    // Deactivate all modes (wander/follow)
    rosBridge.deactivateAllModes();

    // Clear any stale error state and notify controller
    _workflowState = 'idle';
    rosBridge.publishWorkflowIdle();

    // Navigate back to saved position
    if (_goAwayPose != null) {
      rosBridge.publishNavGoal(_goAwayPose!.x, _goAwayPose!.y, theta: _goAwayPose!.theta);
      debugPrint('🔙 [WorkflowTools] Coming back to (${_goAwayPose!.x}, ${_goAwayPose!.y})');
      return ToolResult(
        success: true,
        message: 'Coming back to you.',
      );
    }

    return ToolResult(
      success: false,
      message: 'I don\'t know where to go back to.',
    );
  }

  ToolResult _approachUser() {
    // Trigger approach via callback (conversation_service will handle distance monitoring)
    if (onApproachUserRequested != null) {
      debugPrint('🚶 [WorkflowTools] Approach user requested');
      onApproachUserRequested!();
      return ToolResult(
        success: true,
        message: 'Approaching you.',
      );
    }

    // Fallback: just enable person follower directly
    rosBridge.publishPersonFollowerEnable();
    debugPrint('🚶 [WorkflowTools] Approach user - person follower enabled (fallback)');
    return ToolResult(
      success: true,
      message: 'Approaching you.',
    );
  }

  ToolResult _followUser() {
    // Use centralized mode control (stops all other modes automatically)
    rosBridge.activateFollowMode();
    debugPrint('🚶 [WorkflowTools] Follow user - activateFollowMode called');

    // Speak only if in ready/idle state (not during conversation)
    onSpeakIfIdle?.call('Following mode activated.');

    return ToolResult(
      success: true,
      message: 'Following mode activated.',
    );
  }

  ToolResult _stopFollowing() {
    rosBridge.deactivateFollowMode();
    debugPrint('🛑 [WorkflowTools] Stop following - deactivateFollowMode called');

    // Clear any stale error state and notify controller
    _workflowState = 'idle';
    rosBridge.publishWorkflowIdle();

    return ToolResult(
      success: true,
      message: 'Stopped following.',
    );
  }

  ToolResult _watchUser() {
    // Use centralized mode control (stops all other modes automatically)
    rosBridge.activateTrackMode();
    debugPrint('👁️ [WorkflowTools] Watch user - activateTrackMode called');

    // Speak only if in ready/idle state (not during conversation)
    onSpeakIfIdle?.call('Tracking mode activated.');

    return ToolResult(
      success: true,
      message: 'Tracking mode activated.',
    );
  }

  ToolResult _stopWatching() {
    rosBridge.deactivateTrackMode();
    debugPrint('🛑 [WorkflowTools] Stop watching - deactivateTrackMode called');

    // Clear any stale error state and notify controller
    _workflowState = 'idle';
    rosBridge.publishWorkflowIdle();

    return ToolResult(
      success: true,
      message: 'Stopped watching.',
    );
  }

  // ===========================================================================
  // TASK CREATION
  // ===========================================================================

  /// Find nearest waypoint to current position
  String? _getNearestWaypoint() {
    if (_pose == null || _waypoints.isEmpty) return null;

    String? nearest;
    double minDist = double.infinity;

    for (final wp in _waypoints) {
      final dx = wp.x - _pose!.x;
      final dy = wp.y - _pose!.y;
      final dist = dx * dx + dy * dy;
      if (dist < minDist) {
        minDist = dist;
        nearest = wp.name;
      }
    }

    return nearest;
  }

  /// Find waypoint by name with fuzzy matching
  /// Matches: exact name, or waypoint containing the search term
  /// e.g., "Julie" matches "Julie's desk", "julie's office", etc.
  Waypoint? _findWaypoint(String name) {
    final searchLower = name.toLowerCase();

    // Try exact match first
    for (final wp in _waypoints) {
      if (wp.name.toLowerCase() == searchLower) {
        return wp;
      }
    }

    // Try contains match (e.g., "Julie" matches "Julie's desk")
    for (final wp in _waypoints) {
      if (wp.name.toLowerCase().contains(searchLower)) {
        return wp;
      }
    }

    // Try if search contains waypoint name (e.g., "Julie's desk" matches "Julie")
    for (final wp in _waypoints) {
      if (searchLower.contains(wp.name.toLowerCase())) {
        return wp;
      }
    }

    return null;
  }

  // Track recipient name for report back (e.g., "Julie said...")
  String? _currentRecipient;

  /// Prepare a dynamic task (does NOT execute - call go() to start)
  ToolResult _queueTask(Map<String, dynamic> args) {
    final recipient = args['recipient'] as String? ?? '';
    final message = args['message'] as String? ?? '';

    if (recipient.isEmpty) {
      return ToolResult(
        success: false,
        message: 'No recipient specified. Who should I talk to?',
      );
    }

    if (message.isEmpty) {
      return ToolResult(
        success: false,
        message: 'No message specified. What should I tell them?',
      );
    }

    // Find recipient's location (supports fuzzy matching)
    final waypoint = _findWaypoint(recipient);

    if (waypoint == null) {
      final available = _waypoints.map((w) => w.name).join(', ');
      return ToolResult(
        success: false,
        message: 'I don\'t know where to find "$recipient". Available locations: $available',
      );
    }

    // Build greeting
    final greeting = 'Hi $recipient! $message';

    // Store pending task (will be executed when go() is called)
    _pendingTask = {
      'recipient': recipient,
      'message': message,
      'waypoint': waypoint,
      'greeting': greeting,
    };

    debugPrint('📋 [WorkflowTools] Task prepared: $recipient -> "$message"');

    // Minimal response - AI should just confirm briefly
    return ToolResult(
      success: true,
      message: 'Ready. Say go.',
    );
  }

  /// Execute the prepared task (called after user confirms)
  Future<ToolResult> _go() async {
    debugPrint('🚀 [WorkflowTools] go() called - pendingTask: ${_pendingTask != null ? "exists" : "NULL"}');

    if (_pendingTask == null) {
      debugPrint('❌ [WorkflowTools] go() failed - no pending task!');
      return ToolResult(
        success: false,
        message: 'No task prepared. Use queue_task first.',
      );
    }

    debugPrint('✅ [WorkflowTools] go() executing for: ${_pendingTask!['recipient']}');
    final recipient = _pendingTask!['recipient'] as String;
    final waypoint = _pendingTask!['waypoint'] as Waypoint;
    final greeting = _pendingTask!['greeting'] as String;
    final message = _pendingTask!['message'] as String;

    // Track recipient for context
    _currentRecipient = recipient;

    debugPrint('🚀 [WorkflowTools] Executing task: $recipient');

    // Create action for the conversation at destination
    // No recipientName - we skip the "Are you X?" confirmation
    final tempAction = ActionDefinition(
      name: 'Message for $recipient',
      description: message,
      openingGreeting: greeting,
      source: 'robot',
    );

    // Build workflow steps: navigate then action
    final steps = <Map<String, String>>[
      {'type': 'navigate', 'value': waypoint.name},
      {'type': 'action', 'value': tempAction.name},
    ];

    // Save temp action to ROS2 so workflow executor can find it
    rosBridge.publishSaveAction(tempAction);

    // Notify conversation service about the temp task
    onTempTaskQueued?.call(tempAction, null);

    // Small delay to ensure action is saved before workflow starts
    await Future.delayed(const Duration(milliseconds: 100));

    // Send workflow to robot
    rosBridge.publishWorkflow(steps, source: 'robot');

    // Clear pending task
    _pendingTask = null;

    // Notify conversation service to pause and prepare for task
    // When action executes, it will speak greeting and resume normal conversation
    onTaskStart?.call(waypoint.name, greeting);

    return ToolResult(
      success: true,
      message: 'On my way.',
    );
  }


  ToolResult _setHomeLocation(Map<String, dynamic> args) {
    final name = args['waypoint_name'] as String? ?? '';
    final autoReturn = args['auto_return'] as bool? ?? false;
    
    // Find waypoint
    final waypoint = _waypoints.firstWhere(
      (w) => w.name.toLowerCase() == name.toLowerCase(),
      orElse: () => Waypoint(name: '', x: 0, y: 0),
    );
    
    if (waypoint.name.isEmpty) {
      return ToolResult(
        success: false,
        message: 'Waypoint "$name" not found.',
      );
    }
    
    _defaultHome = waypoint.name;
    rosBridge.publishWorkflowSetHome(waypoint.name, autoReturn);
    
    return ToolResult(
      success: true,
      message: 'Home set to ${waypoint.name}. Auto-return: ${autoReturn ? "on" : "off"}.',
    );
  }
  
  // ===========================================================================
  // CONTEXT FOR SYSTEM PROMPT
  // ===========================================================================
  
  String getWorkflowContext() {
    final buffer = StringBuffer();

    buffer.writeln('\n\nROBOT CONTROL:');
    buffer.writeln('Use function calls silently - don\'t explain what you\'re doing.');
    buffer.writeln('- queue_task + go: deliver message (call queue_task, wait for "go", then call go)');
    buffer.writeln('- go_home: return home');
    buffer.writeln('- move_robot / navigate_to_waypoint: movement');
    buffer.writeln('Keep responses very brief when using tools.');
    buffer.writeln();
    buffer.writeln('MESSAGE DELIVERY (keep responses short):');
    buffer.writeln('- No recipient: "Who should I tell?"');
    buffer.writeln('- No message: "What should I tell [name]?"');
    buffer.writeln('- Have both: call queue_task immediately');

    // Current mode status
    if (_wanderActive || _followingActive) {
      buffer.writeln('\nCURRENT MODE:');
      if (_wanderActive) {
        buffer.writeln('- Wandering mode ACTIVE');
      }
      if (_followingActive) {
        buffer.writeln('- Following mode ACTIVE ($_followingStatus)');
      }
    }

    // Active search status
    if (plannedSearchService != null && plannedSearchService!.isSearching) {
      final progress = plannedSearchService!.searchProgress;
      buffer.writeln('\n🔍 AUTONOMOUS SEARCH ACTIVE:');
      buffer.writeln('- Target: ${progress['target']}');
      buffer.writeln('- Coverage: ${progress['coverage_percent']}%');
      if (progress['pending_verification'] == true) {
        buffer.writeln('- Status: AWAITING USER VERIFICATION');
        buffer.writeln('- Ask: "Is this the ${progress['target']}?" and wait for yes/no');
      } else {
        buffer.writeln('- Status: Navigating and searching (no action needed)');
      }
      buffer.writeln();
      buffer.writeln('SEARCH RULES:');
      buffer.writeln('- Robot navigates and searches ON ITS OWN');
      buffer.writeln('- NEVER say "I can\'t find it" - search continues until done');
      buffer.writeln('- ONLY call confirm/reject when user says yes/no');
    }

    // Waypoints
    if (_waypoints.isNotEmpty) {
      buffer.writeln('\nLOCATIONS: ${_waypoints.map((w) => w.name).join(", ")}');
    }

    return buffer.toString();
  }
}

