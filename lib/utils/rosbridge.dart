// lib/utils/rosbridge.dart
import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../services/local_cache_service.dart';

/// Robot pose in map coordinates
class RobotPose {
  final double x;
  final double y;
  final double theta; // yaw in radians
  
  RobotPose({required this.x, required this.y, required this.theta});
}

/// Waypoint with name and pose
class Waypoint {
  final String name;
  final double x;
  final double y;
  final double theta;
  final bool isDefault;  // Default waypoint = home location
  
  Waypoint({
    required this.name,
    required this.x,
    required this.y,
    this.theta = 0.0,
    this.isDefault = false,
  });
  
  Map<String, dynamic> toJson() => {
    'name': name,
    'x': x,
    'y': y,
    'theta': theta,
    'is_default': isDefault,
  };
  
  factory Waypoint.fromJson(Map<String, dynamic> json) => Waypoint(
    name: json['name'] as String,
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    theta: (json['theta'] as num?)?.toDouble() ?? 0.0,
    isDefault: json['is_default'] as bool? ?? false,
  );
  
  Waypoint copyWith({
    String? name,
    double? x,
    double? y,
    double? theta,
    bool? isDefault,
  }) => Waypoint(
    name: name ?? this.name,
    x: x ?? this.x,
    y: y ?? this.y,
    theta: theta ?? this.theta,
    isDefault: isDefault ?? this.isDefault,
  );
}

/// Navigation status
enum NavStatus {
  idle,       // No active goal
  executing,  // Goal in progress
  succeeded,  // Goal reached!
  canceled,   // Goal was canceled
  failed,     // Goal failed
}

/// Laser scan data
class LaserScan {
  final double angleMin;
  final double angleMax;
  final double angleIncrement;
  final List<double> ranges;
  
  LaserScan({
    required this.angleMin,
    required this.angleMax,
    required this.angleIncrement,
    required this.ranges,
  });
}

/// Occupancy grid map data
class MapData {
  final int width;
  final int height;
  final double resolution;  // meters per pixel
  final double originX;     // world X of map origin
  final double originY;     // world Y of map origin
  final List<int> data;     // -1 = unknown, 0 = free, 100 = occupied
  
  MapData({
    required this.width,
    required this.height,
    required this.resolution,
    required this.originX,
    required this.originY,
    required this.data,
  });
}

/// Saved navigation sequence
class SavedSequence {
  final String name;
  final List<String> waypointNames;
  
  SavedSequence({required this.name, required this.waypointNames});
  
  Map<String, dynamic> toJson() => {
    'name': name,
    'waypoints': waypointNames,
  };
  
  factory SavedSequence.fromJson(Map<String, dynamic> json) => SavedSequence(
    name: json['name'] as String,
    waypointNames: List<String>.from(json['waypoints'] as List),
  );
}

/// A single step in a conversation flow
class ConversationStep {
  final String type;     // 'question', 'statement'
  final String content;  // The text to say/ask
  final bool required;   // Must this step happen?
  
  ConversationStep({
    required this.type,
    required this.content,
    this.required = true,
  });
  
  Map<String, dynamic> toJson() => {
    'type': type,
    'content': content,
    'required': required,
  };
  
  factory ConversationStep.fromJson(Map<String, dynamic> json) => ConversationStep(
    type: json['type'] as String? ?? 'question',
    content: json['content'] as String? ?? '',
    required: json['required'] as bool? ?? true,
  );
  
  ConversationStep copyWith({String? type, String? content, bool? required}) =>
    ConversationStep(
      type: type ?? this.type,
      content: content ?? this.content,
      required: required ?? this.required,
    );
}

/// Action definition (prompt configuration for AI conversations)
/// Note: All actions use the current default agent - no per-action agent selection
class ActionDefinition {
  final String name;
  final String description;
  final String recipientName;      // If set, confirm identity before delivering message
  final String openingGreeting;    // What the robot says first (after confirmation if recipientName set)
  final List<ConversationStep> steps;  // Follow-up questions/statements
  final String confirmation;       // Closing/confirmation statement
  final bool isDefault;            // Default action for wake word / play button
  final String source;             // 'user' or 'robot'

  ActionDefinition({
    required this.name,
    this.description = '',
    this.recipientName = '',
    this.openingGreeting = '',
    this.steps = const [],
    this.confirmation = '',
    this.isDefault = false,
    this.source = 'user',
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'recipient_name': recipientName,
    'opening_greeting': openingGreeting,
    'steps': steps.map((s) => s.toJson()).toList(),
    'confirmation': confirmation,
    'is_default': isDefault,
    'source': source,
  };

  factory ActionDefinition.fromJson(Map<String, dynamic> json) => ActionDefinition(
    name: json['name'] as String,
    description: json['description'] as String? ?? '',
    recipientName: json['recipient_name'] as String? ?? '',
    openingGreeting: json['opening_greeting'] as String? ?? '',
    steps: (json['steps'] as List<dynamic>?)
        ?.map((s) => ConversationStep.fromJson(s as Map<String, dynamic>))
        .toList() ?? [],
    confirmation: json['confirmation'] as String? ?? '',
    isDefault: json['is_default'] as bool? ?? false,
    source: json['source'] as String? ?? 'user',
  );

  ActionDefinition copyWith({
    String? name,
    String? description,
    String? recipientName,
    String? openingGreeting,
    List<ConversationStep>? steps,
    String? confirmation,
    bool? isDefault,
    String? source,
  }) => ActionDefinition(
    name: name ?? this.name,
    description: description ?? this.description,
    recipientName: recipientName ?? this.recipientName,
    openingGreeting: openingGreeting ?? this.openingGreeting,
    steps: steps ?? this.steps,
    confirmation: confirmation ?? this.confirmation,
    isDefault: isDefault ?? this.isDefault,
    source: source ?? this.source,
  );
}

/// A step in a history entry
class HistoryStep {
  final String type;   // 'navigate', 'action', 'display'
  final String value;  // waypoint name, action name, display name

  HistoryStep({required this.type, required this.value});

  Map<String, dynamic> toJson() => {'type': type, 'value': value};

  factory HistoryStep.fromJson(Map<String, dynamic> json) => HistoryStep(
    type: json['type'] as String? ?? '',
    value: json['value'] as String? ?? '',
  );
}

/// History entry for workflow execution
class HistoryEntry {
  final DateTime timestamp;
  final List<HistoryStep> steps;
  final String source;  // 'user' or 'robot'

  HistoryEntry({
    required this.timestamp,
    required this.steps,
    this.source = 'user',
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'steps': steps.map((s) => s.toJson()).toList(),
    'source': source,
  };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
    timestamp: DateTime.parse(json['timestamp'] as String),
    steps: (json['steps'] as List<dynamic>?)
        ?.map((s) => HistoryStep.fromJson(s as Map<String, dynamic>))
        .toList() ?? [],
    source: json['source'] as String? ?? 'user',
  );

  String get description => steps.map((s) => s.value).join(' → ');
}

/// AI Agent definition (reusable persona template)
class AgentDefinition {
  final String name;
  final String faceId;
  final String voice;
  final String voiceMode; // 'turn_taking' or 'realtime'
  final String personality;
  final String introMessage;
  final bool isDefault;

  AgentDefinition({
    required this.name,
    this.faceId = '',
    this.voice = 'nova',
    this.voiceMode = 'turn_taking',
    this.personality = '',
    this.introMessage = '',
    this.isDefault = false,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'face_id': faceId,
    'voice': voice,
    'voice_mode': voiceMode,
    'personality': personality,
    'intro_message': introMessage,
    'is_default': isDefault,
  };

  factory AgentDefinition.fromJson(Map<String, dynamic> json) => AgentDefinition(
    name: json['name'] as String? ?? '',
    faceId: json['face_id'] as String? ?? '',
    voice: json['voice'] as String? ?? 'nova',
    voiceMode: json['voice_mode'] as String? ?? 'turn_taking',
    personality: json['personality'] as String? ?? '',
    introMessage: json['intro_message'] as String? ?? '',
    isDefault: json['is_default'] as bool? ?? false,
  );

  AgentDefinition copyWith({
    String? name,
    String? faceId,
    String? voice,
    String? voiceMode,
    String? personality,
    String? introMessage,
    bool? isDefault,
  }) => AgentDefinition(
    name: name ?? this.name,
    faceId: faceId ?? this.faceId,
    voice: voice ?? this.voice,
    voiceMode: voiceMode ?? this.voiceMode,
    personality: personality ?? this.personality,
    introMessage: introMessage ?? this.introMessage,
    isDefault: isDefault ?? this.isDefault,
  );
}

/// User profile data
class UserProfile {
  final String username;
  final String pronouns;
  final String bio;

