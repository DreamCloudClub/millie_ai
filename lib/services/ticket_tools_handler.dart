import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/ticket.dart';
import '../utils/rosbridge.dart';
import 'location_service.dart';

/// Result from an AI tool call
class ToolResult {
  final bool success;
  final String message;
  final Ticket? ticket;
  
  ToolResult({
    required this.success,
    required this.message,
    this.ticket,
  });
  
  Map<String, dynamic> toJson() => {
    'success': success,
    'message': message,
    if (ticket != null) 'ticket': ticket!.toJson(),
  };
}

/// Tool call from the LLM
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  
  ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
  
  factory ToolCall.fromJson(Map<String, dynamic> json) {
    final function = json['function'] as Map<String, dynamic>;
    return ToolCall(
      id: json['id'] as String,
      name: function['name'] as String,
      arguments: jsonDecode(function['arguments'] as String? ?? '{}'),
    );
  }
}

/// Handler for ticket operations via LLM function calling
class TicketToolsHandler {
  final RosBridge rosBridge;
  
  // Current ticket being built
  Ticket? _currentTicket;
  Ticket? get currentTicket => _currentTicket;
  
  // Delivery mode - when true, complete_order works without items
  bool isDeliveryMode = false;
  
  // Simple ticket counter - starts at 1, resets on refresh
  int _nextTicketNumber = 1;
  
  // Callbacks
  void Function(Ticket ticket)? onTicketCreated;
  void Function(Ticket ticket)? onTicketUpdated;
  void Function()? onOrderComplete;
  
  TicketToolsHandler({required this.rosBridge});
  
  /// Reset ticket counter to 1 (called on Refresh)
  void resetTicketCounter() {
    _nextTicketNumber = 1;
    debugPrint('🔄 Ticket counter reset to 1');
  }
  
  /// Set the next ticket number (for manual sync if needed)
  void setNextTicketNumber(int number) {
    _nextTicketNumber = number;
    debugPrint('📋 Ticket counter set to $number');
  }
  
  /// Get context about the current ticket for the system prompt
  String getActiveTicketContext() {
    if (_currentTicket == null) {
      return '\n\nNo order in progress. Start a new order when the customer requests items.';
    }
    
    final buffer = StringBuffer();
    buffer.writeln('\n\nCURRENT ORDER IN PROGRESS:');
    buffer.writeln('Ticket #${_currentTicket!.ticketNumber}');
    buffer.writeln('Location: ${_currentTicket!.locationName ?? "Unknown"}');
    if (_currentTicket!.items.isNotEmpty) {
      buffer.writeln('Items so far:');
      for (final item in _currentTicket!.items) {
        buffer.writeln('  - $item');
      }
    } else {
      buffer.writeln('No items added yet.');
    }
    return buffer.toString();
  }
  
