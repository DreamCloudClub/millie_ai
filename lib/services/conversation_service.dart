import 'dart:async';
import 'package:flutter/foundation.dart';
import '../utils/rosbridge.dart';
import '../models/ticket.dart';
import 'voice_pipeline_service.dart';
import 'ticket_tools_handler.dart';
import 'workflow_tools.dart';

/// Conversation states
enum ConversationState {
  idle,
  starting,
  greeting,
  listening,
  processing,
  speaking,
  complete,
  cancelled,
}

/// Manages AI conversation flow using STT → LLM → TTS pipeline
/// Creates tickets automatically via LLM function calling
class ConversationService extends ChangeNotifier {
  final RosBridge rosBridge;
  
  // Voice pipeline
  late final VoicePipelineService _pipeline;
  late final TicketToolsHandler _ticketHandler;
  late final WorkflowTools _workflowTools;
  
  // Current state
  ConversationState _state = ConversationState.idle;
  ConversationState get state => _state;
  
  // Company info (for system prompt)
  CompanyInfoData? _companyInfo;
  
  // Agents map (for looking up by name)
  Map<String, AgentDefinition> _agents = {};
  
  // Actions map (for looking up by name and finding default)
  Map<String, ActionDefinition> _actions = {};
  
  // Current action being executed
  ActionDefinition? _currentAction;
  ActionDefinition? get currentAction => _currentAction;
  
  // Flag to prevent double-handling of action complete
  bool _actionCompleteHandled = false;
  
  // Current agent (looked up from action.agentName)
  AgentDefinition? _currentAgent;
  
  // Current ticket for delivery (if delivering)
  Ticket? _deliveryTicket;
  Ticket? get deliveryTicket => _deliveryTicket;
  
  // Callbacks for UI updates
  void Function(bool speaking)? onSpeakingChange;
  void Function(ConversationState state)? onStateChange;  // For face animations
  void Function()? onOrderStarted;
  void Function(String item)? onOrderItemAdded;
  void Function(Ticket ticket)? onOrderComplete;
  void Function(String text)? onBotText;
  void Function(String text)? onUserText;
  void Function(String status)? onStatus;
  void Function()? onPauseRequested;  // Called when user says "pause"
  
  ConversationService({required this.rosBridge}) {
    _ticketHandler = TicketToolsHandler(rosBridge: rosBridge);
    _workflowTools = WorkflowTools(rosBridge);
    _pipeline = VoicePipelineService();
    
    _setupPipelineCallbacks();
    _setupRosBridgeCallbacks();
    _setupTicketHandlerCallbacks();
    _setupWorkflowCallbacks();
  }
  
  void _setupPipelineCallbacks() {
    _pipeline.ticketToolsHandler = _ticketHandler;
    
    _pipeline.onStateChange = (state) {
      switch (state) {
        case VoiceState.idle:
          _setState(ConversationState.idle);
          break;
        case VoiceState.listening:
          _setState(ConversationState.listening);
          break;
        case VoiceState.processing:
          _setState(ConversationState.processing);
          break;
        case VoiceState.speaking:
          _setState(ConversationState.speaking);
          break;
      }
    };
    
    _pipeline.onTranscription = (text) {
      debugPrint('👤 User: $text');
      onUserText?.call(text);
    };
    
    _pipeline.onResponse = (text) {
      debugPrint('🤖 AI: $text');
      onBotText?.call(text);
    };
    
    _pipeline.onSpeaking = (speaking) {
      onSpeakingChange?.call(speaking);
    };
    
    _pipeline.onPauseRequested = () {
      debugPrint('⏸️ Pause requested via voice command');
      onPauseRequested?.call();
    };
    
    _pipeline.onError = (error) {
      debugPrint('❌ Pipeline error: $error');
      onStatus?.call('Error: $error');
    };
    
    _pipeline.onConversationComplete = () {
      debugPrint('✅ Conversation complete callback');
      // Skip if already handled by onOrderComplete
      if (_actionCompleteHandled) {
        debugPrint('⏭️ Action complete already handled - skipping');
        return;
      }
      _setState(ConversationState.complete);
      if (_currentAction != null) {
        rosBridge.publishActionComplete(_currentAction!.name);
      }
      // Reset state after a brief delay so next conversation can start
      Future.delayed(const Duration(milliseconds: 500), () {
        _reset();
        debugPrint('🔄 Conversation reset - ready for next action');
      });
    };
  }
  