  UserProfile({
    this.username = '',
    this.pronouns = '',
    this.bio = '',
  });

  Map<String, dynamic> toJson() => {
    'username': username,
    'pronouns': pronouns,
    'bio': bio,
  };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    username: json['username'] as String? ?? '',
    pronouns: json['pronouns'] as String? ?? '',
    bio: json['bio'] as String? ?? '',
  );

  UserProfile copyWith({
    String? username,
    String? pronouns,
    String? bio,
  }) => UserProfile(
    username: username ?? this.username,
    pronouns: pronouns ?? this.pronouns,
    bio: bio ?? this.bio,
  );
}

/// A person the robot knows about
class KnownPerson {
  final String name;
  final String relationship; // e.g., "owner", "friend", "coworker", "visitor"
  final List<String> notes; // things to remember about this person
  final String? interests; // their interests
  final DateTime? lastSeen;

  KnownPerson({
    required this.name,
    this.relationship = '',
    this.notes = const [],
    this.interests,
    this.lastSeen,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'relationship': relationship,
    'notes': notes,
    'interests': interests,
    'last_seen': lastSeen?.toIso8601String(),
  };

  factory KnownPerson.fromJson(Map<String, dynamic> json) => KnownPerson(
    name: json['name'] as String? ?? '',
    relationship: json['relationship'] as String? ?? '',
    notes: (json['notes'] as List<dynamic>?)?.map((n) => n as String).toList() ?? [],
    interests: json['interests'] as String?,
    lastSeen: json['last_seen'] != null ? DateTime.tryParse(json['last_seen'] as String) : null,
  );

  KnownPerson copyWith({
    String? name,
    String? relationship,
    List<String>? notes,
    String? interests,
    DateTime? lastSeen,
  }) => KnownPerson(
    name: name ?? this.name,
    relationship: relationship ?? this.relationship,
    notes: notes ?? this.notes,
    interests: interests ?? this.interests,
    lastSeen: lastSeen ?? this.lastSeen,
  );
}

/// A note/memory the robot has saved
class MemoryNote {
  final String id;
  final String content;
  final String category; // e.g., "observation", "preference", "fact", "event"
  final DateTime createdAt;

  MemoryNote({
    required this.id,
    required this.content,
    this.category = 'general',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'category': category,
    'created_at': createdAt.toIso8601String(),
  };

  factory MemoryNote.fromJson(Map<String, dynamic> json) => MemoryNote(
    id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
    content: json['content'] as String? ?? '',
    category: json['category'] as String? ?? 'general',
    createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now() : DateTime.now(),
  );
}

/// Owner profile - notes about the primary user
class OwnerProfile {
  final List<String> notes;

  OwnerProfile({
    this.notes = const [],
  });

  bool get isEmpty => notes.isEmpty;

  Map<String, dynamic> toJson() => {
    'notes': notes,
  };

  factory OwnerProfile.fromJson(Map<String, dynamic> json) => OwnerProfile(
    notes: (json['notes'] as List<dynamic>?)?.map((n) => n as String).toList() ?? [],
  );

  OwnerProfile copyWith({
    List<String>? notes,
  }) => OwnerProfile(
    notes: notes ?? this.notes,
  );
}

/// All memories the robot has
class MemoryData {
  final OwnerProfile owner;
  final List<KnownPerson> people;
  final List<MemoryNote> notes;

  MemoryData({
    OwnerProfile? owner,
    this.people = const [],
    this.notes = const [],
  }) : owner = owner ?? OwnerProfile();

  bool get isEmpty => owner.isEmpty && people.isEmpty && notes.isEmpty;

  Map<String, dynamic> toJson() => {
    'owner': owner.toJson(),
    'people': people.map((p) => p.toJson()).toList(),
    'notes': notes.map((n) => n.toJson()).toList(),
  };

  factory MemoryData.fromJson(Map<String, dynamic> json) => MemoryData(
    owner: json['owner'] != null
        ? OwnerProfile.fromJson(json['owner'] as Map<String, dynamic>)
        : OwnerProfile(),
    people: (json['people'] as List<dynamic>?)
        ?.map((p) => KnownPerson.fromJson(p as Map<String, dynamic>))
        .toList() ?? [],
    notes: (json['notes'] as List<dynamic>?)
        ?.map((n) => MemoryNote.fromJson(n as Map<String, dynamic>))
        .toList() ?? [],
  );

  MemoryData copyWith({
    OwnerProfile? owner,
    List<KnownPerson>? people,
    List<MemoryNote>? notes,
  }) => MemoryData(
    owner: owner ?? this.owner,
    people: people ?? this.people,
    notes: notes ?? this.notes,
  );
}

class RosBridge {
  final String url;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  
  // ============================================================
  // CENTRAL DATA STORAGE (Source of Truth)
  // ============================================================
  List<Waypoint> waypoints = [];
  List<SavedSequence> sequences = [];
  List<ActionDefinition> actions = [];
  List<AgentDefinition> agents = [];
  List<HistoryEntry> history = [];
  UserProfile? userProfile;
  MemoryData? memories;
  RobotPose? currentPose;
  MapData? _cachedMapData;
  NavStatus _lastNavStatus = NavStatus.idle;
  LaserScan? _currentLaserScan;
  
  // ============================================================
  // MULTI-LISTENER PATTERN (supports multiple consumers)
  // ============================================================
  final List<void Function(List<Waypoint>)> _waypointListeners = [];
  final List<void Function(List<SavedSequence>)> _sequenceListeners = [];
  final List<void Function(List<ActionDefinition>)> _actionListeners = [];
  final List<void Function(List<AgentDefinition>)> _agentListeners = [];
  final List<void Function(UserProfile)> _userProfileListeners = [];
  final List<void Function(RobotPose)> _poseListeners = [];
  final List<void Function(MapData)> _mapListeners = [];
  final List<void Function(NavStatus)> _navStatusListeners = [];
  final List<void Function(LaserScan)> _laserScanListeners = [];
  final List<void Function(MemoryData)> _memoryListeners = [];
  final List<void Function(List<HistoryEntry>)> _historyListeners = [];
  final List<void Function(String, int, int, List<Map<String, dynamic>>?)> _workflowStatusListeners = [];
  
  /// Add a waypoint listener. Receives current data immediately if available.
  void addWaypointListener(void Function(List<Waypoint>) callback) {
    _waypointListeners.add(callback);
    if (waypoints.isNotEmpty) {
      print('📍 [MultiListener] New waypoint listener, sending ${waypoints.length} cached waypoints');
      callback(waypoints);
    }
  }
  
  void removeWaypointListener(void Function(List<Waypoint>) callback) {
    _waypointListeners.remove(callback);
  }
  
  /// Add a sequence listener. Receives current data immediately if available.
  void addSequenceListener(void Function(List<SavedSequence>) callback) {
    _sequenceListeners.add(callback);
    if (sequences.isNotEmpty) {
      print('📍 [MultiListener] New sequence listener, sending ${sequences.length} cached sequences');
      callback(sequences);
    }
  }
  
  void removeSequenceListener(void Function(List<SavedSequence>) callback) {
    _sequenceListeners.remove(callback);
  }
  
  /// Add an action listener. Receives current data immediately if available.
  void addActionListener(void Function(List<ActionDefinition>) callback) {
    _actionListeners.add(callback);
    if (actions.isNotEmpty) {
      print('📍 [MultiListener] New action listener, sending ${actions.length} cached actions');
      callback(actions);
    }
  }
  
  void removeActionListener(void Function(List<ActionDefinition>) callback) {
    _actionListeners.remove(callback);
  }

