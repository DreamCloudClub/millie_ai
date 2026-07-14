# Millie Bot System Information

This document contains comprehensive technical information about Millie Bot for self-reference during conversations. Use this to answer questions about your hardware, software, capabilities, and how you work.

---

## Overview

**Millie Bot** is an open-source social robot built for education and research. The project consists of three main components:

| Component | Description | Technology |
|-----------|-------------|------------|
| **millie_bot** | ROS2 robot package - navigation, sensors, motor control | ROS2 Humble, Python |
| **millie_ai** | Face tablet app - expressive face, voice AI, conversations | Flutter/Dart |
| **millie_control** | Controller tablet app - joystick, map, waypoints, AI chat | Flutter/Dart |

**Website**: https://DreamCloudClub.org

---

## Hardware Specifications

### Computing
- **Main Computer**: Geekom mini PC (x86_64)
- **Motor Controller**: Arduino Nano Every (USB serial @ 115200 baud)

### Drive System
- **Type**: Differential drive (two DC motors)
- **Wheel Base**: 0.33 meters
- **Wheel Radius**: 0.065 meters (6.5 cm)
- **Max Linear Speed**: 0.40 m/s
- **Max Angular Speed**: 1.5 rad/s

### Sensors

#### LiDAR
- **Model**: SLAMTEC C1
- **Baud Rate**: 460800
- **Range**: Up to 12 meters
- **Resolution**: ~0.05m at 5m distance
- **Mounting**: 0.4m forward, 0.3m above base
- **Note**: Mounted upside-down (180 degree rotation handled in software)

#### Camera
- **Model**: OAK-D Lite (DepthAI by Luxonis)
- **RGB Resolution**: 1080P sensor, output at 640x480 @ 15 FPS
- **Depth**: Stereo depth from dual mono cameras (400P resolution)
- **Depth Alignment**: Aligned to RGB camera for spatial detection
- **AI Accelerator**: Intel Myriad X VPU for on-device neural inference
- **Mounting**: 0.4m forward, 0.75m above base
- **Support**: https://docs.luxonis.com/

#### Person Detection
- **Model**: MobileNet-SSD (trained on COCO dataset)
- **Person Class ID**: 15 (COCO label for "person")
- **Confidence Threshold**: 0.5 (50%)
- **Depth Range**: 100mm to 5000mm (0.1m to 5m)
- **Output**: 3D spatial coordinates (x, y, z in meters)
- **Bounding Boxes**: Optional overlay on RGB stream
- **FPS**: Runs at camera FPS (15 FPS)

The neural network runs entirely on the OAK-D's Myriad X chip, requiring no GPU on the main computer. Detection results include:
- Person confidence score
- 3D position relative to camera (distance and lateral offset)
- Whether person is centered in frame
- Bounding box coordinates for visualization

### Tablets
- **Face Tablet**: Android tablet running millie_ai - displays expressive face, handles voice conversations
- **Controller Tablet**: Android tablet running millie_control - joystick, map view, waypoint management

---

## Arduino Motor Controller

The Arduino Nano Every serves as the motor controller, receiving commands from the ROS2 motor_node over USB serial and driving the DC motors via PWM.

### Hardware Connections

| Function | Pin | Description |
|----------|-----|-------------|
| Left Motor PWM | D6 | PWM signal via TCB0 timer |
| Left Motor Direction | D4 | HIGH = forward, LOW = reverse |
| Right Motor PWM | D3 | PWM signal via TCB1 timer |
| Right Motor Direction | D2 | HIGH = forward, LOW = reverse |
| USB Serial | - | 115200 baud to robot computer |

### Firmware Details

**Location**: `~/ros2_ws/src/millie_bot/firmware/arduino/millie_motor/millie_motor.ino`

**PWM Configuration**:
- Uses TCB0 timer for left motor (pin D6)
- Uses TCB1 timer for right motor (pin D3)
- 8-bit PWM mode (0-255 duty cycle)
- System clock with no prescaler for high-frequency PWM

**Serial Protocol**:
| Command | Format | Example | Description |
|---------|--------|---------|-------------|
| Motor | L <left> R <right>\n | L 50 R 50\n | Set motor duty (-100 to 100) |
| E-Stop Set | E 1\n | E 1\n | Activate emergency stop |
| E-Stop Clear | E 0\n | E 0\n | Clear emergency stop |

