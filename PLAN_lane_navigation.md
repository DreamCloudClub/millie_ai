# Lane Navigation Feature Plan

## Goal
Draw a lane/path on the map in millie_control, and the robot automatically follows it when navigating to any destination.

## User Experience
1. Tap "Draw Lane" button in map controls
2. Drag finger across map to draw the path
3. Tap "Save" to store, or "Clear" to redraw
4. Lane appears on map (persists across app restarts)
5. When robot navigates anywhere, it automatically joins and follows the lane

## Implementation

### Phase 1: millie_control (Flutter) - Draw & Save Lane

**File: `/home/millennial/projects/millie_control/lib/widgets/map_panel.dart`**

1. Add `MapMode.drawLane` to the enum
2. Add lane state:
   - `List<Offset> _lanePoints` - screen points being drawn
   - `List<Point>? _savedLane` - saved lane in map coordinates (from ROS)
3. Add gesture handling for draw mode:
   - `onPanStart` → clear `_lanePoints`, add first point
   - `onPanUpdate` → add points to `_lanePoints`
   - `onPanEnd` → show save/clear dialog
4. **Coordinate conversion** on save:
   - Convert screen `Offset` → map `Point` using existing `_screenToMap()` transform
   - Send map coordinates to ROS
5. Draw the lane in `_FullMapPainter`:
   - For `_savedLane`: convert map coords → screen coords, render as thick colored line
   - For `_lanePoints` (while drawing): render directly in screen coords
   - Use `canvas.drawPath()` with `Path..lineTo()` for smooth rendering
6. Add buttons to `_MapControls`:
   - "Draw Lane" - enters draw mode
   - "Clear" (visible in draw mode) - clears current drawing
   - "Delete Lane" (visible when lane exists) - removes saved lane
7. **Load lane on startup**: When ROS connection established, `_savedLane` populated from `/millie/lane` subscription

**File: `/home/millennial/projects/millie_control/lib/utils/rosbridge.dart`**

Add topics:
- Publish: `/millie/lane/save` - `std_msgs/String` (JSON array of `{x, y}` in map coords)
- Publish: `/millie/lane/delete` - `std_msgs/Empty`
- Subscribe: `/millie/lane` - `std_msgs/String` (JSON array, empty if no lane)

### Phase 2: millie_bot (ROS2) - Store Lane

**File: `/home/millennial/ros2_ws/src/millie_bot/millie_bot/nav_command_node.py`**

1. Add lane storage:
   - `self._lane: list[tuple[float, float]] = []`
   - `lane_file` parameter → `~/.config/millie/lane.yaml`
   - `_load_lane()` on startup
   - `_save_lane()` on modification
2. Add subscribers:
   - `/millie/lane/save` → parse JSON, save to file, update `self._lane`
   - `/millie/lane/delete` → clear lane, delete file
3. Add publisher:
   - `/millie/lane` → publish current lane on change and periodically (every 5s for late-joining clients)

### Phase 3: millie_bot (ROS2) - Auto-Routing

**File: `/home/millennial/ros2_ws/src/millie_bot/millie_bot/nav_command_node.py`**

Modify `_send_nav_goal()`:

```python
def _send_nav_goal(self, x: float, y: float, theta: float):
    if not self._lane:
        # No lane - direct navigation (current behavior)
        self._send_direct_nav_goal(x, y, theta)
        return

    dest = (x, y)
    robot_pos = (self._current_pose.x, self._current_pose.y)

    # Find closest lane points
    entry_idx, entry_dist = self._find_closest_lane_point(robot_pos)
    exit_idx, exit_dist = self._find_closest_lane_point(dest)

    direct_dist = self._distance(robot_pos, dest)

    # Skip lane if robot is closer to destination than to the lane,
    # or if destination is closer to robot than to its lane exit point
    if entry_dist > direct_dist or exit_dist > direct_dist:
        self._send_direct_nav_goal(x, y, theta)
        return

    # Build path through lane (handles bidirectional traversal)
    lane_segment = self._get_lane_segment(entry_idx, exit_idx)

    # Navigate through lane points, then to final destination
    waypoints = [(p[0], p[1], 0.0) for p in lane_segment]
    waypoints.append((x, y, theta))

    self._send_nav_through_poses(waypoints)
```

Helper methods:

```python
def _find_closest_lane_point(self, pos: tuple[float, float]) -> tuple[int, float]:
    """Returns (index, distance) of closest lane point."""
    min_dist = float('inf')
    min_idx = 0
    for i, lp in enumerate(self._lane):
        d = self._distance(pos, lp)
        if d < min_dist:
            min_dist = d
            min_idx = i
    return min_idx, min_dist

def _get_lane_segment(self, start_idx: int, end_idx: int) -> list[tuple[float, float]]:
    """Returns lane points from start to end, handling either direction."""
    if start_idx <= end_idx:
        return self._lane[start_idx:end_idx + 1]
    else:
        # Reverse traversal
        return self._lane[end_idx:start_idx + 1][::-1]

def _distance(self, p1: tuple[float, float], p2: tuple[float, float]) -> float:
    return math.sqrt((p1[0] - p2[0])**2 + (p1[1] - p2[1])**2)

def _send_nav_through_poses(self, poses: list[tuple[float, float, float]]):
    """Send NavigateThroughPoses action - robot flows through without stopping."""
    # Uses nav2_msgs/action/NavigateThroughPoses
    # Note: This is continuous motion, not stop-at-each-waypoint behavior
    ...
```

### Phase 4: Testing

1. Draw a lane in the control app
2. Verify lane appears on map after save
3. Close and reopen app - verify lane still visible
4. Send robot to a waypoint that benefits from lane
5. Verify robot joins lane, follows it, exits to destination
6. Test from different starting positions
7. Test when destination is closer than lane (should skip lane)
8. Test reverse direction on lane
9. Test lane deletion

## Files to Modify

| Project | File | Changes |
|---------|------|---------|
| millie_control | `lib/widgets/map_panel.dart` | Draw mode, lane rendering, coord transform, UI |
| millie_control | `lib/utils/rosbridge.dart` | Lane topics |
| millie_bot | `millie_bot/nav_command_node.py` | Lane storage, auto-routing logic |

## Scope
- millie_control: ~180 lines
- millie_bot: ~120 lines
- Total: ~300 lines

## Future Enhancements (not in v1)
- Lane editing (extend/modify existing lane)
- Multiple named lanes
- One-way lane enforcement
- Lane width visualization