  /// Add a history listener. Receives current data immediately if available.
  void addHistoryListener(void Function(List<HistoryEntry>) callback) {
    _historyListeners.add(callback);
    if (history.isNotEmpty) {
      print('📍 [MultiListener] New history listener, sending ${history.length} cached entries');
      callback(history);
    }
  }

  void removeHistoryListener(void Function(List<HistoryEntry>) callback) {
    _historyListeners.remove(callback);
  }

  /// Add an agent listener. Receives current data immediately if available.
  void addAgentListener(void Function(List<AgentDefinition>) callback) {
    _agentListeners.add(callback);
    if (agents.isNotEmpty) {
      print('📍 [MultiListener] New agent listener, sending ${agents.length} cached agents');
      callback(agents);
    }
  }
  
  void removeAgentListener(void Function(List<AgentDefinition>) callback) {
    _agentListeners.remove(callback);
  }

  /// Add a user profile listener. Receives current data immediately if available.
  void addUserProfileListener(void Function(UserProfile) callback) {
    _userProfileListeners.add(callback);
    if (userProfile != null) {
      print('📍 [MultiListener] New user profile listener, sending cached profile');
      callback(userProfile!);
    }
  }

  void removeUserProfileListener(void Function(UserProfile) callback) {
    _userProfileListeners.remove(callback);
  }

  /// Add a pose listener. Receives current pose immediately if available.
  void addPoseListener(void Function(RobotPose) callback) {
    _poseListeners.add(callback);
    if (currentPose != null) {
      callback(currentPose!);
    }
  }
  
  void removePoseListener(void Function(RobotPose) callback) {
    _poseListeners.remove(callback);
  }
  
  /// Add a map listener. Receives cached map immediately if available.
  void addMapListener(void Function(MapData) callback) {
    _mapListeners.add(callback);
    if (_cachedMapData != null) {
      print('📍 [MultiListener] New map listener, sending cached map ${_cachedMapData!.width}x${_cachedMapData!.height}');
      callback(_cachedMapData!);
    }
  }
  
  void removeMapListener(void Function(MapData) callback) {
    _mapListeners.remove(callback);
  }
  
  /// Direct access to cached map data
  MapData? get mapData => _cachedMapData;
  
  /// Add a nav status listener.
  void addNavStatusListener(void Function(NavStatus) callback) {
    _navStatusListeners.add(callback);
  }
  
  void removeNavStatusListener(void Function(NavStatus) callback) {
    _navStatusListeners.remove(callback);
  }
  
  /// Direct access to current nav status
  NavStatus get currentNavStatus => _lastNavStatus;
  
  /// Get the default waypoint (home location)
  Waypoint? get defaultWaypoint => waypoints.where((w) => w.isDefault).firstOrNull;
  
  /// Add a laser scan listener.
  void addLaserScanListener(void Function(LaserScan) callback) {
    _laserScanListeners.add(callback);
    if (_currentLaserScan != null) {
      callback(_currentLaserScan!);
    }
  }
  
  void removeLaserScanListener(void Function(LaserScan) callback) {
    _laserScanListeners.remove(callback);
  }
  
  /// Direct access to current laser scan
  LaserScan? get laserScan => _currentLaserScan;

  /// Add a memory listener. Receives current data immediately if available.
  void addMemoryListener(void Function(MemoryData) callback) {
    _memoryListeners.add(callback);
    if (memories != null) {
      print('📍 [MultiListener] New memory listener, sending cached memories');
      callback(memories!);
    }
  }

  void removeMemoryListener(void Function(MemoryData) callback) {
    _memoryListeners.remove(callback);
  }

  /// Add a workflow status listener.
  void addWorkflowStatusListener(void Function(String, int, int, List<Map<String, dynamic>>?) callback) {
    _workflowStatusListeners.add(callback);
  }
  
  void removeWorkflowStatusListener(void Function(String, int, int, List<Map<String, dynamic>>?) callback) {
    _workflowStatusListeners.remove(callback);
  }
  
  // ============================================================
  // LEGACY SINGLE CALLBACKS (Still work - for backward compatibility)
  // ============================================================
  void Function(RobotPose)? onPoseUpdate;
  void Function(List<Waypoint>)? onWaypointsUpdate;
  void Function(bool)? onConnectionChange;
  void Function(NavStatus)? onNavStatusUpdate;
  void Function(String status, int step, int total, List<Map<String, dynamic>>? steps)? onWorkflowStatus;
  void Function(ActionDefinition action)? onActionExecute;  // When workflow triggers an action
  void Function(String)? onDisplayCommand;  // When workflow triggers a display change
  void Function()? onVoiceAgentStart;  // When controller requests voice agent start (play button)
  void Function()? onLaunch;  // When controller requests launch (startup sequence)
  void Function()? onStart;   // When controller requests start (quick face transition, no AI)
  void Function()? onPlay;    // When controller requests play (start/resume AI conversation)
  void Function()? onPause;   // When controller requests pause (stop AI conversation)
  void Function()? onExit;    // When controller requests exit (return to launch page)
  void Function()? onWanderStart;  // When controller requests silent wander mode start
  void Function()? onWanderStop;   // When controller requests silent wander mode stop
  void Function()? onRefresh; // When controller requests AI context refresh
  void Function(String)? onSpeakCommand;  // When controller sends text for robot to speak
  void Function(String)? onMotionDetectorStatus;  // Motion detector status changes (approaching, lost, etc.)
  void Function(Map<String, dynamic>)? onPersonStatus;  // Person detection status from camera (JSON with distance, confidence, etc.)
  void Function(Map<String, dynamic>)? onFollowingModeStatus;  // Following mode status (disabled, tracking, approaching, arrived, lost, searching)
  void Function(String)? onWanderStatus;  // Wander status changes (navigating, searching, etc.)
  void Function(String)? onLimiterStatus;  // Limiter blocked by obstacle (blocked_front, blocked_rear)
  void Function(LaserScan)? onLaserScanUpdate;
  void Function(List<SavedSequence>)? onSequencesUpdate;
  void Function(List<ActionDefinition>)? onActionsUpdate;
  void Function(List<AgentDefinition>)? onAgentsUpdate;
  
  // Map callback with caching (map is latched, only sent once)
  void Function(MapData)? _onMapUpdate;
  
  set onMapUpdate(void Function(MapData)? callback) {
    _onMapUpdate = callback;
    // If we already have cached map data, send it immediately
    if (callback != null && _cachedMapData != null) {
      print("📦 Sending cached map data to new listener");
      callback(_cachedMapData!);
    }
  }
  
  void Function(MapData)? get onMapUpdate => _onMapUpdate;
  
  bool _connected = false;
  bool get isConnected => _connected;

  RosBridge(this.url);

  /// Load cached data from SharedPreferences and notify listeners.
  /// Call this before connect() to show cached data immediately.
  Future<void> loadFromCache() async {
    print('📦 Loading data from local cache...');

    // Load agents
    final cachedAgents = await LocalCacheService.loadAgents();
    if (cachedAgents.isNotEmpty) {
      agents = cachedAgents;
      print('📦 Loaded ${agents.length} cached agents');
      for (final listener in _agentListeners) {
        listener(agents);
      }
      onAgentsUpdate?.call(agents);
    }

    // Load user profile
    final cachedProfile = await LocalCacheService.loadUserProfile();
    if (cachedProfile != null) {
      userProfile = cachedProfile;
      print('📦 Loaded cached user profile: ${userProfile!.username}');
      for (final listener in _userProfileListeners) {
        listener(userProfile!);
      }
    }

    // Load memories
    final cachedMemories = await LocalCacheService.loadMemories();
    if (cachedMemories != null) {
      memories = cachedMemories;
      print('📦 Loaded cached memories');
      for (final listener in _memoryListeners) {
        listener(memories!);
      }
    }

    print('📦 Cache loading complete');
  }

  void connect() {
    // Cancel any existing reconnect timer
    _reconnectTimer?.cancel();
    
    // Close existing connection if any
    _subscription?.cancel();
    try { _channel?.sink.close(); } catch (_) {}
    
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      print("✅ Connected to ROSBridge at $url");
      _connected = true;
      onConnectionChange?.call(true);
      
      // Listen for incoming messages
      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: (e) {
          print("❌ ROSBridge error: $e");
          _handleDisconnect();
        },
        onDone: () {
          print("👋 ROSBridge connection closed");
          _handleDisconnect();
        },
      );
      