  /// Tool definitions for the LLM
  static List<Map<String, dynamic>> get toolDefinitions => [
    {
      'type': 'function',
      'function': {
        'name': 'add_order_item',
        'description': 'Add an item to the current order. Use this when the customer orders something.',
        'parameters': {
          'type': 'object',
          'properties': {
            'item': {
              'type': 'string',
              'description': 'The item being ordered (e.g., "1x Cappuccino", "2x Blueberry Muffin")',
            },
          },
          'required': ['item'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'complete_order',
        'description': 'Finalize and save the current order. Use this when the customer confirms they are done ordering.',
        'parameters': {
          'type': 'object',
          'properties': {
            'confirmation_message': {
              'type': 'string',
              'description': 'A brief confirmation message to tell the customer (e.g., "Your order is confirmed!")',
            },
          },
          'required': [],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'cancel_order',
        'description': 'Cancel the current order without saving.',
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
        'name': 'get_order_summary',
        'description': 'Get a summary of the current order items.',
        'parameters': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
    },
  ];
  
  /// Execute a tool call
  Future<ToolResult> executeTool(ToolCall toolCall) async {
    debugPrint('TicketToolsHandler: Executing tool ${toolCall.name}');
    
    switch (toolCall.name) {
      case 'add_order_item':
        return _addOrderItem(toolCall.arguments);
      case 'complete_order':
        return await _completeOrder(toolCall.arguments);
      case 'cancel_order':
        return _cancelOrder();
      case 'get_order_summary':
        return _getOrderSummary();
      default:
        return ToolResult(
          success: false,
          message: 'Unknown tool: ${toolCall.name}',
        );
    }
  }
  
  ToolResult _addOrderItem(Map<String, dynamic> args) {
    var item = args['item'] as String? ?? '';
    
    // Clean up "1x" format to "1" (robot says "one ex" otherwise)
    item = item.replaceAllMapped(
      RegExp(r'^(\d+)x\s*', caseSensitive: false),
      (m) => '${m.group(1)} ',
    );
    
    if (item.isEmpty) {
      return ToolResult(
        success: false,
        message: 'No item specified.',
      );
    }
    
    // Create ticket if needed
    if (_currentTicket == null) {
      final locationService = LocationService.instance;
      _currentTicket = Ticket.create(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        ticketNumber: _nextTicketNumber,
        locationName: locationService.currentLocationName,
        returnPose: locationService.currentReturnPose,
        items: [],
        status: TicketStatus.open,
      );
      debugPrint('📝 Created new ticket #${_currentTicket!.ticketNumber}');
    }
    
    // Check for duplicate (case-insensitive)
    final itemLower = item.toLowerCase().trim();
    final isDuplicate = _currentTicket!.items.any(
      (existing) => existing.toLowerCase().trim() == itemLower
    );
    
    if (isDuplicate) {
      debugPrint('⚠️ Duplicate item ignored: $item');
      return ToolResult(
        success: true,
        message: 'Item already in order.',
        ticket: _currentTicket,
      );
    }
    
    // Add item
    final updatedItems = List<String>.from(_currentTicket!.items)..add(item);
    _currentTicket = _currentTicket!.copyWith(items: updatedItems);
    
    debugPrint('📝 Added item: $item');
    onTicketUpdated?.call(_currentTicket!);
    
    return ToolResult(
      success: true,
      message: 'Added "$item" to the order.',
      ticket: _currentTicket,
    );
  }
  
  Future<ToolResult> _completeOrder(Map<String, dynamic> args) async {
    debugPrint('🔍 complete_order called - currentTicket: ${_currentTicket?.items.length ?? 0} items, deliveryMode: $isDeliveryMode');
    
    // Delivery mode: no items needed, just confirm
    if (isDeliveryMode) {
      debugPrint('✅ Delivery confirmed');
      onOrderComplete?.call();
      return ToolResult(
        success: true,
        message: 'Delivery confirmed.',
      );
    }
    
    // Take Order mode: require items
    if (_currentTicket == null || _currentTicket!.items.isEmpty) {
      debugPrint('⚠️ No items in order - cannot complete');
      return ToolResult(
        success: false,
        message: 'No items in the order. Please add items first.',
      );
    }
    
    // Update title based on location and dedupe items as final safety
    final title = _currentTicket!.locationName ?? 'Custom Location';
    final dedupedItems = _currentTicket!.items.toSet().toList();  // Remove any duplicates
    final finalTicket = _currentTicket!.copyWith(title: title, items: dedupedItems);
    
    // Save to ROS
    rosBridge.publishSaveTicket(finalTicket.toJson());
    debugPrint('✅ Order completed and saved: ${finalTicket.items.length} items');
    
    onTicketCreated?.call(finalTicket);
    onOrderComplete?.call();
    
    // Increment counter for next ticket
    _nextTicketNumber++;
    
    // Clear current ticket
    final completedTicket = finalTicket;
    _currentTicket = null;
    
    return ToolResult(
      success: true,
      message: 'Order saved with ${completedTicket.items.length} items.',
      ticket: completedTicket,
    );
  }
  
  ToolResult _cancelOrder() {
    debugPrint('❌ Order cancelled - ending conversation');
    _currentTicket = null;
    
    // End the conversation just like complete_order
    onOrderComplete?.call();
    
    return ToolResult(
      success: true,
      message: 'No problem. Have a great day!',
    );
  }
  
  ToolResult _getOrderSummary() {
    if (_currentTicket == null || _currentTicket!.items.isEmpty) {
      return ToolResult(
        success: true,
        message: 'No items in the current order.',
      );
    }
    
    final summary = _currentTicket!.items.join(', ');
    return ToolResult(
      success: true,
      message: 'Current order: $summary',
      ticket: _currentTicket,
    );
  }
  
  /// Clear the current ticket (e.g., when conversation ends)
  void clear() {
    _currentTicket = null;
    isDeliveryMode = false;
  }
}

