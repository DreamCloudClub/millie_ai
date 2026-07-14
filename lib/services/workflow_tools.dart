import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../utils/rosbridge.dart';

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

/// Workflow Tools for AI function calling
/// Gives the Default Action full control over the robot:
/// - Navigate to any waypoint
/// - Execute any action
/// - Control workflow (pause, resume, stop, etc.)
class WorkflowTools {
  final RosBridge rosBridge;
  
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

  // Callback for patrol mode (wander + person detection)
  void Function()? onPatrolModeStart;
  void Function()? onPatrolModeStop;

  // Callback for go_away to trigger Patrol Mode
  void Function()? onGoAwayRequested;

  // Callback for approach_user to move toward detected person
  void Function()? onApproachUserRequested;

  // Callback when a temp task is queued (navigate + action)
  // Parameters: action definition (temp), origin pose (for return-to-origin)
  void Function(ActionDefinition action, RobotPose? originPose)? onTempTaskQueued;

  // Callback when AI wants to end the conversation naturally
  void Function()? onConversationEnd;


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
    // DIRECT MOVEMENT
    {
      'type': 'function',
      'function': {
        'name': 'move_robot',
        'description': '''Move the robot directly. Match user words to directions:
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
    // PATROL MODE (wander + person detection, auto-engage)
    {
      'type': 'function',
      'function': {
        'name': 'patrol',
        'description': 'Start patrol mode (wander + detect humans). Robot explores and will engage when it finds someone. Use when user says "patrol", "go patrol", "patrol mode".',
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
        'name': 'stop_patrol',
        'description': 'Stop patrol mode. Use when user says "stop patrol", "stop patrolling".',
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
        'description': 'Robot goes away and patrols (wander + detect). Saves current position to return to later. Use when user says "go away", "leave me alone".',
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
    // TASK CREATION (two-step: queue_task prepares, go executes)
    {
      'type': 'function',
      'function': {
        'name': 'queue_task',
        'description': 'Prepare a task to go somewhere and deliver a message.',
        'parameters': {
          'type': 'object',
          'properties': {
            'recipient': {
              'type': 'string',
              'description': 'Name of person to talk to (used to find their location)',
            },
            'message': {
              'type': 'string',
              'description': 'The exact message from the user to deliver - use their words verbatim',
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

      // Direct movement
      case 'move_robot':
        return _moveRobot(toolCall.arguments);

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

      // Patrol mode (wander + person detection)
      case 'patrol':
        return _startPatrolMode();
      case 'stop_patrol':
        return _stopPatrolMode();

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
    rosBridge.publishMove('stop');
    rosBridge.publishWorkflowCancel();  // Also cancel any navigation
    debugPrint('🛑 [WorkflowTools] Stop command');

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
  // PATROL MODE (wander + person detection, auto-engage on detection)
  // ===========================================================================

  ToolResult _startPatrolMode() {
    debugPrint('🔍 [WorkflowTools] Starting patrol mode (wander + detection)');

    if (onPatrolModeStart != null) {
      onPatrolModeStart!();
    } else {
      rosBridge.activatePatrolMode();
    }

    // Speak only if in ready/idle state (not during conversation)
    onSpeakIfIdle?.call('Patrol mode activated.');

    return ToolResult(
      success: true,
      message: 'Patrol mode activated.',
    );
  }

  ToolResult _stopPatrolMode() {
    debugPrint('🛑 [WorkflowTools] Stopping patrol mode');

    // Always disable patrol (wander + follow) directly
    rosBridge.deactivatePatrolMode();

    // Also notify conversation service if callback is set
    onPatrolModeStop?.call();

    // Clear any stale error state and notify controller
    _workflowState = 'idle';
    rosBridge.publishWorkflowIdle();

    return ToolResult(
      success: true,
      message: 'Stopped patrolling.',
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

    // Trigger Patrol Mode via callback (wander + person detection)
    if (onGoAwayRequested != null) {
      debugPrint('👋 [WorkflowTools] Go away - triggering patrol mode');
      onGoAwayRequested!();
    } else {
      // Fallback: activate patrol mode directly
      rosBridge.activatePatrolMode();
      debugPrint('👋 [WorkflowTools] Go away - patrol mode enabled (fallback)');
    }

    return ToolResult(
      success: true,
      message: 'Going away. Say "come back" when you want me to return.',
    );
  }

  ToolResult _comeBack() {
    // Deactivate all modes (patrol/wander/follow)
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

    // Return confirmation - AI should confirm and tell user to say "go"
    final confirmMsg = 'Got it. I\'ll tell $recipient: $message. Just say go when you\'re ready.';

    return ToolResult(
      success: true,
      message: confirmMsg,
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
      message: 'On my way to ${waypoint.name}.',
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
    buffer.writeln('You can control the robot using function calls.');
    buffer.writeln('- move_robot: forward/back, turn (45°/90°/180°), spin (360°), stop');
    buffer.writeln('- navigate_to_waypoint: go to a saved location');
    buffer.writeln('- queue_task + go: deliver a message to someone');
    buffer.writeln('- go_home: return to home location');
    buffer.writeln('- stop_robot: stop all movement');

    buffer.writeln('\nMESSAGE DELIVERY:');
    buffer.writeln('1. Get the recipient name and their message');
    buffer.writeln('2. Call queue_task with recipient and the exact message');
    buffer.writeln('3. WAIT for them to say "go" before calling go()');
    buffer.writeln('4. Robot will navigate and deliver the message');
    buffer.writeln('5. Then have a normal conversation - no special flow needed');
    buffer.writeln('6. When they say "go home" or "return", use go_home');

    // Current mode status
    if (_wanderActive || _followingActive) {
      buffer.writeln('\nCURRENT MODE:');
      if (_wanderActive && _followingActive) {
        buffer.writeln('- Patrol mode ACTIVE (wandering + person detection)');
      } else if (_wanderActive) {
        buffer.writeln('- Wandering mode ACTIVE');
      } else if (_followingActive) {
        buffer.writeln('- Following mode ACTIVE ($_followingStatus)');
      }
    }

    // Waypoints
    if (_waypoints.isNotEmpty) {
      buffer.writeln('\nLOCATIONS: ${_waypoints.map((w) => w.name).join(", ")}');
    }

    return buffer.toString();
  }
}

