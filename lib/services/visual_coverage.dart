import 'dart:math' as math;
import 'dart:typed_data';
import '../utils/rosbridge.dart';

/// A single visual observation with pose and search results
class VisualObservation {
  final DateTime timestamp;
  final double x;
  final double y;
  final double headingDegrees;
  final double fovDegrees;

  // Search context
  final String? searchTarget;
  final bool targetVisible;
  final double confidence;
  final String? targetLocation;
  final bool possibleMatch;

  // Scene context
  final String scene;
  final String description;

  // The actual camera image captured at this pose
  final Uint8List? imageBytes;

  VisualObservation({
    required this.timestamp,
    required this.x,
    required this.y,
    required this.headingDegrees,
    this.fovDegrees = 72.0,
    this.searchTarget,
    this.targetVisible = false,
    this.confidence = 0.0,
    this.targetLocation,
    this.possibleMatch = false,
    this.scene = '',
    this.description = '',
    this.imageBytes,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'x': x,
    'y': y,
    'heading': headingDegrees,
    'fov': fovDegrees,
    'search_target': searchTarget,
    'target_visible': targetVisible,
    'confidence': confidence,
    'target_location': targetLocation,
    'possible_match': possibleMatch,
    'scene': scene,
    'description': description,
  };
}

/// An unseen region that needs visual inspection
class UnseenRegion {
  final String id;
  final double centroidX;
  final double centroidY;
  final double areaSqMeters;
  final double distanceFromRobot;
  final String directionFromRobot;

  UnseenRegion({
    required this.id,
    required this.centroidX,
    required this.centroidY,
    required this.areaSqMeters,
    required this.distanceFromRobot,
    required this.directionFromRobot,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'centroid': {'x': centroidX, 'y': centroidY},
    'area_sqm': areaSqMeters,
    'distance_meters': distanceFromRobot,
    'direction': directionFromRobot,
  };
}

/// Visual coverage map - tracks which areas have been visually inspected
class VisualCoverageMap {
  final int width;
  final int height;
  final double resolution;
  final double originX;
  final double originY;
  final List<int> seen;  // 0 = unseen, 1 = seen
  final List<int> occupancy;  // Reference to occupancy data for raycasting

  static const double cameraFovDegrees = 72.0;
  static const double maxVisibilityRange = 6.0;  // meters
  static const int occupiedThreshold = 50;

  VisualCoverageMap({
    required this.width,
    required this.height,
    required this.resolution,
    required this.originX,
    required this.originY,
    required this.occupancy,
  }) : seen = List.filled(width * height, 0);

  /// Create from MapData
  factory VisualCoverageMap.fromMapData(MapData map) {
    return VisualCoverageMap(
      width: map.width,
      height: map.height,
      resolution: map.resolution,
      originX: map.originX,
      originY: map.originY,
      occupancy: map.data,
    );
  }

  /// Convert world coordinates to map cell
  (int, int) worldToMap(double wx, double wy) {
    final mx = ((wx - originX) / resolution).round();
    final my = ((wy - originY) / resolution).round();
    return (mx, my);
  }

  /// Convert map cell to world coordinates
  (double, double) mapToWorld(int mx, int my) {
    final wx = mx * resolution + originX;
    final wy = my * resolution + originY;
    return (wx, wy);
  }

  /// Check if a cell is within bounds
  bool inBounds(int mx, int my) {
    return mx >= 0 && mx < width && my >= 0 && my < height;
  }

  /// Get cell index
  int cellIndex(int mx, int my) => my * width + mx;

  /// Check if a cell is occupied (wall/obstacle)
  bool isOccupied(int mx, int my) {
    if (!inBounds(mx, my)) return true;
    return occupancy[cellIndex(mx, my)] > occupiedThreshold;
  }

  /// Check if a cell is free space
  bool isFree(int mx, int my) {
    if (!inBounds(mx, my)) return false;
    final val = occupancy[cellIndex(mx, my)];
    return val >= 0 && val <= occupiedThreshold;
  }

  /// Mark a cell as seen
  void markSeen(int mx, int my) {
    if (inBounds(mx, my)) {
      seen[cellIndex(mx, my)] = 1;
    }
  }

  /// Check if a cell has been seen
  bool isSeen(int mx, int my) {
    if (!inBounds(mx, my)) return false;
    return seen[cellIndex(mx, my)] == 1;
  }

  /// Mark visibility cone from an observation using raycasting
  void markVisibilityCone(double robotX, double robotY, double headingDegrees) {
    final (startMx, startMy) = worldToMap(robotX, robotY);

    // Convert to radians
    final headingRad = headingDegrees * 3.14159 / 180.0;
    final halfFovRad = (cameraFovDegrees / 2) * 3.14159 / 180.0;

    // Number of rays to cast (more = finer resolution)
    const numRays = 60;
    final angleStep = (cameraFovDegrees * 3.14159 / 180.0) / numRays;

    for (int i = 0; i <= numRays; i++) {
      final angle = headingRad - halfFovRad + (i * angleStep);
      _castRay(startMx, startMy, angle);
    }
  }