  // Multi-listener references for cleanup
  late final void Function(CompanyInfoData) _companyInfoListener;
  late final void Function(List<AgentDefinition>) _agentListener;
  late final void Function(List<ActionDefinition>) _actionListener;
  late final void Function(List<Map<String, dynamic>>) _ticketListener;
  
  void _setupRosBridgeCallbacks() {
    // Listen for company info updates (multi-listener pattern)
    _companyInfoListener = (info) {
      _companyInfo = info;
      debugPrint('📋 ConversationService: Company info loaded');
    };
    rosBridge.addCompanyInfoListener(_companyInfoListener);
    
    // Listen for agents updates (multi-listener pattern)
    _agentListener = (agents) {
      _agents = {for (var a in agents) a.name: a};
      debugPrint('🤖 ConversationService: Agents loaded: ${_agents.keys.toList()}');
    };
    rosBridge.addAgentListener(_agentListener);
    
    // Listen for actions updates (multi-listener pattern)
    _actionListener = (actions) {
      _actions = {for (var a in actions) a.name: a};
      final defaultAction = actions.where((a) => a.isDefault).firstOrNull;
      debugPrint('🎯 ConversationService: Actions loaded: ${_actions.keys.toList()}');
      debugPrint('🎯 Default action: ${defaultAction?.name ?? "none"}');
    };
    rosBridge.addActionListener(_actionListener);
    
    // Listen for tickets (for display, not for counter sync)
    _ticketListener = (ticketsJson) {
      debugPrint('📋 Tickets loaded: ${ticketsJson.length}');
    };
    rosBridge.addTicketListener(_ticketListener);
    
    // Request data on startup
    rosBridge.requestTickets();
    rosBridge.requestAgents();
    rosBridge.requestActions();
  }
  
  void _setupTicketHandlerCallbacks() {
    _ticketHandler.onTicketCreated = (ticket) {
      debugPrint('✅ Ticket created: ${ticket.title}');
      onOrderComplete?.call(ticket);
    };
    
    _ticketHandler.onTicketUpdated = (ticket) {
      // Notify UI when items are added
      if (ticket.items.isNotEmpty) {
        onOrderItemAdded?.call(ticket.items.last);
      }
    };
    
    _ticketHandler.onOrderComplete = () {
      debugPrint('✅ Order flow complete - currentAction: ${_currentAction?.name}');
      _actionCompleteHandled = true;  // Prevent double-handling
      final actionName = _currentAction?.name;
      
      // Stop listening immediately so conversation doesn't continue
      _pipeline.stopConversation();
      debugPrint('🛑 Stopped conversation - waiting for TTS to finish...');
      
      // Wait for TTS to finish (fixed delay), then send action complete
      Future.delayed(const Duration(seconds: 5), () {
        debugPrint('📤 Sending action complete: $actionName');
        if (actionName != null) {
          rosBridge.publishActionComplete(actionName);
        }
        _reset();
      });
    };
  }
  
  void _setupWorkflowCallbacks() {
    _workflowTools.onWorkflowConfirmed = () {
      debugPrint('🚀 Workflow confirmed - stopping conversation immediately');
      _actionCompleteHandled = true;  // Prevent double-handling
      
      // Stop listening/speaking immediately - no more conversation
      // Workflow was already published by workflow_tools.confirm_and_execute
      _pipeline.stopConversation();
      debugPrint('🛑 Conversation stopped - workflow starting');
      
      // Reset conversation state (no delay needed - workflow starts now)
      _reset();
    };
  }
  