      // Subscribe to robot pose (slam_toolbox publishes to /pose)
      _subscribe('/pose', 'geometry_msgs/msg/PoseWithCovarianceStamped');
      
      // Subscribe to waypoints list
      _subscribe('/millie/waypoints', 'std_msgs/msg/String');
      
      // Subscribe to sequences list
      _subscribe('/millie/sequences', 'std_msgs/msg/String');
      
      // Subscribe to actions list
      _subscribe('/millie/actions', 'std_msgs/msg/String');

      // Subscribe to history
      _subscribe('/millie/history', 'std_msgs/msg/String');

      // Subscribe to AI agents
      _subscribe('/millie/agents', 'std_msgs/msg/String');

      // Subscribe to user profile
      _subscribe('/millie/user_profile', 'std_msgs/msg/String');

      // Subscribe to memories
      _subscribe('/millie/memories', 'std_msgs/msg/String');

      // Subscribe to workflow status
      _subscribe('/millie/workflow/status', 'std_msgs/msg/String');
      _subscribe('/millie/action/execute', 'std_msgs/msg/String');
      _subscribe('/millie/display', 'std_msgs/msg/String');

      // Subscribe to voice agent commands from controller
      _subscribe('/millie/voice_agent/start', 'std_msgs/msg/String');

      // Subscribe to mode commands (launch/play/pause) from controller
      _subscribe('/millie/mode', 'std_msgs/msg/String');

      // Subscribe to AI refresh command from controller
      _subscribe('/millie/ai/refresh', 'std_msgs/msg/String');

      // Subscribe to speak command from controller (robot speaks text)
      _subscribe('/millie/speak', 'std_msgs/msg/String');

      // Subscribe to motion detector status (for AI prompts in explore mode)
      _subscribe('/motion_detector/status', 'std_msgs/msg/String');

      // Subscribe to always-on person detection status from OAK-D
      _subscribe('/oak/person_status', 'std_msgs/msg/String');
      _subscribe('/person_follower/status', 'std_msgs/msg/String');

      // Subscribe to wander status (for AI prompts in explore mode)
      _subscribe('/wander/status', 'std_msgs/msg/String');

      // Subscribe to limiter status (blocked by obstacle)
      _subscribe('/limiter/status', 'std_msgs/msg/String');

      // Subscribe to map with TRANSIENT_LOCAL QoS to receive latched map
      _subscribeWithQos('/map', 'nav_msgs/msg/OccupancyGrid', durability: 'transient_local');
      
      // Subscribe to Nav2 action status for navigation complete notifications
      _subscribe('/navigate_to_pose/_action/status', 'action_msgs/msg/GoalStatusArray');
      
      // Laser scan disabled - needs TF sync for proper display
      // _subscribeThrottled('/scan_filtered', 'sensor_msgs/msg/LaserScan', 500);
      
    } catch (e) {
      print("❌ Failed to connect to ROSBridge: $e");
      _handleDisconnect();
    }
  }
  