**Safety Features**:
- **Watchdog Timer**: 500ms timeout - if no command received, motors stop automatically
- **E-Stop**: When active, all motor commands are ignored (duty forced to 0)
- **Startup Message**: Prints "MILLIE MOTOR BRIDGE ACTIVE" on boot

### How to Flash the Arduino

**Prerequisites**:
- Arduino CLI installed (`arduino-cli`)
- Arduino megaAVR boards package installed

**Install Arduino CLI** (if needed):
```bash
curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | sh
sudo mv bin/arduino-cli /usr/local/bin/
```

**Install the board package**:
```bash
arduino-cli core update-index
arduino-cli core install arduino:megaavr
```

**Compile and upload**:
```bash
cd ~/ros2_ws/src/millie_bot/firmware/arduino/millie_motor
arduino-cli compile --fqbn arduino:megaavr:nona4809 .
arduino-cli upload --fqbn arduino:megaavr:nona4809 -p /dev/ttyACM0 .
```

**Verify upload**:
```bash
# Open serial monitor to see startup message
arduino-cli monitor -p /dev/ttyACM0 -c baudrate=115200
# Should print: "MILLIE MOTOR BRIDGE ACTIVE — FINAL BUILD"
```

**Test motor commands manually**:
```bash
# Send test command (50% forward on both motors)
echo "L 50 R 50" > /dev/ttyACM0

# Stop motors
echo "L 0 R 0" > /dev/ttyACM0
```

### Motor Control Flow

```
Joystick/Nav2
     │
     ▼
/cmd_vel (Twist message)
     │
     ▼
limiter_node (acceleration limiting, safety checks)
     │
     ▼
/cmd_vel_raw (Twist message)
     │
     ▼
motor_node (converts to differential drive)
     │
     ▼
USB Serial: "L <pct> R <pct>\n"
     │
     ▼
Arduino Nano Every
     │
     ▼
PWM to Motor Drivers → DC Motors
```

### Troubleshooting Arduino

**No response from Arduino**:
```bash
# Check if Arduino is detected
ls -la /dev/ttyACM*

# Check permissions
sudo usermod -a -G dialout $USER
# (logout and login again)

# Test serial connection
arduino-cli monitor -p /dev/ttyACM0 -c baudrate=115200
```

**Motors not moving**:
- Check E-stop is cleared (send "E 0\n")
- Verify motor driver power supply
- Check direction pin wiring (D4, D2)
- Check PWM pin wiring (D6, D3)

**Upload fails**:
```bash
# Reset Arduino by pressing reset button, then immediately upload
arduino-cli upload --fqbn arduino:megaavr:nona4809 -p /dev/ttyACM0 .
```

---

## Software Architecture

### ROS2 Network (millie_bot)

#### TF Tree (Coordinate Frames)
```
map (from slam_toolbox)
  - odom (from slam_toolbox)
      - base_link (from EKF filter)
          - base_scan (LiDAR frame)
          - oak-d-base-frame (Camera frame)
```

#### Core Nodes

| Node | Purpose |
|------|---------|
| motor_node | Differential drive control via Arduino serial |
| limiter_node | Velocity smoothing, acceleration limits, safety override |
| scan_filter_node | Filters LiDAR self-reflections (<0.42m), rotates 180 degrees |
| mode_manager_node | Controls operating mode (idle/mapping/navigating) |
| nav_command_node | Handles navigation goals, waypoints, sequences, actions, agents |
| workflow_executor_node | Executes multi-step workflows with navigation, delays, actions |
| oak_person_detector_node | MobileNet-SSD person detection on OAK-D |
| person_follower_node | Follows detected persons at configurable distance |
| center_on_human_node | Rotates to keep person centered in camera frame |
| lidar_person_tracker_node | Detects legs in LiDAR data |
| motion_detector_node | Depth frame differencing for movement detection |
| wander_node | Frontier exploration or random goal navigation |
| move_command_node | Direct movement commands from voice/UI |

#### Localization Stack
1. **LiDAR Driver** (sllidar_ros2) - publishes /scan
2. **Scan Filter** - removes self-hits, publishes /scan_filtered
3. **rf2o Odometry** - laser-based odometry, publishes /odom
4. **Command Odometry** - integrates cmd_vel for encoder-like estimate
5. **EKF Filter** (robot_localization) - fuses odometry sources, publishes TF
6. **SLAM Toolbox** - SLAM or localization mode, publishes /map and map to odom TF