  /// Start a conversation with the given action
  /// Optionally pass a ticket for delivery context
  Future<void> startConversation(ActionDefinition action, {Ticket? ticket}) async {
    // If not idle, force reset (allows new workflow to interrupt pending cleanup)
    if (_state != ConversationState.idle) {
      debugPrint('⚠️ Conversation not idle (state: $_state) - forcing reset');
      await _pipeline.stopConversation();
      _reset();
    }
    
    _currentAction = action;
    _deliveryTicket = ticket;
    _ticketHandler.isDeliveryMode = ticket != null;  // Delivery has ticket context, Take Order doesn't
    
    // Configure tool handlers based on action type
    // Default Action (General Assistant) gets workflow control
    // Other actions get ticket tools only
    if (action.isDefault) {
      // Default Action: full workflow control + ticket capabilities
      _pipeline.workflowToolsHandler = _workflowTools;
      _pipeline.ticketToolsHandler = _ticketHandler;
      debugPrint('🧭 Enabled: workflow tools + ticket tools (Default Action)');
    } else {
      // Specialized actions: ticket tools only, no workflow control
      _pipeline.workflowToolsHandler = null;
      _pipeline.ticketToolsHandler = _ticketHandler;
      debugPrint('📋 Enabled: ticket tools only (${action.name})');
    }
    
    _setState(ConversationState.starting);
    
    // Look up agent by name if specified
    _currentAgent = null;
    if (action.agentName.isNotEmpty && _agents.containsKey(action.agentName)) {
      _currentAgent = _agents[action.agentName];
      debugPrint('🤖 Using agent: ${_currentAgent!.name}');
    } else if (action.agentName.isNotEmpty) {
      debugPrint('⚠️ Agent "${action.agentName}" not found');
    }
    
    debugPrint('🎬 Starting conversation: ${action.name}');
    if (ticket != null) {
      debugPrint('📦 With ticket context: ${ticket.title} (${ticket.items.length} items)');
    }
    onOrderStarted?.call();
    
    // Build system prompt (uses agent if available)
    final systemPrompt = buildSystemPrompt();
    
    // Get greeting and apply template substitution
    String greeting = action.openingGreeting.isNotEmpty 
        ? action.openingGreeting 
        : 'Hello! How can I help you today?';
    greeting = _substituteTemplateVariables(greeting);
    
    // Get voice
    final voice = getVoice();
    
    // Start the pipeline
    await _pipeline.startConversation(
      systemPrompt: systemPrompt,
      voice: voice,
      greeting: greeting,
    );
    
    _setState(ConversationState.listening);
  }
  
  /// Substitute template variables in text
  /// Supported: {robot_name}, {company_name}, {ticket.items}, {ticket.number}, {ticket.location}, {ticket.title}
  String _substituteTemplateVariables(String text) {
    // Robot/company variables (always available)
    if (_companyInfo != null) {
      text = text.replaceAll('{robot_name}', _companyInfo!.robotName.isNotEmpty ? _companyInfo!.robotName : 'Millie');
      text = text.replaceAll('{company_name}', _companyInfo!.companyName.isNotEmpty ? _companyInfo!.companyName : 'our establishment');
    } else {
      text = text.replaceAll('{robot_name}', 'Millie');
      text = text.replaceAll('{company_name}', 'our establishment');
    }
    
    if (_deliveryTicket == null) {
      // No ticket context - remove or replace with defaults
      text = text.replaceAll('{ticket.items}', 'your order');
      text = text.replaceAll('{ticket.number}', '');
      text = text.replaceAll('{ticket.location}', 'here');
      text = text.replaceAll('{ticket.title}', 'your order');
      return text;
    }
    
    final ticket = _deliveryTicket!;
    
    // Format items as readable list
    String itemsText;
    if (ticket.items.isEmpty) {
      itemsText = 'your order';
    } else if (ticket.items.length == 1) {
      itemsText = ticket.items.first;
    } else {
      final allButLast = ticket.items.sublist(0, ticket.items.length - 1).join(', ');
      itemsText = '$allButLast and ${ticket.items.last}';
    }
    
    text = text.replaceAll('{ticket.items}', itemsText);
    text = text.replaceAll('{ticket.number}', ticket.ticketNumber.toString());
    text = text.replaceAll('{ticket.location}', ticket.locationName ?? 'your location');
    text = text.replaceAll('{ticket.title}', ticket.title);
    
    return text;
  }
  