  /// Cast a single ray and mark cells as seen until hitting obstacle
  void _castRay(int startMx, int startMy, double angleRad) {
    final maxRangeCells = (maxVisibilityRange / resolution).round();

    // Use Bresenham-like stepping
    final dx = math.cos(angleRad);
    final dy = math.sin(angleRad);

    double fx = startMx.toDouble();
    double fy = startMy.toDouble();

    for (int step = 0; step < maxRangeCells; step++) {
      fx += dx;
      fy += dy;

      final mx = fx.round();
      final my = fy.round();

      if (!inBounds(mx, my)) break;

      // Mark this cell as seen
      markSeen(mx, my);

      // Stop if we hit an obstacle
      if (isOccupied(mx, my)) break;
    }
  }

  /// Calculate coverage percentage (seen free space / total free space)
  double getCoveragePercent() {
    int totalFree = 0;
    int seenFree = 0;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        if (isFree(x, y)) {
          totalFree++;
          if (isSeen(x, y)) seenFree++;
        }
      }
    }

    if (totalFree == 0) return 100.0;
    return (seenFree / totalFree) * 100.0;
  }

  /// Find connected unseen regions in free space
  List<UnseenRegion> findUnseenRegions(double robotX, double robotY, double robotHeading) {
    // Track which cells have been assigned to a region
    final assigned = List.filled(width * height, false);
    final regions = <UnseenRegion>[];
    var regionId = 0;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        if (isFree(x, y) && !isSeen(x, y) && !assigned[cellIndex(x, y)]) {
          // Found start of new unseen region - flood fill
          final cells = <(int, int)>[];
          final queue = <(int, int)>[(x, y)];

          while (queue.isNotEmpty) {
            final (cx, cy) = queue.removeLast();
            if (!inBounds(cx, cy)) continue;
            if (assigned[cellIndex(cx, cy)]) continue;
            if (!isFree(cx, cy) || isSeen(cx, cy)) continue;

            assigned[cellIndex(cx, cy)] = true;
            cells.add((cx, cy));

            // Add neighbors
            queue.add((cx + 1, cy));
            queue.add((cx - 1, cy));
            queue.add((cx, cy + 1));
            queue.add((cx, cy - 1));
          }

          // Only include regions of meaningful size (> 0.5 sqm)
          final areaSqm = cells.length * resolution * resolution;
          if (areaSqm < 0.5) continue;

          // Calculate centroid
          double sumX = 0, sumY = 0;
          for (final (cx, cy) in cells) {
            sumX += cx;
            sumY += cy;
          }
          final centroidMx = sumX / cells.length;
          final centroidMy = sumY / cells.length;
          final (centroidWx, centroidWy) = mapToWorld(centroidMx.round(), centroidMy.round());

          // Calculate distance and direction from robot
          final dx = centroidWx - robotX;
          final dy = centroidWy - robotY;
          final distance = math.sqrt(dx * dx + dy * dy);

          // Calculate relative direction
          var angleToRegion = math.atan2(dy, dx) * 180.0 / 3.14159;
          var relativeAngle = angleToRegion - robotHeading;
          // Normalize to -180 to 180
          while (relativeAngle > 180) relativeAngle -= 360;
          while (relativeAngle < -180) relativeAngle += 360;

          String direction;
          if (relativeAngle.abs() < 30) {
            direction = 'ahead';
          } else if (relativeAngle.abs() > 150) {
            direction = 'behind';
          } else if (relativeAngle > 0) {
            direction = relativeAngle > 60 ? 'left' : 'ahead-left';
          } else {
            direction = relativeAngle < -60 ? 'right' : 'ahead-right';
          }

          regions.add(UnseenRegion(
            id: String.fromCharCode(65 + regionId),  // A, B, C, ...
            centroidX: centroidWx,
            centroidY: centroidWy,
            areaSqMeters: areaSqm,
            distanceFromRobot: distance,
            directionFromRobot: direction,
          ));
          regionId++;

          // Limit to top 10 regions
          if (regionId >= 10) break;
        }
      }
      if (regionId >= 10) break;
    }

    // Sort by size (largest first)
    regions.sort((a, b) => b.areaSqMeters.compareTo(a.areaSqMeters));

    return regions;
  }

  /// Get summary of unseen regions for prompt
  String getUnseenSummary(double robotX, double robotY, double robotHeading) {
    final regions = findUnseenRegions(robotX, robotY, robotHeading);
    if (regions.isEmpty) {
      return 'All areas have been visually explored.';
    }

    final buffer = StringBuffer('UNSEEN AREAS TO EXPLORE:\n');
    for (final region in regions.take(5)) {
      buffer.writeln('- ${region.directionFromRobot}: ${region.areaSqMeters.toStringAsFixed(1)} sqm, ${region.distanceFromRobot.toStringAsFixed(1)}m away');
    }
    buffer.writeln('\nCoverage: ${getCoveragePercent().toStringAsFixed(0)}%');
    return buffer.toString();
  }

  /// Suggest best direction to explore based on unseen regions
  String? suggestDirection(double robotX, double robotY, double robotHeading) {
    final regions = findUnseenRegions(robotX, robotY, robotHeading);
    if (regions.isEmpty) return null;

    // Find the largest unseen region that isn't behind us
    for (final region in regions) {
      if (region.directionFromRobot != 'behind') {
        return region.directionFromRobot;
      }
    }

    // If all regions are behind, suggest turning
    return 'turn around';
  }

  /// Suggest the best next viewpoint to observe unseen areas
  Map<String, dynamic>? suggestNextViewpoint(double robotX, double robotY, double robotHeading) {
    final regions = findUnseenRegions(robotX, robotY, robotHeading);
    if (regions.isEmpty) return null;

    // Try each unseen region until we find a valid viewpoint
    for (final target in regions) {
      final viewpoint = _findViewpointForRegion(target, robotX, robotY);
      if (viewpoint != null) return viewpoint;
    }

    return null;
  }

  /// Find a valid viewpoint to observe a specific unseen region
  Map<String, dynamic>? _findViewpointForRegion(UnseenRegion target, double robotX, double robotY) {
    final (targetMx, targetMy) = worldToMap(target.centroidX, target.centroidY);

    // Desired viewing distance: 1.5-2.5 meters from the region centroid
    const viewDistMin = 1.5;
    const viewDistMax = 2.5;
    final viewDistCells = ((viewDistMin + viewDistMax) / 2 / resolution).round();

    // Try 8 angles around the region to find a navigable viewpoint
    for (int angleIdx = 0; angleIdx < 8; angleIdx++) {
      final angle = angleIdx * 45.0 * 3.14159 / 180.0;

      // Calculate potential viewpoint position
      final viewMx = targetMx + (viewDistCells * math.cos(angle)).round();
      final viewMy = targetMy + (viewDistCells * math.sin(angle)).round();

      if (!inBounds(viewMx, viewMy)) continue;
      if (!isFree(viewMx, viewMy)) continue;
      if (!_isSafeCell(viewMx, viewMy, inflationCells: 3)) continue;

      // Check line-of-sight to target (no obstacles between viewpoint and target)
      if (!_hasLineOfSight(viewMx, viewMy, targetMx, targetMy)) continue;

      final (viewX, viewY) = mapToWorld(viewMx, viewMy);

      // Calculate heading to face the target region
      final headingToTarget = math.atan2(target.centroidY - viewY, target.centroidX - viewX) * 180.0 / 3.14159;

      return {
        'x': viewX,
        'y': viewY,
        'heading': headingToTarget,
        'target_region': target.id,
        'reason': 'Unseen area ${target.id} (${target.areaSqMeters.toStringAsFixed(1)} sqm)',
      };
    }

    // If no good viewpoint found at distance, try closer positions
    // (maybe the region is in a corner)
    for (int dist = viewDistCells - 2; dist >= 3; dist -= 2) {
      for (int angleIdx = 0; angleIdx < 8; angleIdx++) {
        final angle = angleIdx * 45.0 * 3.14159 / 180.0;

        final viewMx = targetMx + (dist * math.cos(angle)).round();
        final viewMy = targetMy + (dist * math.sin(angle)).round();

        if (!inBounds(viewMx, viewMy)) continue;
        if (!isFree(viewMx, viewMy)) continue;
        if (!_isSafeCell(viewMx, viewMy, inflationCells: 2)) continue;

        final (viewX, viewY) = mapToWorld(viewMx, viewMy);
        final headingToTarget = math.atan2(target.centroidY - viewY, target.centroidX - viewX) * 180.0 / 3.14159;

        return {
          'x': viewX,
          'y': viewY,
          'heading': headingToTarget,
          'target_region': target.id,
          'reason': 'Unseen area ${target.id} (close approach)',
        };
      }
    }

    return null;
  }

  /// Check if there's line-of-sight between two map cells (no obstacles)
  bool _hasLineOfSight(int x1, int y1, int x2, int y2) {
    final dx = x2 - x1;
    final dy = y2 - y1;
    final steps = math.max(dx.abs(), dy.abs());
    if (steps == 0) return true;

    final stepX = dx / steps;
    final stepY = dy / steps;

    for (int i = 1; i < steps; i++) {
      final mx = (x1 + stepX * i).round();
      final my = (y1 + stepY * i).round();
      if (isOccupied(mx, my)) return false;
    }
    return true;
  }

  /// Check if a cell is safe (not too close to obstacles)
  bool _isSafeCell(int mx, int my, {int inflationCells = 3}) {
    for (int dy = -inflationCells; dy <= inflationCells; dy++) {
      for (int dx = -inflationCells; dx <= inflationCells; dx++) {
        if (isOccupied(mx + dx, my + dy)) return false;
      }
    }
    return true;
  }
}