#### Navigation Stack
- **Planner**: NavFn (A* algorithm)
- **Controller**: Regulated Pure Pursuit
- **Max Navigation Speed**: 0.3 m/s
- **Goal Tolerance**: XY 0.30m, Yaw 0.2 rad

---

## Communication Protocols

### ROSBridge WebSocket
- **Port**: 9090
- **Protocol**: WebSocket with JSON-encoded ROS messages
- **Purpose**: Tablet apps communicate with ROS2 via this bridge

### Boot Server HTTP API
- **Port**: 5050
- **Purpose**: System control (start/stop ROS, reboot, shutdown, map management)

### Video Streaming
- **Port**: 8080
- **Format**: MJPEG stream via web_video_server
- **Topic**: /oak/rgb/image_raw

### Arduino Serial Protocol
- **Baud**: 115200
- **Motor Command**: L <duty> R <duty> followed by newline (duty: -100 to 100)
- **Emergency Stop**: E 0 (clear) or E 1 (activate)
- **Watchdog**: 500ms timeout - motors stop if no command received

---

## Millie AI (Face Tablet App)

### Purpose
The face tablet displays an expressive animated face and handles AI-powered voice conversations. It runs on a tablet mounted on the robot facing outward toward users.

### Face Display

#### Eyes
- White rounded rectangles with glow effect
- Size: approximately 32% screen width, 28% screen height
- Gap between eyes: approximately 6% screen width
- **Animations**:
  - **Idle**: 30% glow intensity
  - **Listening**: 40% glow + breathing animation (3% scale, 2000ms cycle)
  - **Processing**: 50% glow, static
  - **Speaking**: 60% glow + pulse animation (6% scale, 800ms cycle)

#### Mouth
- Expandable container showing thought bubble / order items
- Closed: 16px pill-shaped container
- Open: Up to 200px with scrollable content
- Left-aligned text with 80px padding
- Animation: 450ms smooth transition

#### Animal Faces
12 pre-made animal faces available: cat, dog, bear, bee, bird, crocodile, elephant, fish, lion, lobster, reptile, tiger

### Voice Pipeline (Turn-Taking Mode)

1. **Listening**: Microphone captures audio with Voice Activity Detection
   - Amplitude threshold: -20dB
   - Auto-stops after 1.5s silence or 30s max
   - Minimum 300ms speech required

2. **Speech-to-Text**: OpenAI Whisper API transcribes audio

3. **LLM Processing**: Claude API generates response
   - Includes conversation history
   - System prompt defines personality (agent)
   - Can return tool calls for robot control

4. **Text-to-Speech**: OpenAI TTS API synthesizes speech
   - Voice configurable per agent (default: alloy)

5. **Playback**: Audio streams to speaker

### Conversation States
idle -> starting -> greeting -> listening -> processing -> speaking -> complete/idle

### Status Indicator
Bottom-center pill showing: "Ready", "Listening...", "Speaking...", "Thinking...", "Paused"

### Control Bar (Long-Press Overlay)
- **Top Row**: Follow, Track, Home buttons
- **Bottom Row**: Play, Pause, Refresh, Exit buttons

### Gestures
- **Tap**: Show control bar (or pause if active)
- **Double-tap**: Start/resume/pause conversation
- **Long-press**: Show control bar

### Pages

| Page | Purpose |
|------|---------|
| FacePage | Full-screen face display with animated eyes/mouth |
| HomePage | Main navigation hub, orchestrates all communication |
| LaunchPage | Agent selection - shows current agent, launch/start buttons |
| LocationsPage | Waypoint management, task builder, workflow execution |
| SettingsPage | Robot configuration, map management, agent settings |
| ActionEditorPage | Create/edit AI actions with multi-step conversations |

---

## Millie Control (Controller Tablet App)

### Purpose
Remote control interface for the robot operator. Provides manual control, navigation, and AI chat capabilities.

### Main Views

| View | Description |
|------|-------------|
| Camera | Live MJPEG video feed from OAK-D camera |
| Map | Real-time navigation map with robot pose, click-to-navigate |
| Locations | Waypoint management, task sequences, workflow builder |
| Chat | AI chatbot with text/voice input, function calling for robot control |
| Settings | Robot status, map management, agent configuration, memory |

### Joystick Panel
- Virtual on-screen joystick for manual control
- 9 configurable buttons in 3x3 grid
- Top rows: Mode controls (Launch, Start, Wander, Refresh, Play/Pause, Exit)
- Bottom row: Quick navigation buttons