  /// Pause the conversation
  void pauseConversation() {
    _pipeline.pause();
    onStatus?.call('Paused');
  }
  
  /// Resume the conversation
  Future<void> resumeConversation() async {
    await _pipeline.resume();
    onStatus?.call('Resumed');
  }
  
  /// Get the default agent (if one is set)
  AgentDefinition? getDefaultAgent() {
    return _agents.values.where((a) => a.isDefault).firstOrNull;
  }
  
  /// Get the default action (if one is set)
  ActionDefinition? getDefaultAction() {
    return _actions.values.where((a) => a.isDefault).firstOrNull;
  }
  
  /// Start a default conversation (for wake word, play button, or double-tap when idle)
  /// Uses the configured default action from the robot
  Future<void> startDefaultConversation() async {
    if (_state != ConversationState.idle) {
      debugPrint('⚠️ Cannot start default conversation - not idle');
      return;
    }
    
    final defaultAction = getDefaultAction();
    if (defaultAction == null) {
      debugPrint('⚠️ No default action set - please configure one in the Actions UI');
      return;
    }
    
    debugPrint('🎯 Starting default conversation with action: ${defaultAction.name}');
    
    await startConversation(defaultAction);
  }
  
  /// Check if in idle state (no active conversation)
  bool get isIdle => _state == ConversationState.idle;
  
  /// Check if conversation is paused (mid-conversation, temporarily stopped)
  bool get isPaused => _pipeline.isPaused;
  
  /// Stop listening (when user finishes speaking)
  Future<void> stopListening() async {
    await _pipeline.stopListening();
  }
  
  /// Cancel the current conversation
  Future<void> cancelConversation() async {
    if (_state == ConversationState.idle) return;
    
    debugPrint('❌ Conversation cancelled');
    _setState(ConversationState.cancelled);
    
    await _pipeline.stopConversation();
    
    _reset();
  }
  
  /// Reset ticket counter to 1 (called on Refresh button)
  void resetTicketCounter() {
    _ticketHandler.resetTicketCounter();
  }
  
