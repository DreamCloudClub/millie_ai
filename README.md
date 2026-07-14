# Millie AI

The expressive face and voice interface for Millie Bot. This Flutter app runs on a tablet mounted on the robot, displaying animated eyes and mouth while handling AI-powered conversations.

![Flutter](https://img.shields.io/badge/Flutter-3.9+-02569B?logo=flutter)
![Dart](https://img.shields.io/badge/Dart-3.9+-0175C2?logo=dart)
![License](https://img.shields.io/badge/License-Educational_Use-blue)

---

### Learn more at **https://DreamCloudClub.org**

This project is part of the **Millie Bot** ecosystem — an educational robotics platform for learning ROS, Flutter, and AI integration:

| Project | Description |
|---------|-------------|
| **[Millie Bot](https://github.com/DreamCloudClub/millie_bot)** | ROS2 package - navigation, sensors, motor control |
| **Millie AI** | This app — expressive face and voice AI for the robot |
| **[Millie Control](https://github.com/DreamCloudClub/millie_control)** | Remote control interface with joystick, map, and AI chat |

---

## What This App Does

Millie AI transforms a tablet into the robot's face and voice. When mounted on the robot facing outward, it:

- **Displays an animated face** with expressive eyes and mouth
- **Listens and responds** using speech-to-text, LLM, and text-to-speech
- **Shows visual feedback** — eyes pulse when speaking, breathe when listening
- **Executes workflows** — multi-step tasks combining navigation and speech
- **Remembers people** — persistent memory of conversations and relationships

## Screenshots

*Coming soon — face display, control overlay, animal faces*

## Features

### Animated Face Display
- **Eyes**: White rounded rectangles with dynamic glow effects
  - Breathing animation while listening
  - Pulsing animation while speaking
  - Glow intensity reflects conversation state
- **Mouth**: Expandable thought bubble showing processed items
- **Animal Faces**: 12 alternative faces (cat, dog, bear, lion, etc.)
- **Status Indicator**: Bottom pill showing "Ready", "Listening...", "Speaking...", "Thinking..."

### Voice Conversation
- **Speech-to-Text**: OpenAI Whisper API
- **LLM Processing**: Claude API with conversation history and tool calling
- **Text-to-Speech**: OpenAI TTS with configurable voices
- **Voice Activity Detection**: Automatic speech detection with silence timeout
- **Turn-Taking Mode**: Traditional back-and-forth conversation
- **Realtime Mode**: Streaming/continuous voice (experimental)

### Robot Control
- **Control Bar**: Long-press overlay with Follow, Track, Home, Play, Pause, Refresh, Exit
- **Gesture Control**: Tap to show controls, double-tap to play/pause
- **Workflow Execution**: Navigate to locations and speak on arrival
- **AI Tool Calling**: Voice commands can trigger navigation and actions

### Agents (Personalities)
- Multiple personality profiles with different voices and behaviors
- Configurable system prompts, intro messages, and face selection
- Stored on robot and synced via ROS

### Memory System
- Remember people with relationships and notes
- Save general observations and facts
- AI can recall memories during conversations

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     MILLIE AI (Face Tablet)                      │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │   FacePage   │  │ Conversation │  │   Workflow   │          │
│  │  Eyes/Mouth  │  │   Service    │  │   Handler    │          │
│  │  Animations  │  │  STT/LLM/TTS │  │  Nav+Speak   │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│           │                │                │                   │
│           └────────────────┼────────────────┘                   │
│                            │                                    │
│                    ┌───────▼───────┐                           │
│                    │   RosBridge   │                           │
│                    │   WebSocket   │                           │
│                    └───────┬───────┘                           │
└────────────────────────────┼────────────────────────────────────┘
                             │ ws://192.168.0.157:9090
                             ▼
┌────────────────────────────────────────────────────────────────┐
│                    MILLIE BOT (ROS2)                            │
│  Nav2, SLAM, Waypoints, Workflows, Agents, Person Detection    │
└────────────────────────────────────────────────────────────────┘
                             ▲
                             │ ws://192.168.0.157:9090
┌────────────────────────────┼───────────────────────────────────┐
│                    MILLIE CONTROL (Controller Tablet)           │
│  Joystick, Map View, Waypoint Editor, Mode Switching, AI Chat  │
└────────────────────────────────────────────────────────────────┘
```

## Network Setup

### Current Setup (TP-Link Travel Router)
The robot uses a TP-Link AX1500 travel router as a dedicated network hub:

```
┌─────────────────────────────────────────────────────────────┐
│                      NETWORK TOPOLOGY                        │
│                                                              │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐   │
│  │   Robot     │     │  TP-Link    │     │   Local     │   │
│  │  Computer   │◄───►│   AX1500    │◄───►│   WiFi      │   │
│  │ 192.168.0.157│ ETH │  (Router)   │WiFi │  (Office)   │   │
│  └─────────────┘     └─────────────┘     └─────────────┘   │
│        ▲                   ▲                                │
│        │                   │ WiFi                           │
│        ▼                   ▼                                │
│  ┌─────────────┐     ┌─────────────┐                       │
│  │    Face     │     │ Controller  │                       │
│  │   Tablet    │     │   Tablet    │                       │
│  └─────────────┘     └─────────────┘                       │
│                                                              │
│  Robot: Static IP 192.168.0.157 via Ethernet                │
│  Tablets: Connect to TP-Link WiFi "millie network 5G"       │
│  TP-Link: Bridges to local WiFi for internet                │
└─────────────────────────────────────────────────────────────┘
```

**Network Details:**
- **Robot IP**: 192.168.0.157 (static, ethernet connection)
- **TP-Link WiFi**: SSID "millie network 5G" / Password "milliebot1!"
- **Gateway**: 192.168.0.1

**Deployment:**
1. Configure TP-Link to connect to location's WiFi (via TP-Link app)
2. Robot ethernet stays at 192.168.0.157 - no configuration needed
3. Users connect tablets to "millie network 5G" and run the app

**Developer SSH Access:**
The robot also maintains a WiFi connection to the office network for remote SSH access, independent of the TP-Link network.

## Communication

### To Robot (via ROSBridge)
| Topic | Purpose |
|-------|---------|
| /millie/mode | Send mode commands (launch, start, play, pause, exit) |
| /millie/nav/goal | Request navigation to waypoint |
| /millie/workflow/execute | Start multi-step workflow |
| /cmd_vel | Direct velocity commands (from control bar) |
| /person_follower/enable | Enable/disable person following |

### From Robot (via ROSBridge)
| Topic | Purpose |
|-------|---------|
| /millie/workflow/status | Workflow progress updates |
| /millie/agents | Agent definitions |
| /millie/waypoints | Available waypoints |
| /millie/action/execute | Action triggered from controller |
| /pose | Robot position for location awareness |

### To Controller
The face tablet publishes voice state so the controller knows when AI is active:
| Topic | Purpose |
|-------|---------|
| /millie/voice/playing | Currently speaking |
| /millie/voice/paused | Conversation paused |
| /millie/voice/idle | Ready for input |

## Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) 3.9+
- Android tablet (tested on Samsung Galaxy Tab)
- OpenAI API key (for Whisper STT and TTS)
- Anthropic API key (for Claude LLM)
- Running Millie Bot with ROSBridge on port 9090

## Setup

### 1. Clone the repository

```bash
git clone https://github.com/DreamCloudClub/millie_ai.git
cd millie_ai
```

### 2. Install dependencies

```bash
flutter pub get
```

### 3. Configure environment

Create a `.env` file with your API keys:

```env
OPENAI_API_KEY=sk-your-openai-key
ANTHROPIC_API_KEY=sk-ant-your-anthropic-key
```

### 4. Configure robot connection

The robot IP is configured in `lib/pages/home_page.dart`:

```dart
final rosBridge = RosBridge('ws://192.168.0.157:9090');
```

Update this if your robot uses a different IP address.

### 5. Run the app

```bash
flutter run
```

Or build an APK for the tablet:

```bash
flutter build apk --release
```

## Project Structure

```
lib/
├── main.dart                 # App entry point, orientation, brightness
├── pages/
│   ├── home_page.dart        # Main orchestrator, ROS connection, mode handling
│   ├── face_page.dart        # Animated face display (eyes, mouth, status)
│   ├── launch_page.dart      # Agent selection, startup buttons
│   ├── locations_page.dart   # Waypoint and workflow management
│   ├── settings_page.dart    # Robot configuration
│   └── action_editor_page.dart # Create/edit AI actions
├── services/
│   ├── conversation_service.dart  # Orchestrates voice pipeline
│   ├── voice_pipeline_service.dart # STT → LLM → TTS flow
│   ├── realtime_voice_service.dart # Streaming voice (experimental)
│   ├── workflow_tools.dart        # AI tools for robot control
│   ├── memory_tools.dart          # AI tools for memory access
│   ├── location_service.dart      # Track robot location
│   └── local_cache_service.dart   # Offline data persistence
├── widgets/
│   ├── control_bar.dart      # Long-press overlay controls
│   ├── icon_rail.dart        # Bottom navigation bar
│   └── top_notification.dart # Toast notifications
└── utils/
    ├── rosbridge.dart        # WebSocket ROS communication
    ├── robot_api.dart        # HTTP API for system control
    └── constants.dart        # Colors, dimensions, timing
```

## Usage

### Starting a Conversation
1. **Launch**: Runs full startup sequence with motion test
2. **Start**: Quick start with short intro, no motion test
3. **Double-tap face**: Toggle play/pause

### Control Bar (Long-Press)
- **Follow**: Enable person following mode
- **Track**: Center camera on detected human
- **Home**: Navigate to home waypoint
- **Play**: Start/resume conversation
- **Pause**: Pause conversation
- **Refresh**: Clear conversation context
- **Exit**: Return to dashboard

### Workflow Execution
Workflows are triggered from the controller tablet or via AI commands. The face shows progress and speaks at designated steps.

## Configuration

### Face Animation Timing
In `lib/pages/face_page.dart`:
- Eye pulse (speaking): 800ms cycle
- Eye breathing (listening): 2000ms cycle
- Mouth animation: 450ms transition

### Voice Pipeline
In `lib/services/voice_pipeline_service.dart`:
- Silence timeout: 1.5 seconds
- Max recording: 30 seconds
- Min speech duration: 300ms

## Troubleshooting

### No connection to robot
- Verify robot IP in `home_page.dart`
- Ensure ROSBridge is running: `ros2 launch rosbridge_server rosbridge_websocket_launch.xml`
- Check both devices are on same network

### Voice not working
- Check microphone permissions on tablet
- Verify API keys in `.env` file
- Check internet connectivity for API calls

### Face not animating
- Ensure conversation service is started
- Check callback connections in `home_page.dart`

## Resources and Support

### Voice AI Services
| Service | Documentation |
|---------|---------------|
| **OpenAI Whisper (STT)** | https://platform.openai.com/docs/guides/speech-to-text |
| **OpenAI TTS** | https://platform.openai.com/docs/guides/text-to-speech |
| **Claude API (LLM)** | https://docs.anthropic.com/en/docs |

### Robot Communication
| Component | Documentation |
|-----------|---------------|
| **ROSBridge** | https://github.com/RobotWebTools/rosbridge_suite |
| **OAK-D Lite Camera** | https://docs.luxonis.com/ |
| **Luxonis Forum** | https://discuss.luxonis.com/ |

### Flutter Development
| Resource | Link |
|----------|------|
| **Flutter SDK** | https://docs.flutter.dev/ |
| **Dart Language** | https://dart.dev/guides |
| **Flutter Packages** | https://pub.dev/ |

## License

**Educational Use Only** — Free for personal, educational, and hobbyist use. Commercial use is not permitted.

---

Made with care by [Dream Cloud Club](https://DreamCloudClub.org)
