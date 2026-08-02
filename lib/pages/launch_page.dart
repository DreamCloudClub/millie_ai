import 'package:flutter/material.dart';
import '../utils/constants.dart';
import '../utils/rosbridge.dart';

/// Launch Robot page - Agent profile card with Launch/Start buttons
/// Launch = full startup sequence with greeting
/// Start = quick transition to face, no sound
class LaunchPage extends StatefulWidget {
  final RosBridge rosBridge;
  final VoidCallback onLaunch;
  final VoidCallback onStart;

  const LaunchPage({
    super.key,
    required this.rosBridge,
    required this.onLaunch,
    required this.onStart,
  });

  @override
  State<LaunchPage> createState() => _LaunchPageState();
}

class _LaunchPageState extends State<LaunchPage> {
  // Agent info from robot
  String _robotName = 'Millie';
  String _selectedAgent = '';
  String _selectedVoice = 'nova';
  String _selectedVoiceMode = 'turn_taking';
  String _selectedFaceId = '';


  // Multi-listener reference
  late final void Function(List<AgentDefinition>) _agentListener;

  @override
  void initState() {
    super.initState();
    _setupListeners();
  }

  void _setupListeners() {
    // Agents listener - get all info from the default agent
    _agentListener = (agents) {
      if (mounted && agents.isNotEmpty) {
        setState(() {
          final defaultAgent = agents.where((a) => a.isDefault).firstOrNull ?? agents.first;
          _robotName = defaultAgent.name;
          _selectedAgent = defaultAgent.name;
          _selectedFaceId = defaultAgent.faceId;
          _selectedVoice = defaultAgent.voice.isNotEmpty ? defaultAgent.voice : 'nova';
          _selectedVoiceMode = defaultAgent.voiceMode.isNotEmpty ? defaultAgent.voiceMode : 'turn_taking';
        });
      }
    };
    widget.rosBridge.addAgentListener(_agentListener);

    // Request initial data
    widget.rosBridge.requestAgents();
  }

  @override
  void dispose() {
    widget.rosBridge.removeAgentListener(_agentListener);
    super.dispose();
  }

  Widget _buildRobotFace() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Eyes
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 380 * 0.24,
              height: 380 * 0.32,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(380 * 0.024),
              ),
            ),
            SizedBox(width: 380 * 0.08),
            Container(
              width: 380 * 0.24,
              height: 380 * 0.32,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(380 * 0.024),
              ),
            ),
          ],
        ),
        SizedBox(height: 380 * 0.12),
        // Mouth
        Container(
          width: 380 * 0.32,
          height: 380 * 0.025,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(380 * 0.0125),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Agent Profile Card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.xl),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(AppRadius.medium),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Card title (left aligned with padding)
                  const Padding(
                    padding: EdgeInsets.only(left: AppSpacing.sm),
                    child: Text(
                      'Agent Profile',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  const Divider(color: AppColors.border, height: 1),
                  const SizedBox(height: AppSpacing.xl),
                  // Face Preview (proportional like millie_mini, size 380)
                  Center(
                    child: Container(
                      width: 380,
                      height: 380,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(380 * 0.08),
                      ),
                      child: _buildRobotFace(),
                    ),
                  ),

                  const SizedBox(height: AppSpacing.xl),

                  // Agent details
                  _DetailRow(label: 'Agent', value: _selectedAgent.isNotEmpty ? _selectedAgent : _robotName),
                  _DetailRow(label: 'Voice', value: _selectedVoice),
                  _DetailRow(label: 'Mode', value: _selectedVoiceMode == 'realtime' ? 'Realtime' : 'Turn Taking'),

                  const SizedBox(height: AppSpacing.xl),

                  // Launch and Play Buttons
                  Row(
                    children: [
                      // Launch Button (Green) - Full startup sequence
                      Expanded(
                        child: GestureDetector(
                          onTap: widget.onLaunch,
                          child: Container(
                            height: 60,
                            decoration: BoxDecoration(
                              color: AppColors.success.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(AppRadius.medium),
                              border: Border.all(color: AppColors.success, width: 2),
                            ),
                            child: Center(
                              child: Text(
                                'Launch',
                                style: TextStyle(
                                  color: AppColors.success,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(width: AppSpacing.md),

                      // Start Button (Blue) - Quick transition to face, no sound
                      Expanded(
                        child: GestureDetector(
                          onTap: widget.onStart,
                          child: Container(
                            height: 60,
                            decoration: BoxDecoration(
                              color: AppColors.accent.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(AppRadius.medium),
                              border: Border.all(color: AppColors.accent, width: 2),
                            ),
                            child: Center(
                              child: Text(
                                'Start',
                                style: TextStyle(
                                  color: AppColors.accent,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 16,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