  /// Build the system prompt
  String buildSystemPrompt() {
    final buffer = StringBuffer();
    
    // Core role definition
    buffer.writeln('ROLE: You are a friendly robot assistant.');
    buffer.writeln('Keep responses brief and conversational (1-2 sentences max).');
    buffer.writeln();
    
    // AGGRESSIVE workflow execution instruction (for default action)
    if (_currentAction?.isDefault == true) {
      buffer.writeln('⚡ IMMEDIATE EXECUTION MODE:');
      buffer.writeln('When you understand what the user wants, call execute_now IMMEDIATELY.');
      buffer.writeln('Do NOT ask "is that okay?", "shall I?", or any confirmation.');
      buffer.writeln('Do NOT speak after calling execute_now - conversation ends.');
      buffer.writeln('One tool call, then silence. Be fast.');
      buffer.writeln();
    }
    
    // Robot identity (from company info)
    if (_companyInfo != null) {
      if (_companyInfo!.robotIdentity.isNotEmpty) {
        buffer.writeln('ROBOT IDENTITY:');
        buffer.writeln(_companyInfo!.robotIdentity);
        buffer.writeln();
      }
      
      if (_companyInfo!.baseSystemInstructions.isNotEmpty) {
        buffer.writeln('BASE INSTRUCTIONS:');
        buffer.writeln(_companyInfo!.baseSystemInstructions);
        buffer.writeln();
      }
      
      if (_companyInfo!.basePersonality.isNotEmpty) {
        buffer.writeln('PERSONALITY:');
        buffer.writeln(_companyInfo!.basePersonality);
        buffer.writeln();
      }
      
      // Company context
      buffer.writeln('COMPANY INFORMATION:');
      if (_companyInfo!.companyName.isNotEmpty) {
        buffer.writeln('Company: ${_companyInfo!.companyName}');
      }
      if (_companyInfo!.address.isNotEmpty) {
        buffer.writeln('Address: ${_companyInfo!.address}');
      }
      if (_companyInfo!.phone.isNotEmpty) {
        buffer.writeln('Phone: ${_companyInfo!.phone}');
      }
      buffer.writeln();
    }
    
    // Agent-specific context (from the agent referenced by action)
    if (_currentAgent != null) {
      buffer.writeln('AGENT ROLE: ${_currentAgent!.name}');
      if (_currentAgent!.description.isNotEmpty) {
        buffer.writeln(_currentAgent!.description);
      }
      buffer.writeln();
      
      if (_currentAgent!.systemInstructions.isNotEmpty) {
        buffer.writeln('AGENT INSTRUCTIONS:');
        buffer.writeln(_currentAgent!.systemInstructions);
        buffer.writeln();
      }
      
      if (_currentAgent!.personality.isNotEmpty) {
        buffer.writeln('AGENT PERSONALITY:');
        buffer.writeln(_currentAgent!.personality);
        buffer.writeln();
      }
      
      if (_currentAgent!.knowledgeFocus.isNotEmpty) {
        buffer.writeln('KNOWLEDGE FOCUS:');
        buffer.writeln(_currentAgent!.knowledgeFocus);
        buffer.writeln();
      }
    }
    
    // Action-specific context
    if (_currentAction != null) {
      if (_currentAction!.context.isNotEmpty) {
        buffer.writeln('ACTION CONTEXT:');
        buffer.writeln(_substituteTemplateVariables(_currentAction!.context));
        buffer.writeln();
      }
      
      buffer.writeln('CURRENT TASK: ${_currentAction!.name}');
      if (_currentAction!.description.isNotEmpty) {
        buffer.writeln(_substituteTemplateVariables(_currentAction!.description));
      }
      buffer.writeln();
      
      if (_currentAction!.confirmation.isNotEmpty) {
        buffer.writeln('When the task is complete, say: "${_substituteTemplateVariables(_currentAction!.confirmation)}"');
        buffer.writeln();
      }
    }
    
    // Ticket context (for delivery actions)
    if (_deliveryTicket != null) {
      buffer.writeln('DELIVERY CONTEXT:');
      buffer.writeln('You are delivering ticket #${_deliveryTicket!.ticketNumber}');
      buffer.writeln('Items: ${_deliveryTicket!.items.join(", ")}');
      if (_deliveryTicket!.locationName != null) {
        buffer.writeln('Location: ${_deliveryTicket!.locationName}');
      }
      buffer.writeln();
    }
    
    return buffer.toString();
  }
  
  /// Get the voice to use
  String getVoice() {
    const validVoices = ['alloy', 'ash', 'ballad', 'coral', 'echo', 'sage', 'shimmer', 'verse', 'nova', 'onyx'];
    
    if (_companyInfo != null && _companyInfo!.voice.isNotEmpty) {
      final voice = _companyInfo!.voice.toLowerCase();
      if (validVoices.contains(voice)) {
        return voice;
      }
      debugPrint('⚠️ Invalid voice "$voice", using alloy');
    }
    return 'alloy';
  }
  
  void _setState(ConversationState newState) {
    _state = newState;
    notifyListeners();
    onStateChange?.call(newState);  // Notify UI for face animations
    debugPrint('📍 Conversation state: ${newState.name}');
  }
  
  void _reset() {
    _currentAction = null;
    _currentAgent = null;
    _deliveryTicket = null;
    _actionCompleteHandled = false;
    _ticketHandler.clear();
    _workflowTools.clear();  // Clear pending workflow steps
    _setState(ConversationState.idle);
    debugPrint('🔄 Conversation fully reset');
  }
  
  @override
  void dispose() {
    rosBridge.removeCompanyInfoListener(_companyInfoListener);
    rosBridge.removeAgentListener(_agentListener);
    rosBridge.removeActionListener(_actionListener);
    rosBridge.removeTicketListener(_ticketListener);
    _workflowTools.dispose();
    _pipeline.dispose();
    super.dispose();
  }
}