### AI Integration
- **Model**: GPT-4o-mini
- **Speech-to-Text**: Whisper API
- **Text-to-Speech**: OpenAI TTS
- **Function Calling**: Can invoke robot navigation commands from natural language

---

## Autonomous Behaviors

### Person Following
- **Detection**: OAK-D MobileNet-SSD (confidence > 0.5)
- **Follow Distance**: 1.2 meters
- **Backup Distance**: 0.7 meters (starts reversing if closer)
- **Hard Stop**: 0.5 meters

### Leg Detection (LiDAR)
- Detects paired clusters at shin height (0.1-0.25m width)
- Gap between legs: 0.15-0.60m
- Rotates toward detected legs when follow/track mode active

### Motion Detection
- Depth frame differencing from OAK-D
- Threshold: 250mm depth change
- Minimum area: 25,000 pixels to trigger
- Approach speed: 0.25 m/s

### Exploration Modes
- **Frontier Exploration** (mapping mode): Navigates to unmapped areas
- **Wandering** (navigation mode): Random goals within 1-3m radius
- Can pause/resume on motion detection

---

## Movement Commands

Direct movement commands that can be triggered by voice or UI. These are simple, timed movements that don't require navigation or obstacle avoidance.

### Available Commands

| Command | Description | Duration |
|---------|-------------|----------|
| `forward` | Move forward | 1.5 seconds at 0.3 m/s |
| `back` | Move backward | 1.5 seconds at 0.3 m/s |
| `slight_left` | Small turn left | 45 degrees |
| `slight_right` | Small turn right | 45 degrees |
| `left` | Quarter turn left | 90 degrees |
| `right` | Quarter turn right | 90 degrees |
| `turn_around_left` | Half turn left | 180 degrees |
| `turn_around_right` | Half turn right | 180 degrees |
| `spin_left` | Full rotation left | 360 degrees |
| `spin_right` | Full rotation right | 360 degrees |
| `stop` | Immediate stop | - |

### Turn Angle Reference

| Angle | Commands | Voice Examples |
|-------|----------|----------------|
| 45° | `slight_left`, `slight_right` | "turn slightly left", "small turn right", "little turn left" |
| 90° | `left`, `right` | "turn left", "turn right", "turn to face left" |
| 180° | `turn_around_left`, `turn_around_right` | "turn around", "turn around to the left" |
| 360° | `spin_left`, `spin_right` | "spin around", "do a spin", "spin to the right" |

### Configuration

- **Linear Speed**: 0.3 m/s (forward/backward)
- **Turn Speed**: 0.8 rad/s (all rotations)
- **Turn durations** are calculated: `duration = angle_radians / turn_speed`

### ROS Interface

| Topic | Type | Description |
|-------|------|-------------|
| `/millie/move` | String | Send movement command |
| `/millie/move/status` | String | Movement status updates |

Status messages:
- `moving:<command>` - Currently executing a movement
- `idle` - Ready for next command

### AI Tool Integration

The `move_robot` tool allows the AI to invoke these commands during conversation:

```json
{
  "name": "move_robot",
  "parameters": {
    "direction": "left"
  }
}
```

Valid directions: `forward`, `back`, `slight_left`, `slight_right`, `left`, `right`, `turn_around_left`, `turn_around_right`, `spin_left`, `spin_right`, `stop`

---

## Workflows

Multi-step task sequences that combine navigation, speech, and display changes.

### Step Types

| Type | Parameters | Description |
|------|------------|-------------|
| navigate | waypoint or x,y,theta | Go to location |
| action / prompt | action_name | Execute AI action/prompt |
| display | display_type | Change UI display |
| delay | seconds | Wait for duration |
| save_pose | name | Remember current position |

### Example Workflow
```json
{
  "name": "Kitchen Visit",
  "steps": [
    {"type": "save_pose", "name": "_start"},
    {"type": "navigate", "waypoint": "kitchen"},
    {"type": "action", "value": "greeting"},
    {"type": "delay", "seconds": 30},
    {"type": "navigate", "waypoint": "_start"}
  ]
}
```

---

## Agents (Personalities)

Agents define the robot's personality, voice, and behavior.

### Agent Properties
- **Name**: Identifier (e.g., "greeter", "bartender", "host")
- **Voice**: TTS voice selection (alloy, echo, fable, onyx, nova, shimmer)
- **Face ID**: Which face to display (robot face or animal face)
- **Voice Mode**: turn_taking (traditional) or realtime (streaming)
- **Personality Prompt**: System prompt defining behavior
- **Intro Message**: What to say when starting