  void _handleDisconnect() {
    if (!_connected) return; // Already disconnected
    _connected = false;
    onConnectionChange?.call(false);
    _scheduleReconnect();
  }
  
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      print("🔄 Attempting to reconnect to ROSBridge...");
      connect();
    });
  }
  
  void _subscribe(String topic, String type) {
    if (_channel == null) return;
    
    final msg = {
      "op": "subscribe",
      "topic": topic,
      "type": type,
    };
    _channel!.sink.add(jsonEncode(msg));
    print("📡 Subscribed to $topic");
  }
  
  void _subscribeThrottled(String topic, String type, int throttleRateMs) {
    if (_channel == null) return;
    
    final msg = {
      "op": "subscribe",
      "topic": topic,
      "type": type,
      "throttle_rate": throttleRateMs,  // Limit message rate
    };
    _channel!.sink.add(jsonEncode(msg));
    print("📡 Subscribed to $topic (throttled: ${throttleRateMs}ms)");
  }
  
  void _subscribeWithQos(String topic, String type, {String? durability, int? throttleRateMs}) {
    if (_channel == null) return;
    
    final msg = <String, dynamic>{
      "op": "subscribe",
      "topic": topic,
      "type": type,
    };
    
    // Add QoS settings if specified
    if (durability != null) {
      msg["qos"] = {"durability": durability};
    }
    
    if (throttleRateMs != null) {
      msg["throttle_rate"] = throttleRateMs;
    }
    
    _channel!.sink.add(jsonEncode(msg));
    print("📡 Subscribed to $topic (durability: $durability)");
  }
  
  void _handleMessage(dynamic data) {
    try {
      final msg = jsonDecode(data);
      
      if (msg['op'] == 'publish') {
        final topic = msg['topic'];
        
        if (topic == '/pose') {
          _handlePoseMessage(msg['msg']);
        } else if (topic == '/millie/waypoints') {
          _handleWaypointsMessage(msg['msg']);
        } else if (topic == '/millie/sequences') {
          _handleSequencesMessage(msg['msg']);
        } else if (topic == '/millie/actions') {
          _handleActionsMessage(msg['msg']);
        } else if (topic == '/millie/history') {
          _handleHistoryMessage(msg['msg']);
        } else if (topic == '/millie/agents') {
          _handleAgentsMessage(msg['msg']);
        } else if (topic == '/millie/user_profile') {
          _handleUserProfileMessage(msg['msg']);
        } else if (topic == '/millie/memories') {
          _handleMemoriesMessage(msg['msg']);
        } else if (topic == '/millie/workflow/status') {
          _handleWorkflowStatusMessage(msg['msg']);
        } else if (topic == '/millie/action/execute') {
          _handleActionExecuteMessage(msg['msg']);
        } else if (topic == '/millie/display') {
          _handleDisplayMessage(msg['msg']);
        } else if (topic == '/millie/voice_agent/start') {
          _handleVoiceAgentStartMessage();
        } else if (topic == '/millie/mode') {
          _handleModeMessage(msg['msg']);
        } else if (topic == '/millie/ai/refresh') {
          _handleRefreshMessage();
        } else if (topic == '/millie/speak') {
          _handleSpeakMessage(msg['msg']);
        } else if (topic == '/map') {
          _handleMapMessage(msg['msg']);
        } else if (topic == '/navigate_to_pose/_action/status') {
          _handleNavStatusMessage(msg['msg']);
        } else if (topic == '/scan_filtered') {
          _handleLaserScanMessage(msg['msg']);
        } else if (topic == '/motion_detector/status') {
          _handleMotionDetectorStatus(msg['msg']);
        } else if (topic == '/oak/person_status') {
          _handlePersonStatus(msg['msg']);
        } else if (topic == '/person_follower/status') {
          _handleFollowingModeStatus(msg['msg']);
        } else if (topic == '/wander/status') {
          _handleWanderStatus(msg['msg']);
        } else if (topic == '/limiter/status') {
          _handleLimiterStatus(msg['msg']);
        }
      }
    } catch (e) {
      print("⚠️ Error parsing message: $e");
    }
  }

  void _handleMotionDetectorStatus(Map<String, dynamic> msg) {
    final status = msg['data'] as String? ?? '';
    if (status.isNotEmpty) {
      print("👀 [RosBridge] Motion detector: $status");
      onMotionDetectorStatus?.call(status);
    }
  }

  void _handlePersonStatus(Map<String, dynamic> msg) {
    final data = msg['data'] as String? ?? '';
    if (data.isNotEmpty) {
      try {
        final status = jsonDecode(data) as Map<String, dynamic>;
        print("👤 [RosBridge] Person detected: ${status['person_detected']} (dist=${status['distance']})");
        onPersonStatus?.call(status);
      } catch (e) {
        // Fallback for old string format
        print("👤 [RosBridge] Person status: $data");
        onPersonStatus?.call({'status': data, 'person_detected': false});
      }
    }
  }

  void _handleFollowingModeStatus(Map<String, dynamic> msg) {
    final data = msg['data'] as String? ?? '';
    if (data.isNotEmpty) {
      try {
        final status = jsonDecode(data) as Map<String, dynamic>;
        final mode = status['status'] as String? ?? 'disabled';
        print("🚶 [RosBridge] Following mode: $mode (detected=${status['person_detected']}, dist=${status['distance']})");
        onFollowingModeStatus?.call(status);
      } catch (e) {
        // Fallback for old string format
        print("🚶 [RosBridge] Following mode: $data");
        onFollowingModeStatus?.call({'status': data, 'person_detected': false});
      }
    }
  }

  void _handleWanderStatus(Map<String, dynamic> msg) {
    final status = msg['data'] as String? ?? '';
    if (status.isNotEmpty) {
      print("🚶 [RosBridge] Wander: $status");
      onWanderStatus?.call(status);
    }
  }

  void _handleLimiterStatus(Map<String, dynamic> msg) {
    final status = msg['data'] as String? ?? '';
    if (status.isNotEmpty) {
      print("🚧 [RosBridge] Limiter: $status");
      onLimiterStatus?.call(status);
    }
  }
  
  void _handlePoseMessage(Map<String, dynamic> msg) {
    try {
      final pose = msg['pose']['pose'];
      final position = pose['position'];
      final orientation = pose['orientation'];
      
      // Convert quaternion to yaw
      final double qz = orientation['z'];
      final double qw = orientation['w'];
      final double theta = 2.0 * _atan2(qz, qw);
      
      final robotPose = RobotPose(
        x: position['x'].toDouble(),
        y: position['y'].toDouble(),
        theta: theta,
      );
      
      // Store in central storage
      currentPose = robotPose;
      
      // Notify multi-listeners
      for (final listener in _poseListeners) {
        listener(robotPose);
      }
      
      // Legacy callback (backward compatibility)
      onPoseUpdate?.call(robotPose);
    } catch (e) {
      print("⚠️ Error parsing pose: $e");
    }
  }
  
  double _atan2(double y, double x) {
    // Simple atan2 implementation
    if (x > 0) return _atan(y / x);
    if (x < 0 && y >= 0) return _atan(y / x) + 3.14159;
    if (x < 0 && y < 0) return _atan(y / x) - 3.14159;
    if (x == 0 && y > 0) return 3.14159 / 2;
    if (x == 0 && y < 0) return -3.14159 / 2;
    return 0;
  }
  
  double _atan(double x) {
    // Taylor series approximation for small values
    return x - (x * x * x) / 3 + (x * x * x * x * x) / 5;
  }
  
  void _handleWorkflowStatusMessage(Map<String, dynamic> msg) {
    try {
      final data = jsonDecode(msg['data']);
      final status = data['status'] as String? ?? 'unknown';
      final step = data['step'] as int? ?? 0;
      final total = data['total'] as int? ?? 0;
      
      // Parse workflow steps if included (sent when status is 'started')
      List<Map<String, dynamic>>? steps;
      if (data['steps'] != null) {
        steps = (data['steps'] as List).map((s) => Map<String, dynamic>.from(s)).toList();
      }
      
      print('📋 [RosBridge] Workflow status: $status ($step/$total), notifying ${_workflowStatusListeners.length} listeners');
      
      // Notify multi-listeners
      for (final listener in _workflowStatusListeners) {
        listener(status, step, total, steps);
      }
      
      // Legacy callback (backward compatibility)
      onWorkflowStatus?.call(status, step, total, steps);
    } catch (e) {
      print("⚠️ Error parsing workflow status: $e");
    }
  }

  void _handleActionExecuteMessage(Map<String, dynamic> msg) {
    try {
      final data = jsonDecode(msg['data']);
      print("🎯 Action raw data: $data");
      print("🎯 Opening greeting: ${data['opening_greeting']}");
      final action = ActionDefinition.fromJson(data);
      print("🎯 Action execute received: ${action.name}");
      print("🎯 Action openingGreeting: '${action.openingGreeting}'");

      onActionExecute?.call(action);
    } catch (e) {
      print("⚠️ Error parsing action execute: $e");
    }
  }

  void _handleDisplayMessage(Map<String, dynamic> msg) {
    try {
      final displayName = msg['data'] as String;
      print("📺 Display command received: $displayName");
      onDisplayCommand?.call(displayName);
    } catch (e) {
      print("⚠️ Error parsing display command: $e");
    }
  }

  void _handleVoiceAgentStartMessage() {
    print("🎤 Voice agent start command received from controller");
    onVoiceAgentStart?.call();
  }

  void _handleModeMessage(Map<String, dynamic> msg) {
    try {
      final mode = msg['data'] as String;
      print("🎮 Mode command received: $mode");
      switch (mode) {
        case 'launch':
          onLaunch?.call();
          break;
        case 'start':
          onStart?.call();
          break;
        case 'play':
          onPlay?.call();
          break;
        case 'pause':
          onPause?.call();
          break;
        case 'exit':
          onExit?.call();
          break;
        case 'wander_start':
          onWanderStart?.call();
          break;
        case 'wander_stop':
          onWanderStop?.call();
          break;
      }
    } catch (e) {
      print("⚠️ Error parsing mode command: $e");
    }
  }

  void _handleRefreshMessage() {
    print("🔄 AI refresh command received from controller");
    onRefresh?.call();
  }

  void _handleSpeakMessage(Map<String, dynamic> msg) {
    final text = msg['data'] as String? ?? '';
    if (text.isNotEmpty) {
      print("🔊 Speak command from controller: $text");
      onSpeakCommand?.call(text);
    }
  }

  void _handleWaypointsMessage(Map<String, dynamic> msg) {
    try {
      final data = jsonDecode(msg['data']);
      final parsedWaypoints = (data['waypoints'] as List)
          .map((w) => Waypoint.fromJson(w as Map<String, dynamic>))
          .toList();
      
      // Sort so default waypoint appears first
      parsedWaypoints.sort((a, b) {
        if (a.isDefault && !b.isDefault) return -1;
        if (!a.isDefault && b.isDefault) return 1;
        return 0;
      });
      
      // Store in central storage
      waypoints = parsedWaypoints;
      
      print('📍 [RosBridge] Waypoints updated: ${waypoints.length} points, notifying ${_waypointListeners.length} listeners');
      
      // Notify multi-listeners
      for (final listener in _waypointListeners) {
        listener(waypoints);
      }
      
      // Legacy callback (backward compatibility)
      onWaypointsUpdate?.call(waypoints);
    } catch (e) {
      print("⚠️ Error parsing waypoints: $e");
    }
  }
  
  void _handleSequencesMessage(Map<String, dynamic> msg) {
    try {
      final data = jsonDecode(msg['data']);
      final parsedSequences = (data['sequences'] as List).map((s) => SavedSequence(
        name: s['name'] as String,
        waypointNames: List<String>.from(s['waypoints'] as List),
      )).toList();
      
      // Store in central storage
      sequences = parsedSequences;
      
      print('📍 [RosBridge] Sequences updated: ${sequences.length} tasks, notifying ${_sequenceListeners.length} listeners');
      
      // Notify multi-listeners
      for (final listener in _sequenceListeners) {
        listener(sequences);
      }
      
      // Legacy callback (backward compatibility)
      onSequencesUpdate?.call(sequences);
    } catch (e) {
      print("⚠️ Error parsing sequences: $e");
    }
  }

  void _handleActionsMessage(Map<String, dynamic> msg) {
    try {
      final data = jsonDecode(msg['data']);
      final parsedActions = (data['actions'] as List)
          .map((a) => ActionDefinition.fromJson(a as Map<String, dynamic>))
          .toList();
      
      // Store in central storage
      actions = parsedActions;
      
      print('📍 [RosBridge] Actions updated: ${actions.length} actions, notifying ${_actionListeners.length} listeners');
      
      // Notify multi-listeners
      for (final listener in _actionListeners) {
        listener(actions);
      }
      
      // Legacy callback (backward compatibility)
      onActionsUpdate?.call(actions);
    } catch (e) {
      print("⚠️ Error parsing actions: $e");
    }
  }

  void _handleHistoryMessage(Map<String, dynamic> msg) {
    try {
      final data = jsonDecode(msg['data']);
      final parsedHistory = (data['history'] as List)
          .map((h) => HistoryEntry.fromJson(h as Map<String, dynamic>))
          .toList();

      history = parsedHistory;
      print('📍 [RosBridge] History updated: ${history.length} entries');

      for (final listener in _historyListeners) {
        listener(history);
      }
    } catch (e) {
      print("⚠️ Error parsing history: $e");
    }
  }

  void _handleAgentsMessage(Map<String, dynamic> msg) {
    try {
      final data = jsonDecode(msg['data']);
      final parsedAgents = (data['agents'] as List)
          .map((a) => AgentDefinition.fromJson(a as Map<String, dynamic>))
          .toList();

      // Store in central storage
      agents = parsedAgents;

      // Save to local cache
      LocalCacheService.saveAgents(agents);

      print('📍 [RosBridge] Agents updated: ${agents.length} agents, notifying ${_agentListeners.length} listeners');

      // Notify multi-listeners
      for (final listener in _agentListeners) {
        listener(agents);
      }

      // Legacy callback (backward compatibility)
      onAgentsUpdate?.call(agents);
    } catch (e) {
      print("⚠️ Error parsing agents: $e");
    }
  }

  void _handleUserProfileMessage(Map<String, dynamic> msg) {
    try {
      final data = jsonDecode(msg['data']);
      final profileData = data['user_profile'] as Map<String, dynamic>?;
      if (profileData != null) {
        userProfile = UserProfile.fromJson(profileData);

        // Save to local cache
        LocalCacheService.saveUserProfile(userProfile!);

        print('📍 [RosBridge] User profile updated: ${userProfile!.username}');

        // Notify listeners
        for (final listener in _userProfileListeners) {
          listener(userProfile!);
        }
      }
    } catch (e) {
      print("⚠️ Error parsing user profile: $e");
    }
  }

  void _handleMemoriesMessage(Map<String, dynamic> msg) {
    try {
      final data = jsonDecode(msg['data']);
      final memoryData = data['memories'] as Map<String, dynamic>?;
      if (memoryData != null) {
        // Store in central storage
        memories = MemoryData.fromJson(memoryData);

        // Save to local cache
        LocalCacheService.saveMemories(memories!);

        print('📍 [RosBridge] Memories updated: ${memories!.owner.notes.length} owner notes, ${memories!.people.length} people, ${memories!.notes.length} notes');

        // Notify multi-listeners
        for (final listener in _memoryListeners) {
          listener(memories!);
        }
      }
    } catch (e) {
      print("⚠️ Error parsing memories: $e");
    }
  }

  void _handleLaserScanMessage(Map<String, dynamic> msg) {
    try {
      final angleMin = (msg['angle_min'] as num?)?.toDouble() ?? -3.14;
      final angleMax = (msg['angle_max'] as num?)?.toDouble() ?? 3.14;
      final angleIncrement = (msg['angle_increment'] as num?)?.toDouble() ?? 0.01;
      final rawRanges = msg['ranges'] as List?;
      
      if (rawRanges == null || rawRanges.isEmpty) return;
      
      final ranges = <double>[];
      for (final r in rawRanges) {
        if (r == null) {
          ranges.add(0.0);
        } else {
          final val = (r as num).toDouble();
          // Filter out inf/nan values
          if (val.isInfinite || val.isNaN || val > 10.0) {
            ranges.add(0.0);
          } else {
            ranges.add(val);
          }
        }
      }
      
      final scan = LaserScan(
        angleMin: angleMin,
        angleMax: angleMax,
        angleIncrement: angleIncrement,
        ranges: ranges,
      );
      
      // Store in central storage
      _currentLaserScan = scan;
      
      // Notify multi-listeners
      for (final listener in _laserScanListeners) {
        listener(scan);
      }
      
      // Legacy callback (backward compatibility)
      onLaserScanUpdate?.call(scan);
    } catch (e) {
      print("⚠️ Laser scan parse error: $e");
    }
  }

  void _handleMapMessage(Map<String, dynamic> msg) {
    try {
      final info = msg['info'];
      if (info == null) return;
      
      final width = info['width'] as int;
      final height = info['height'] as int;
      final resolution = (info['resolution'] as num).toDouble();
      final origin = info['origin']['position'];
      final originX = (origin['x'] as num).toDouble();
      final originY = (origin['y'] as num).toDouble();
      
      final rawData = msg['data'] as List?;
      if (rawData == null) return;
      
      final data = rawData.map((e) => (e as num).toInt()).toList();
      
      final mapData = MapData(
        width: width,
        height: height,
        resolution: resolution,
        originX: originX,
        originY: originY,
        data: data,
      );
      
      // Store in central storage
      _cachedMapData = mapData;
      
      print("🗺️ Map received: ${width}x${height}, notifying ${_mapListeners.length} listeners");
      
      // Notify multi-listeners
      for (final listener in _mapListeners) {
        listener(mapData);
      }
      
      // Legacy callback (backward compatibility)
      _onMapUpdate?.call(mapData);
    } catch (e) {
      print("⚠️ Error parsing map: $e");
    }
  }
  
  void _handleNavStatusMessage(Map<String, dynamic> msg) {
    try {
      final statusList = msg['status_list'] as List?;
      if (statusList == null || statusList.isEmpty) {
        // No active goals = idle
        if (_lastNavStatus != NavStatus.idle) {
          _lastNavStatus = NavStatus.idle;
          // Don't notify on becoming idle (that's just cleanup)
        }
        return;
      }
      
      // Get the most recent goal status (last in list)
      final latestGoal = statusList.last as Map<String, dynamic>;
      final statusCode = latestGoal['status'] as int;
      
      // Nav2 GoalStatus codes:
      // 1 = ACCEPTED, 2 = EXECUTING, 4 = SUCCEEDED, 5 = CANCELED, 6 = ABORTED
      NavStatus newStatus;
      switch (statusCode) {
        case 1:
        case 2:
          newStatus = NavStatus.executing;
          break;
        case 4:
          newStatus = NavStatus.succeeded;
          break;
        case 5:
          newStatus = NavStatus.canceled;
          break;
        case 6:
          newStatus = NavStatus.failed;
          break;
        default:
          newStatus = NavStatus.idle;
      }
      
      // Only notify on meaningful state changes
      if (newStatus != _lastNavStatus && newStatus != NavStatus.executing) {
        print("🎯 Nav status: $newStatus (code: $statusCode), notifying ${_navStatusListeners.length} listeners");
        
        // Notify multi-listeners
        for (final listener in _navStatusListeners) {
          listener(newStatus);
        }
        
        // Legacy callback (backward compatibility)
        onNavStatusUpdate?.call(newStatus);
      }
      _lastNavStatus = newStatus;
    } catch (e) {
      print("⚠️ Error parsing nav status: $e");
    }
  }

  void publishCmdVel(double x, double y) {
    if (_channel == null || !_connected) {
      return; // Silent - joystick sends many messages
    }

    const double maxLin = 0.60;
    const double maxAng = 0.7;

    final double linear = -y * maxLin;
    final double angular = -x * maxAng;

    final msg = {
      "op": "publish",
      "topic": "/cmd_vel",
      "msg": {
        "linear": {"x": linear, "y": 0.0, "z": 0.0},
        "angular": {"x": 0.0, "y": 0.0, "z": angular}
      }
    };

    _channel!.sink.add(jsonEncode(msg));
  }
  
  /// Send a navigation goal to Nav2
  void publishNavGoal(double x, double y, {double theta = 0.0}) {
    if (!_connected || _channel == null) {
      print("⚠️ Not connected to ROSBridge, skipping nav goal");
      return;
    }
    
    // Convert theta to quaternion (rotation around Z axis only)
    final double qz = _sin(theta / 2);
    final double qw = _cos(theta / 2);
    
    final msg = {
      "op": "publish",
      "topic": "/goal_pose",
      "msg": {
        "header": {
          "frame_id": "map",
        },
        "pose": {
          "position": {"x": x, "y": y, "z": 0.0},
          "orientation": {"x": 0.0, "y": 0.0, "z": qz, "w": qw}
        }
      }
    };
    
    print("🎯 Sending nav goal: ($x, $y, θ=$theta)");
    _channel!.sink.add(jsonEncode(msg));
  }
  
  /// Set initial pose estimate (for slam_toolbox localization)
  void publishInitialPose(double x, double y, {double theta = 0.0}) {
    if (!_connected || _channel == null) {
      print("⚠️ Not connected to ROSBridge, skipping initial pose");
      return;
    }
    
    // Convert theta to quaternion
    final double qz = _sin(theta / 2);
    final double qw = _cos(theta / 2);
    
    final msg = {
      "op": "publish",
      "topic": "/initialpose",
      "msg": {
        "header": {
          "frame_id": "map",
        },
        "pose": {
          "pose": {
            "position": {"x": x, "y": y, "z": 0.0},
            "orientation": {"x": 0.0, "y": 0.0, "z": qz, "w": qw}
          },
          "covariance": [0.25, 0.0, 0.0, 0.0, 0.0, 0.0,
                         0.0, 0.25, 0.0, 0.0, 0.0, 0.0,
                         0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                         0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                         0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                         0.0, 0.0, 0.0, 0.0, 0.0, 0.07]
        }
      }
    };
    
    print("📍 Setting initial pose: ($x, $y, θ=$theta)");
    _channel!.sink.add(jsonEncode(msg));
  }

  /// Navigate to a named waypoint
  void publishGoToWaypoint(String waypointName) {
    _publishSimple("/millie/waypoint/goto", waypointName);
  }
  
  /// Navigate through a sequence of waypoints (legacy)
  void publishNavigateSequence(List<String> waypointNames) {
    final sequenceStr = waypointNames.join(',');
    _publishSimple("/millie/waypoint/sequence", sequenceStr);
  }
  
  /// Execute a workflow (navigation + speak steps)
  /// History is logged on the robot when workflow is received
  void publishWorkflow(List<Map<String, String>> steps, {String source = 'user'}) {
    final Map<String, dynamic> data = {
      'steps': steps,
      'source': source,
    };
    final jsonStr = jsonEncode(data);
    _publishSimple("/millie/workflow/execute", jsonStr);
  }
  
  /// Cancel current workflow
  void publishWorkflowCancel() {
    _publishSimple("/millie/workflow/cancel", "cancel");
  }
  
  /// Pause current workflow
  void publishWorkflowPause() {
    _publishSimple("/millie/workflow/pause", "pause");
  }
  
  /// Resume paused workflow
  void publishWorkflowResume() {
    _publishSimple("/millie/workflow/resume", "resume");
  }
  
  /// Add steps to end of workflow
  void publishWorkflowAddSteps(List<Map<String, String>> steps) {
    final data = {'steps': steps};
    _publishSimple("/millie/workflow/add_steps", jsonEncode(data));
  }
  
  /// Insert steps at current position (next up)
  void publishWorkflowInsertSteps(List<Map<String, String>> steps) {
    final data = {'steps': steps};
    _publishSimple("/millie/workflow/insert_steps", jsonEncode(data));
  }
  
  /// Clear remaining workflow steps
  void publishWorkflowClear() {
    _publishSimple("/millie/workflow/clear", "clear");
  }
  
  /// Replace remaining workflow with new steps
  void publishWorkflowReplace(List<Map<String, String>> steps) {
    final data = {'steps': steps};
    _publishSimple("/millie/workflow/replace", jsonEncode(data));
  }
  
  /// Set default home location
  void publishWorkflowSetHome(String waypointName, bool autoReturn) {
    final data = {'location': waypointName, 'auto_return': autoReturn};
    _publishSimple("/millie/workflow/set_home", jsonEncode(data));
  }
  
  /// Notify robot that an action is complete
  void publishActionComplete(String actionName, {bool delivered = true}) {
    final data = jsonEncode({
      'name': actionName,
      'delivered': delivered,
    });
    _publishSimple("/millie/action/complete", data);
  }
  
  /// Save current robot position as a waypoint
  void publishSaveWaypoint(String name) {
    _publishSimple("/millie/waypoint/save", name);
  }
  
  /// Update a waypoint (e.g., to set as default)
  void publishUpdateWaypoint(Waypoint waypoint) {
    final json = jsonEncode(waypoint.toJson());
    _publishSimple("/millie/waypoint/update", json);
  }
  
  /// Set a waypoint as the default (home location)
  void publishSetDefaultWaypoint(String name) {
    // Find the waypoint and update with isDefault = true
    final waypoint = waypoints.firstWhere(
      (w) => w.name == name,
      orElse: () => Waypoint(name: '', x: 0, y: 0),
    );
    if (waypoint.name.isNotEmpty) {
      final updated = waypoint.copyWith(isDefault: true);
      publishUpdateWaypoint(updated);
    }
  }
  
  /// Delete a waypoint by name
  void publishDeleteWaypoint(String name) {
    _publishSimple("/millie/waypoint/delete", name);
  }
  
  /// Request waypoints list refresh
  void requestWaypoints() {
    _publishSimple("/millie/waypoint/list", "request");
  }
  
  /// Request saved sequences from robot
  void requestSequences() {
    _publishSimple("/millie/sequence/list", "request");
  }

  /// Save a sequence to the robot
  void publishSaveSequence(String name, List<String> waypointNames) {
    final json = jsonEncode({
      'name': name,
      'waypoints': waypointNames,
    });
    _publishSimple("/millie/sequence/save", json);
  }
  
  /// Delete a sequence from the robot
  void publishDeleteSequence(String name) {
    _publishSimple("/millie/sequence/delete", name);
  }
  
  /// Reorder sequences on the robot
  void publishReorderSequences(List<String> orderedNames) {
    final json = jsonEncode({
      'order': orderedNames,
    });
    _publishSimple("/millie/sequence/reorder", json);
  }
  
  /// Request saved actions from robot
  void requestActions() {
    _publishSimple("/millie/action/list", "request");
  }

  /// Request history from robot
  void requestHistory() {
    _publishSimple("/millie/history/list", "request");
  }

  /// Clear all history on robot
  void publishClearHistory() {
    _publishSimple("/millie/history/clear", "clear");
    history.clear();
    for (final listener in _historyListeners) {
      listener(history);
    }
  }

  /// Delete a specific history entry by timestamp
  void publishDeleteHistoryEntry(String timestamp) {
    _publishSimple("/millie/history/delete", timestamp);
  }

  /// Save an action to the robot
  void publishSaveAction(ActionDefinition action) {
    final json = jsonEncode(action.toJson());
    _publishSimple("/millie/action/save", json);
  }
  
  /// Delete an action from the robot
  void publishDeleteAction(String name) {
    _publishSimple("/millie/action/delete", name);
  }
  
  /// Reorder actions on the robot
  void publishReorderActions(List<String> orderedNames) {
    final json = jsonEncode({
      'order': orderedNames,
    });
    _publishSimple("/millie/action/reorder", json);
  }

  /// Save an AI agent to the robot
  void publishSaveAgent(AgentDefinition agent) {
    final json = jsonEncode(agent.toJson());
    print("📤 Publishing agent: $json");
    _publishSimple("/millie/agent/save", json);
  }
  
  /// Delete an AI agent from the robot
  void publishDeleteAgent(String name) {
    _publishSimple("/millie/agent/delete", name);
  }
  
  /// Request AI agents from robot
  void requestAgents() {
    _publishSimple("/millie/agent/list", "");
  }

  /// Save user profile to the robot
  void publishSaveUserProfile(UserProfile profile) {
    final json = jsonEncode(profile.toJson());
    print("📤 Publishing user profile: $json");
    _publishSimple("/millie/user_profile/save", json);
  }

  /// Request user profile from robot
  void requestUserProfile() {
    _publishSimple("/millie/user_profile/list", "");
  }

  /// Save memories to the robot
  void publishSaveMemories(MemoryData memoryData) {
    final json = jsonEncode(memoryData.toJson());
    print("📤 Publishing memories");
    _publishSimple("/millie/memories/save", json);
  }

  /// Request memories from robot
  void requestMemories() {
    _publishSimple("/millie/memories/list", "");
  }

  /// Cancel current navigation - calls Nav2 cancel service directly
  void publishCancelNav() {
    if (!_connected || _channel == null) return;
    
    // Call the Nav2 action cancel service directly via rosbridge
    // UUID of all zeros = cancel ALL active goals
    final cancelMsg = {
      "op": "call_service",
      "service": "/navigate_to_pose/_action/cancel_goal",
      "type": "action_msgs/srv/CancelGoal",
      "args": {
        "goal_info": {
          "goal_id": {"uuid": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]},
          "stamp": {"sec": 0, "nanosec": 0}
        }
      }
    };
    _channel!.sink.add(jsonEncode(cancelMsg));
    
    print("🛑 Cancelling navigation");
  }
  
  /// Emergency stop - cancel ALL autonomous movement
  void publishEstop() {
    if (!_connected || _channel == null) {
      print("⚠️ E-STOP FAILED - Not connected to ROSBridge!");
      return;
    }

    // Disable explore mode (wander + motion detector)
    disableExploreMode();

    // Cancel Nav2 navigation via service call
    publishCancelNav();

    // Publish pause mode to stop all autonomous behaviors
    _publishSimple("/millie/mode", "pause");

    // Send zero velocity to stop motion immediately
    final stopMsg = {
      "op": "publish",
      "topic": "/cmd_vel",
      "msg": {
        "linear": {"x": 0.0, "y": 0.0, "z": 0.0},
        "angular": {"x": 0.0, "y": 0.0, "z": 0.0}
      }
    };
    _channel!.sink.add(jsonEncode(stopMsg));

    print("🛑 E-STOP: Explore disabled + Nav cancelled + zero velocity sent");
  }
  
  double _sin(double x) {
    // Taylor series approximation
    return x - (x * x * x) / 6 + (x * x * x * x * x) / 120;
  }
  
  double _cos(double x) {
    // Taylor series approximation
    return 1 - (x * x) / 2 + (x * x * x * x) / 24;
  }

  void publishShutdown() {
    _publishSimple("/shutdown", "shutdown");
  }

  void publishWake() {
    _publishSimple("/millie/wake", "wake");
  }

  void publishSleep() {
    _publishSimple("/millie/sleep", "sleep");
  }

  // ✅ new agent publisher helpers
  void publishDefaultAgent() => _publishSimple("/millie/agent", "default");
  void publishGreeterAgent() => _publishSimple("/millie/agent", "greeter");
  void publishBartenderAgent() => _publishSimple("/millie/agent", "bartender");
  void publishHostAgent() => _publishSimple("/millie/agent", "host");

  // Voice state publishing (for controller sync)
  void publishVoicePlaying() => _publishSimple("/millie/voice/state", "playing");
  void publishVoicePaused() => _publishSimple("/millie/voice/state", "paused");
  void publishVoiceIdle() => _publishSimple("/millie/voice/state", "idle");

  // Workflow status publishing (for controller button sync fallback)
  void publishWorkflowIdle() {
    final msg = {
      "op": "publish",
      "topic": "/millie/workflow/status",
      "msg": {
        "data": '{"status": "idle", "step": 0, "total": 0}'
      }
    };
    _channel?.sink.add(jsonEncode(msg));
    print('📋 Published workflow idle status');
  }

  // Movement commands (for voice control)
  // Mode commands (pause, wander_start, wander_stop, turn_and_resume, etc.)
  void publishMode(String mode) => _publishSimple("/millie/mode", mode);

  // Commands: forward, back, left, right, spin_left, spin_right, stop
  void publishMove(String command) => _publishSimple("/millie/move", command);
  void publishMoveForward() => publishMove("forward");
  void publishMoveBack() => publishMove("back");
  void publishTurnLeft() => publishMove("left");
  void publishTurnRight() => publishMove("right");
  void publishSpinLeft() => publishMove("spin_left");
  void publishSpinRight() => publishMove("spin_right");
  void publishMoveStop() => publishMove("stop");

  // Wander mode control (wander only, no person detection)
  void publishWanderEnable() => _publishBool("/wander/enable", true);
  void publishWanderDisable() => _publishBool("/wander/enable", false);

  // Person follower control (NN-based person detection)
  void publishPersonFollowerEnable() => _publishBool("/person_follower/enable", true);
  void publishPersonFollowerDisable() => _publishBool("/person_follower/enable", false);
  void publishPersonFollower(bool enable) => _publishBool("/person_follower/enable", enable);

  // Center on human control (camera tracking)
  void publishCenterOnHuman(bool enable) => _publishBool("/oak/center_on_human", enable);

  // ===========================================================================
  // MODE CONTROL: Wander, Follow, Track, Patrol (mutually exclusive)
  // Centralized mode manager - ALWAYS stops all before starting new mode
  // ===========================================================================

  /// Internal: Stop ALL movement modes (called before any mode switch)
  void _stopAllMovementModes() {
    print('🛑 Stopping all movement modes');
    _publishBool("/wander/enable", false);
    _publishBool("/person_follower/enable", false);
    _publishBool("/oak/center_on_human", false);
  }

  /// Activate Wander mode (wander only, no person detection)
  void activateWanderMode() {
    print('🚶 Activating Wander mode (wander only)');
    _stopAllMovementModes();
    _publishBool("/wander/enable", true);
  }

  /// Deactivate Wander mode
  void deactivateWanderMode() {
    print('🛑 Deactivating Wander mode');
    _publishBool("/wander/enable", false);
  }

  /// Activate Follow mode (person detection + following, no wander)
  void activateFollowMode() {
    print('👤 Activating Follow mode');
    _stopAllMovementModes();
    _publishBool("/person_follower/enable", true);
  }

  /// Deactivate Follow mode
  void deactivateFollowMode() {
    print('🛑 Deactivating Follow mode');
    _publishBool("/person_follower/enable", false);
  }

  /// Activate Track mode (camera tracking, stationary)
  void activateTrackMode() {
    print('👁️ Activating Track mode (camera tracking)');
    _stopAllMovementModes();
    _publishBool("/oak/center_on_human", true);
  }

  /// Deactivate Track mode
  void deactivateTrackMode() {
    print('🛑 Deactivating Track mode');
    _publishBool("/oak/center_on_human", false);
  }

  /// Activate Patrol mode (wander + person detection combined)
  void activatePatrolMode() {
    print('🔍 Activating Patrol mode (wander + follow)');
    _stopAllMovementModes();
    _publishBool("/wander/enable", true);
    _publishBool("/person_follower/enable", true);
  }

  /// Deactivate Patrol mode
  void deactivatePatrolMode() {
    print('🛑 Deactivating Patrol mode');
    _publishBool("/wander/enable", false);
    _publishBool("/person_follower/enable", false);
  }

  /// Stop all autonomous modes (wander, follow, track)
  void deactivateAllModes() {
    _stopAllMovementModes();
  }

  // Legacy methods for backward compatibility
  @Deprecated('Use activatePatrolMode() instead')
  void enableExploreMode() {
    activatePatrolMode();
  }

  @Deprecated('Use deactivatePatrolMode() instead')
  void disableExploreMode() {
    deactivatePatrolMode();
  }

  void _publishBool(String topic, bool value) {
    if (_channel == null) {
      print('⚠️ Cannot publish to $topic - rosbridge not connected');
      return;
    }
    final msg = {
      "op": "publish",
      "topic": topic,
      "msg": {"data": value}
    };
    _channel!.sink.add(jsonEncode(msg));
    print('📤 Published $value to $topic');
  }

  // ✅ shared helper
  void _publishSimple(String topic, String data) {
    if (_channel == null) {
      print("⚠️ Not connected to ROSBridge, skipping publish for $topic");
      return;
    }
    
    print("🔌 _publishSimple: topic=$topic, connected=$_connected, channel=${_channel != null}");

    final msg = {
      "op": "publish",
      "topic": topic,
      "msg": {"data": data}
    };

    final jsonMsg = jsonEncode(msg);
    print("📤 Sending to $topic: $jsonMsg");
    _channel!.sink.add(jsonMsg);
  }

  void close() {
    try {
      _reconnectTimer?.cancel();
      _subscription?.cancel();
      _channel?.sink.close();
      _connected = false;
      print("👋 Disconnected from ROSBridge");
    } catch (e) {
      print("⚠️ Error closing ROSBridge: $e");
    }
  }
}
