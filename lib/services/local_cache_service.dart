import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/rosbridge.dart';

/// Service for caching agents, user profile, and memories locally.
/// ROS remains source of truth - when connected, ROS data overwrites local cache.
class LocalCacheService {
  static const String _agentsKey = 'cached_agents';
  static const String _userProfileKey = 'cached_user_profile';
  static const String _memoriesKey = 'cached_memories';

  // ============================================================
  // Agents
  // ============================================================

  /// Load cached agents from SharedPreferences
  static Future<List<AgentDefinition>> loadAgents() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_agentsKey);

    if (jsonStr == null) {
      return [];
    }

    try {
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      return jsonList
          .map((j) => AgentDefinition.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error loading cached agents: $e');
      return [];
    }
  }

  /// Save agents to local cache
  static Future<void> saveAgents(List<AgentDefinition> agents) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(agents.map((a) => a.toJson()).toList());
    await prefs.setString(_agentsKey, jsonStr);
    print('💾 Cached ${agents.length} agents');
  }

  // ============================================================
  // User Profile
  // ============================================================

  /// Load cached user profile from SharedPreferences
  static Future<UserProfile?> loadUserProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_userProfileKey);

    if (jsonStr == null) {
      return null;
    }

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      return UserProfile.fromJson(json);
    } catch (e) {
      print('Error loading cached user profile: $e');
      return null;
    }
  }

  /// Save user profile to local cache
  static Future<void> saveUserProfile(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(profile.toJson());
    await prefs.setString(_userProfileKey, jsonStr);
    print('💾 Cached user profile: ${profile.username}');
  }

  // ============================================================
  // Memories
  // ============================================================

  /// Load cached memories from SharedPreferences
  static Future<MemoryData?> loadMemories() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_memoriesKey);

    if (jsonStr == null) {
      return null;
    }

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      return MemoryData.fromJson(json);
    } catch (e) {
      print('Error loading cached memories: $e');
      return null;
    }
  }

  /// Save memories to local cache
  static Future<void> saveMemories(MemoryData memories) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(memories.toJson());
    await prefs.setString(_memoriesKey, jsonStr);
    print('💾 Cached memories: ${memories.owner.notes.length} owner notes, ${memories.people.length} people, ${memories.notes.length} notes');
  }

  // ============================================================
  // Utility
  // ============================================================

  /// Clear all cached data
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_agentsKey);
    await prefs.remove(_userProfileKey);
    await prefs.remove(_memoriesKey);
    print('🗑️ Cleared all cached data');
  }
}