---

## Memory System

The robot maintains persistent memories:

### Memory Types
- **Owner Profile**: Notes about the owner/operator
- **Known People**: Database of people with relationships, interests, notes
- **General Notes**: Observations, facts, and learned information

### Memory Tools (AI Functions)
- save_person(name, relationship, notes) - Remember someone
- save_note(content, category) - Record observation
- recall_person(name) - Look up known person
- recall_notes() - List memories
- update_person_note() - Add to person's notes

---

## ROS Topics Reference

### Motor Control
| Topic | Type | Description |
|-------|------|-------------|
| /cmd_vel | Twist | Velocity commands from nav/teleop |
| /cmd_vel_raw | Twist | Rate-limited output to motors |
| /estop | Bool | Emergency stop signal |

### Sensors
| Topic | Type | Description |
|-------|------|-------------|
| /scan | LaserScan | Raw LiDAR data |
| /scan_filtered | LaserScan | Filtered LiDAR (no self-hits) |
| /oak/rgb/image_raw | Image | RGB video |
| /oak/stereo/image_raw | Image | Depth image |
| /oak/nn/spatial_detections | Detection3DArray | Person detections with 3D position |

### Localization
| Topic | Type | Description |
|-------|------|-------------|
| /odom | Odometry | Laser-based odometry |
| /pose | PoseWithCovarianceStamped | SLAM pose estimate |
| /map | OccupancyGrid | Occupancy grid map |

### Millie Control Topics
| Topic | Description |
|-------|-------------|
| /millie/mode/set | Set mode: idle, mapping, navigating |
| /millie/nav/goal | Navigation goal (waypoint name or x,y) |
| /millie/waypoint/save | Save current pose as waypoint |
| /millie/workflow/execute | Execute multi-step workflow |
| /millie/speak | Text for robot to speak |
| /person_follower/enable | Enable/disable person following |
| /oak/center_on_human | Enable/disable centering on human |

---

## Network Configuration

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

| Device | IP | Port | Purpose |
|--------|-----|------|---------|
| Robot (Geekom PC) | 192.168.0.157 | - | ROS2, sensors, motors |
| ROSBridge | 192.168.0.157 | 9090 | WebSocket for tablet communication |
| Boot Server | 192.168.0.157 | 5050 | HTTP API for system control |
| Video Stream | 192.168.0.157 | 8080 | MJPEG camera feed |
| Face Tablet | WiFi (dynamic) | - | Millie AI app |
| Controller Tablet | WiFi (dynamic) | - | Millie Control app |

**Deployment:**
1. Configure TP-Link to connect to location's WiFi (via TP-Link app)
2. Robot ethernet stays at 192.168.0.157 - no configuration needed
3. Users connect tablets to "millie network 5G" and run the app

**Developer SSH Access:**
The robot also maintains a WiFi connection to the office network for remote SSH access, independent of the TP-Link network.

### Future Setup (Mobile + Indoor)

For outdoor/mobile operation and seamless indoor transitions, we use a portable network that travels with the robot:

```
┌─────────────────────────────────────────────────────────────┐
│                      NETWORK TOPOLOGY                        │
│                                                              │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐   │
│  │   Robot     │     │    WiFi     │     │   WiFi      │   │
│  │  Computer   │◄───►│    Hub      │◄───►│  Extender   │   │
│  │ 192.168.x.x │     │  (SIM Card) │     │ (Indoor AP) │   │
│  └─────────────┘     └─────────────┘     └─────────────┘   │
│        ▲                   ▲                    ▲           │
│        │                   │                    │           │
│        ▼                   ▼                    ▼           │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐   │
│  │    Face     │     │ Controller  │     │   Local     │   │
│  │   Tablet    │     │   Tablet    │     │   WiFi      │   │
│  └─────────────┘     └─────────────┘     └─────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

**WiFi Hub with SIM Card**:
- Creates a mobile hotspot that travels with the robot
- SIM card provides cellular data for internet connectivity
- Works outdoors or in locations without local WiFi
- All robot devices (computer, tablets) connect to this hub
- Maintains consistent IP addresses regardless of location

**WiFi Extender**:
- Bridges to local WiFi networks when indoors
- Provides internet access through the building's network
- Robot's internal network remains on the WiFi hub
- Allows faster internet speeds when available
- Seamless transition between cellular and local WiFi

**Benefits**:
- Robot can operate anywhere with cellular coverage
- No need to reconfigure IPs when moving locations
- Indoor operation gets faster internet through local WiFi
- Outdoor operation falls back to cellular data
- All three devices (robot, face tablet, controller) stay connected

---

## Safety Features

- **E-Stop Button**: Prominent on controller app, cancels navigation, zeros velocity
- **Deadman Timeout**: 300ms without command stops motors
- **Arduino Watchdog**: 500ms timeout stops motors
- **Velocity Limiter**: Enforces acceleration/deceleration limits
- **LiDAR Safety**: Can slow or stop on obstacle detection

---

## Troubleshooting

### Clean Shutdown
```bash
~/ros2_ws/src/millie_bot/scripts/kill_millie.sh
```

### Check Status
```bash
ros2 node list
ros2 topic list
ros2 topic echo /millie/mode/status
```

### View TF Tree
```bash
ros2 run tf2_tools view_frames
```

### Systemd Service
```bash
sudo systemctl status millie_bot.service
sudo journalctl -u millie_bot.service -f
```

---

## File Locations

| Item | Path |
|------|------|
| Main Launch | ~/ros2_ws/src/millie_bot/launch/main.launch.py |
| Arduino Firmware | ~/ros2_ws/src/millie_bot/firmware/arduino/millie_motor/ |
| Configuration | ~/ros2_ws/src/millie_bot/config/millie.yaml |
| ROS Nodes | ~/ros2_ws/src/millie_bot/millie_bot/*.py |
| Maps | ~/ros2_ws/src/millie_bot/maps/ |
| Waypoints | ~/.config/millie/waypoints.yaml |
| Face App | ~/projects/millie_ai/ |
| Controller App | ~/projects/millie_control/ |

---

## Version Info

- **ROS Version**: ROS2 Humble
- **Flutter**: 3.9+
- **Dart**: 3.9+
- **License**: Educational Use (apps), Apache-2.0 (ROS package)

---

## Resources and Support Links

### Millie Bot Project
- **Website**: https://DreamCloudClub.org
- **GitHub**: https://github.com/DreamCloudClub

### Hardware Documentation

| Component | Documentation |
|-----------|---------------|
| **OAK-D Lite Camera** | https://docs.luxonis.com/hardware/products/OAK-D%20Lite |
| **DepthAI SDK** | https://docs.luxonis.com/develop/getting-started/ |
| **DepthAI Python API** | https://docs.luxonis.com/software/depthai/depthai-python-api-overview/ |
| **Luxonis Support** | https://discuss.luxonis.com/ |
| **SLAMTEC C1 LiDAR** | https://www.slamtec.com/en/C1 |
| **Arduino Nano Every** | https://docs.arduino.cc/hardware/nano-every/ |
| **Arduino CLI** | https://arduino.github.io/arduino-cli/ |

### ROS2 Documentation

| Component | Documentation |
|-----------|---------------|
| **ROS2 Humble** | https://docs.ros.org/en/humble/ |
| **Nav2 Navigation** | https://docs.nav2.org/ |
| **SLAM Toolbox** | https://github.com/SteveMacenski/slam_toolbox |
| **ROSBridge** | https://github.com/RobotWebTools/rosbridge_suite |
| **robot_localization (EKF)** | https://docs.ros.org/en/humble/p/robot_localization/ |
| **rf2o_laser_odometry** | https://github.com/MAPIRlab/rf2o_laser_odometry |

### AI and Voice Services

| Service | Documentation |
|---------|---------------|
| **OpenAI Whisper (STT)** | https://platform.openai.com/docs/guides/speech-to-text |
| **OpenAI TTS** | https://platform.openai.com/docs/guides/text-to-speech |
| **Claude API (LLM)** | https://docs.anthropic.com/en/docs |
| **OpenAI Chat (GPT)** | https://platform.openai.com/docs/guides/chat |

### Flutter Development

| Resource | Link |
|----------|------|
| **Flutter SDK** | https://docs.flutter.dev/ |
| **Dart Language** | https://dart.dev/guides |
| **Flutter Packages** | https://pub.dev/ |

### Neural Network Models

| Model | Description |
|-------|-------------|
| **MobileNet-SSD** | Object detection model used for person detection |
| **COCO Dataset** | Training dataset with 80 object classes (person = class 15) |
| **Blob Converter** | https://blobconverter.luxonis.com/ (convert models for Myriad X) |

---

*This document is for Millie Bot's AI system to reference when answering questions about itself.*
