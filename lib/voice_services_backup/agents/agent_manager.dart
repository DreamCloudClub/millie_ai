// lib/agents/agent_manager.dart
import 'default_agent.dart';
import 'hotel_agent.dart';
import 'host_agent.dart';

class AgentManager {
  // Singleton (optional — keeps one consistent state across the app)
  static final AgentManager instance = AgentManager._internal();
  AgentManager._internal();

  // Available agents
  final _agents = {
    'default': DefaultAgent(),
    'hotel': HotelAgent(),
    'host': HostAgent(),
  };

  // Current active agent
  String _activeId = 'default';

  // Get active agent instance
  dynamic get activeAgent => _agents[_activeId];

  // Get greeting and persona directly
  String get greeting => activeAgent.greeting;
  Map<String, String> get personaMessage => activeAgent.personaMessage;

  // Switch agent
  void setActive(String id) {
    if (_agents.containsKey(id)) {
      _activeId = id;
      print('[AgentManager] Active agent set to: $_activeId');
    } else {
      print('[AgentManager] Unknown agent id: $id');
    }
  }

  // Get current active id
  String get activeId => _activeId;

  // List all agent ids (for UI buttons, debugging, etc.)
  List<String> get availableAgents => _agents.keys.toList();
}
