import 'package:flutter/material.dart';
import '../utils/constants.dart';
import '../utils/rosbridge.dart';
import '../widgets/eyes_widget.dart';
import '../widgets/mouth_widget.dart';

/// Launch Robot page - Agent profile card with Launch button
/// Launches the Face display for customer interaction
class LaunchPage extends StatefulWidget {
  final RosBridge rosBridge;
  final VoidCallback onLaunch;

  const LaunchPage({
    super.key,
    required this.rosBridge,
    required this.onLaunch,
  });

  @override
  State<LaunchPage> createState() => _LaunchPageState();
}

class _LaunchPageState extends State<LaunchPage> {
  // Agent info from robot (loaded from Profile settings)
  String _robotName = 'Millie';
  String _robotIdentity = '';
  String _selectedAgent = '';
  String _selectedVoice = 'nova';
  
  // Multi-listener references
  late final void Function(CompanyInfoData) _companyInfoListener;
  late final void Function(List<AgentDefinition>) _agentListener;
  
  @override
  void initState() {
    super.initState();
    _setupListeners();
  }
  
  void _setupListeners() {
    // Company info listener
    _companyInfoListener = (info) {
      if (mounted) {
        setState(() {
          _robotName = info.robotName.isNotEmpty ? info.robotName : 'Millie';
          _robotIdentity = info.robotIdentity;
          _selectedVoice = info.voice.isNotEmpty ? info.voice : 'nova';
        });
      }
    };
    widget.rosBridge.addCompanyInfoListener(_companyInfoListener);
    
    // Agents listener
    _agentListener = (agents) {
      if (mounted && agents.isNotEmpty) {
        setState(() {
          final defaultAgent = agents.where((a) => a.isDefault).firstOrNull;
          _selectedAgent = defaultAgent?.name ?? agents.first.name;
        });
      }
    };
    widget.rosBridge.addAgentListener(_agentListener);
    
    // Request initial data
    widget.rosBridge.requestCompanyInfo();
    widget.rosBridge.requestAgents();
  }
  
  @override
  void dispose() {
    widget.rosBridge.removeCompanyInfoListener(_companyInfoListener);
    widget.rosBridge.removeAgentListener(_agentListener);
    super.dispose();
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
                      child: Column(
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
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: AppSpacing.xl),
                  
                  // Agent details
                  _DetailRow(label: 'Robot', value: _robotName),
                  if (_selectedAgent.isNotEmpty)
                    _DetailRow(label: 'Agent', value: _selectedAgent),
                  _DetailRow(label: 'Voice', value: _selectedVoice),
                  if (_robotIdentity.isNotEmpty)
                    _DetailRow(
                      label: 'Identity',
                      value: _robotIdentity.length > 50 
                          ? '${_robotIdentity.substring(0, 50)}...' 
                          : _robotIdentity,
                    ),
                  
                  const SizedBox(height: AppSpacing.xl),
                  
                  // Launch Button (Orange)
                  GestureDetector(
                    onTap: widget.onLaunch,
                    child: Container(
                      width: double.infinity,
                      height: 60,
                      decoration: BoxDecoration(
                        color: AppColors.danger,
                        borderRadius: BorderRadius.circular(AppRadius.medium),
                        border: Border.all(color: AppColors.dangerBright, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.danger.withOpacity(0.4),
                            blurRadius: 12,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Center(
                        child: Text(
                          'Launch',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
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


