import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../utils/rosbridge.dart';
import 'ticket_tools_handler.dart';

/// Workflow Tools for AI function calling
/// Gives the Default Action full control over the robot:
/// - Navigate to any waypoint
/// - Execute any action (Take Order, Deliver Ticket, etc.)
/// - Display any screen
/// - Control workflow (pause, resume, stop, etc.)
class WorkflowTools {
  final RosBridge rosBridge;
  
  // Callback when workflow is confirmed and conversation should end
  void Function()? onWorkflowConfirmed;
  
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
  void clear() {
    if (_pendingSteps.isNotEmpty) {
      debugPrint('🧹 [WorkflowTools] Clearing ${_pendingSteps.length} pending steps');
      _pendingSteps.clear();
    }
  }
  
  // ===========================================================================
  // TOOL DEFINITIONS
  // ===========================================================================
  
  static List<Map<String, dynamic>> get toolDefinitions => [
    // NAVIGATION (prefer execute_now for immediate execution)
    {
      'type': 'function',
      'function': {
        'name': 'navigate_to_waypoint',
        'description': 'Queue navigation to a location. Prefer execute_now instead for immediate execution.',
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
    // ACTIONS (prefer execute_now for immediate execution)
    {
      'type': 'function',
      'function': {
        'name': 'execute_action',
        'description': 'Queue an action like "Take Order" or "Deliver Ticket". Prefer execute_now instead.',
        'parameters': {
          'type': 'object',
          'properties': {
            'action_name': {
              'type': 'string',
              'description': 'The name of the action to execute',
            },
          },
          'required': ['action_name'],
        },
      },
    },
    // DISPLAY (prefer execute_now for immediate execution)
    {
      'type': 'function',
      'function': {
        'name': 'show_display',
        'description': 'Queue a display change. Prefer execute_now instead.',
        'parameters': {
          'type': 'object',
          'properties': {
            'display_name': {
              'type': 'string',
              'description': 'The display to show: "Show Face", "Show Dashboard", or "Show Tickets"',
            },
          },
          'required': ['display_name'],
        },
      },
    },
    // SAVED TASKS (prefer execute_now for immediate execution)
    {
      'type': 'function',
      'function': {
        'name': 'execute_saved_task',
        'description': 'Queue a saved Task. Prefer execute_now instead.',
        'parameters': {
          'type': 'object',
          'properties': {
            'task_name': {
              'type': 'string',
              'description': 'The name of the saved Task to execute',
            },
          },
          'required': ['task_name'],
        },
      },
    },
    // EXECUTE NOW - Single tool to build and execute workflow immediately
    {
      'type': 'function',
      'function': {
        'name': 'execute_now',
        'description': 'EXECUTE IMMEDIATELY without asking for confirmation. Use this when you know what the user wants. Builds and starts the workflow in one step. The conversation ends immediately after this call - do NOT speak after calling this.',
        'parameters': {
          'type': 'object',
          'properties': {
            'steps': {
              'type': 'array',
              'description': 'Steps to execute',
              'items': {
                'type': 'object',
                'properties': {
                  'type': {
                    'type': 'string',
                    'enum': ['navigate', 'action', 'display', 'speak'],
                    'description': 'Step type',
                  },
                  'value': {
                    'type': 'string',
                    'description': 'Waypoint name, action name, display name, or text to speak',
                  },
                },
                'required': ['type', 'value'],
              },
            },
          },
          'required': ['steps'],
        },
      },
    },
    // CONFIRM AND EXECUTE (legacy - prefer execute_now)
    {
      'type': 'function',
      'function': {
        'name': 'confirm_and_execute',
        'description': 'Start executing queued workflow steps. Prefer execute_now instead for single-step execution.',
        'parameters': {
          'type': 'object',
          'properties': {
            'summary': {
              'type': 'string',
              'description': 'Brief summary of what will happen',
            },
          },
          'required': ['summary'],
        },
      },
    },
    // WORKFLOW BUILDING (prefer execute_now instead)
    {
      'type': 'function',
      'function': {
        'name': 'add_workflow_steps',
        'description': 'Queue multiple steps. Prefer execute_now instead for immediate execution.',
        'parameters': {
          'type': 'object',
          'properties': {
            'steps': {
              'type': 'array',
              'description': 'Array of steps to add',
              'items': {
                'type': 'object',
                'properties': {
                  'type': {
                    'type': 'string',
                    'enum': ['navigate', 'action', 'display', 'speak'],
                    'description': 'Step type',
                  },
                  'value': {
                    'type': 'string',
                    'description': 'Waypoint name, action name, display name, or text to speak',
                  },
                },
                'required': ['type', 'value'],
              },
            },
          },
          'required': ['steps'],
        },
      },
    },
    // WORKFLOW CONTROL
    {
      'type': 'function',
      'function': {
        'name': 'pause_workflow',
        'description': 'Pause the current workflow. Robot stops but remembers position. Use when user says "pause", "wait", "hold on".',
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
        'name': 'resume_workflow',
        'description': 'Resume a paused workflow. Use when user says "resume", "continue", "keep going".',
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
        'name': 'stop_workflow',
        'description': 'Stop and cancel the current workflow completely. Use when user says "stop", "cancel", "abort".',
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
        'name': 'clear_workflow',
        'description': 'Clear remaining workflow steps but stay ready for new commands.',
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
        'description': 'Get list of all saved locations/waypoints. Use when user asks "where can you go?", "what locations do you know?"',
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
        'name': 'get_available_actions',
        'description': 'Get list of all saved actions. Use when user asks "what can you do?", "what actions are available?"',
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
        'name': 'get_saved_tasks',
        'description': 'Get list of all saved Tasks (multi-step workflows). Use when user asks "what Tasks do you have?", "what can you run?", or wants to know available saved Tasks like Patrol, Delivery rounds, etc.',
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
        'description': 'Get current robot status: location, workflow state, etc. Use when user asks "where are you?", "what are you doing?"',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
    // HOME LOCATION
    {
      'type': 'function',
      'function': {
        'name': 'go_home',
        'description': 'Queue navigation to the home/default location. Prefer execute_now instead.',
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
        'description': 'Set the default home location for auto-return.',
        'parameters': {
          'type': 'object',
          'properties': {
            'waypoint_name': {
              'type': 'string',
              'description': 'The waypoint to set as home',
            },
            'auto_return': {
              'type': 'boolean',
              'description': 'Whether to automatically return home after workflows',
            },
          },
          'required': ['waypoint_name'],
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
      
      // Actions
      case 'execute_action':
        return _executeAction(toolCall.arguments);
      
      // Display
      case 'show_display':
        return _showDisplay(toolCall.arguments);
      
      // Saved Tasks
      case 'execute_saved_task':
        return _executeSavedTask(toolCall.arguments);
      
      // Execute now (immediate execution)
      case 'execute_now':
        return _executeNow(toolCall.arguments);
      
      // Confirm and execute (legacy)
      case 'confirm_and_execute':
        return _confirmAndExecute(toolCall.arguments);
      
      // Workflow building
      case 'add_workflow_steps':
        return _addWorkflowSteps(toolCall.arguments);
      
      // Workflow control
      case 'pause_workflow':
        return _pauseWorkflow();
      case 'resume_workflow':
        return _resumeWorkflow();
      case 'stop_workflow':
        return _stopWorkflow();
      case 'clear_workflow':
        return _clearWorkflow();
      
      // Queries
      case 'get_available_waypoints':
        return _getAvailableWaypoints();
      case 'get_available_actions':
        return _getAvailableActions();
      case 'get_saved_tasks':
        return _getSavedTasks();
      case 'get_robot_status':
        return _getRobotStatus();
      
      // Home
      case 'go_home':
        return _goHome();
      case 'set_home_location':
        return _setHomeLocation(toolCall.arguments);
      
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
    
    // Queue locally - will be sent to robot on confirm_and_execute
    _pendingSteps.add({'type': 'navigate', 'value': waypoint.name});
    debugPrint('📋 [WorkflowTools] Queued: navigate to ${waypoint.name}');
    
    return ToolResult(
      success: true,
      message: 'Added navigation to ${waypoint.name}. Call confirm_and_execute to start.',
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
      orElse: () => ActionDefinition(name: '', agentName: '', description: ''),
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
        message: 'No display specified. Options: "Show Face", "Show Dashboard", "Show Tickets"',
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
              orElse: () => ActionDefinition(name: '', agentName: '', description: ''),
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
    rosBridge.publishWorkflow(steps);
    
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
    rosBridge.publishWorkflow(_pendingSteps);
    
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
              orElse: () => ActionDefinition(name: '', agentName: '', description: ''),
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
    buffer.write('.');
    
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
      _pendingSteps.add({'type': 'navigate', 'value': defaultWaypoint.name});
      debugPrint('📋 [WorkflowTools] Queued: go home to ${defaultWaypoint.name}');
      
      return ToolResult(
        success: true,
        message: 'Added navigation home to ${defaultWaypoint.name}. Call confirm_and_execute to start.',
      );
    }
    
    // Fallback: check for manually set home
    if (_defaultHome != null && _defaultHome!.isNotEmpty) {
      _pendingSteps.add({'type': 'navigate', 'value': _defaultHome!});
      debugPrint('📋 [WorkflowTools] Queued: go home to $_defaultHome');
      
      return ToolResult(
        success: true,
        message: 'Added navigation home to $_defaultHome. Call confirm_and_execute to start.',
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
        message: 'No home location set. Please set a default waypoint in the Points list.',
      );
    }
    
    _pendingSteps.add({'type': 'navigate', 'value': homeWp.name});
    debugPrint('📋 [WorkflowTools] Queued: go home to ${homeWp.name}');
    
    return ToolResult(
      success: true,
      message: 'Added navigation home to ${homeWp.name}. Call confirm_and_execute to start.',
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
    
    buffer.writeln('\n\nWORKFLOW CONTROL:');
    buffer.writeln('You can control the robot using function calls.');
    buffer.writeln('CRITICAL: When you know what to do, use execute_now IMMEDIATELY. Do NOT ask for verbal confirmation. Do NOT say "is that okay?" or "shall I proceed?". Just execute.');
    buffer.writeln('Example: User says "go to the desk" → call execute_now with navigate to desk. Done. No talking after.');
    
    // Waypoints
    if (_waypoints.isNotEmpty) {
      buffer.writeln('\nAVAILABLE LOCATIONS: ${_waypoints.map((w) => w.name).join(", ")}');
    }
    
    // Actions
    if (_actions.isNotEmpty) {
      buffer.writeln('AVAILABLE ACTIONS: ${_actions.map((a) => a.name).join(", ")}');
    }
    
    // Saved Tasks
    if (_sequences.isNotEmpty) {
      buffer.writeln('SAVED TASKS: ${_sequences.map((t) => t.name).join(", ")}');
    }
    
    // Home location
    final defaultWaypoint = _waypoints.where((w) => w.isDefault).firstOrNull;
    if (defaultWaypoint != null) {
      buffer.writeln('HOME LOCATION: ${defaultWaypoint.name}');
    }
    
    // Show pending steps (queued for execution)
    if (_pendingSteps.isNotEmpty) {
      final pending = _pendingSteps.map((s) => '${s['type']}: ${s['value']}').join(', ');
      buffer.writeln('\nPENDING STEPS (call confirm_and_execute to start): $pending');
    }
    
    // Current state
    buffer.writeln('\nCURRENT STATE: $_workflowState');
    if (_totalSteps > 0) {
      buffer.writeln('WORKFLOW PROGRESS: step $_currentStep of $_totalSteps');
    }
    
    return buffer.toString();
  }
}

