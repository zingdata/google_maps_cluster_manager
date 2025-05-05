import 'dart:math';
import 'dart:ui';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_cluster_manager/google_maps_cluster_manager.dart';
import 'package:google_maps_cluster_manager/src/max_dist_clustering.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'
    hide Cluster;

enum ClusterAlgorithm { GEOHASH, MAX_DIST }

class MaxDistParams {
  final double epsilon;

  MaxDistParams(this.epsilon);
}

class ClusterManager<T extends ClusterItem> {
  ClusterManager(this._items, this.updateMarkers,
      {Future<Marker> Function(Cluster<T>)? markerBuilder,
      this.levels = const [1, 4.25, 6.75, 8.25, 11.5, 14.5, 16.0, 16.5, 20.0],
      double? extraPercent,
      this.maxItemsForMaxDistAlgo = 200,
      this.clusterAlgorithm = ClusterAlgorithm.GEOHASH,
      this.maxDistParams,
      this.stopClusteringZoom})
      : this.markerBuilder = markerBuilder ?? _basicMarkerBuilder,
        // Default extraPercent is adaptive based on platform
        this.extraPercent = extraPercent ?? (kIsWeb ? 0.75 : 0.5),
        assert(levels.length <= precision);

  /// Method to build markers
  final Future<Marker> Function(Cluster<T>) markerBuilder;

  // Num of Items to switch from MAX_DIST algo to GEOHASH
  final int maxItemsForMaxDistAlgo;

  /// Function to update Markers on Google Map
  final void Function(Set<Marker>) updateMarkers;

  /// Zoom levels configuration
  final List<double> levels;

  /// Extra percent of markers to be loaded (ex : 0.2 for 20%)
  final double extraPercent;

  // Clusteringalgorithm
  final ClusterAlgorithm clusterAlgorithm;

  final MaxDistParams? maxDistParams;

  /// Zoom level to stop cluster rendering
  final double? stopClusteringZoom;

  /// Precision of the geohash
  static final int precision = kIsWeb ? 12 : 20;

  /// Google Maps map id
  int? _mapId;

  /// List of items
  Iterable<T> get items => _items;
  Iterable<T> _items;

  /// Last known zoom
  late double _zoom = 0; // Initialize _zoom
  
  /// Flag to track if map is idle
  bool _isMapIdle = true;
  
  /// Last known map bounds
  LatLngBounds? _lastKnownBounds;

  /// Throttle timer for web updates
  Timer? _updateTimer; // Renamed for clarity

  /// Flag to indicate if an update calculation is currently running
  bool _isUpdateRunning = false;

  final double _maxLng = 180 - pow(10, -10.0) as double;

  /// Set Google Map Id for the cluster manager
  void setMapId(int mapId, {bool withUpdate = true}) async {
    _mapId = mapId;
    // Fetch initial zoom *before* triggering the first update
    try {
      _zoom = await GoogleMapsFlutterPlatform.instance.getZoomLevel(mapId: mapId);
    } catch (e) {
       if (kDebugMode) {
         print('Error getting initial zoom: $e');
       }
       // Assign a default zoom if fetching fails? Or handle error appropriately.
       try {
         _zoom = await GoogleMapsFlutterPlatform.instance.getVisibleRegion(mapId: mapId).then((b) => _calculateZoom(b)); // Fallback
       } catch (e2) {
         if (kDebugMode) print('Error getting initial bounds for zoom fallback: $e2');
         _zoom = 0; // Ultimate fallback
       }
    }

    if (withUpdate) {
      // Trigger initial update slightly delayed, especially for web
      // Let's try a slightly longer delay initially.
      Future.delayed(Duration(milliseconds: kIsWeb ? 250 : 50), () {
         onCameraIdle(); // Simulate initial idle state to trigger update
      });
    }
  }

  /// Method called on map update to update cluster. Triggered by onCameraIdle.
  void onCameraIdle() {
    _isMapIdle = true;
    // Trigger the cluster update calculation
    _triggerUpdate();
  }

  /// Method called on camera move
  void onCameraMove(CameraPosition position, {forceUpdate = false}) {
     _isMapIdle = false;
     _zoom = position.zoom;
     // Optional: Could potentially schedule a throttled update here if needed during move,
     // but let's prioritize the idle update first.
     // If forceUpdate is true (e.g., from setItems), trigger immediately.
     if (forceUpdate) {
        _triggerUpdate(immediate: true);
     } else if (kIsWeb) {
       // On web, maybe still useful to have *some* update during drag, but debounced.
       // Let's use a simpler debounce: reset timer on each move.
       _updateTimer?.cancel();
       _updateTimer = Timer(Duration(milliseconds: 150), () {
         // Only run if map hasn't become idle already
         if (!_isMapIdle) {
           _triggerUpdate();
         }
       });
     }
  }

   /// Update all cluster items - Triggers an immediate update
  void setItems(List<T> newItems) {
    _items = newItems;
    _triggerUpdate(immediate: true); // Force update immediately
  }

  /// Add on cluster item - Triggers an immediate update
  void addItem(ClusterItem newItem) {
    _items = List.from([...items, newItem]);
    _triggerUpdate(immediate: true); // Force update immediately
  }


  /// Central method to trigger the actual cluster calculation and marker update.
  /// Uses a debounce timer for web moves, but runs immediately on idle or forced updates.
  void _triggerUpdate({bool immediate = false}) {
    if (_mapId == null) return;

    // Cancel any pending timer if update is immediate or triggered by idle
    if (immediate || _isMapIdle) {
      _updateTimer?.cancel();
    }

    // Simple debounce: If not immediate and a timer is already active, do nothing.
    if (!immediate && _updateTimer != null && _updateTimer!.isActive) {
      return;
    }

    // If an update is already running, don't start another one unless immediate
    if (_isUpdateRunning && !immediate) {
       if (kDebugMode) print("ClusterManager: Update already running, skipping trigger.");
       return;
    }

    final updateAction = () async {
      // Double check run condition inside async callback
      if (_isUpdateRunning) {
         if (kDebugMode) print("ClusterManager: Update already running, skipping execution.");
         return; // Prevent concurrent execution
      }
       if (_mapId == null) return; // Check mapId again inside async closure

      _isUpdateRunning = true;
       if (kDebugMode) print("ClusterManager: Starting cluster update. Idle: $_isMapIdle");

      try {
         // Always get fresh bounds when starting the update
         final currentBounds = await GoogleMapsFlutterPlatform.instance.getVisibleRegion(mapId: _mapId!);
         // Basic validation
         if (currentBounds.southwest.latitude == currentBounds.northeast.latitude ||
             currentBounds.southwest.longitude == currentBounds.northeast.longitude) {
             if (kDebugMode) print("ClusterManager: Invalid bounds received: $currentBounds. Skipping update.");
             _isUpdateRunning = false;
             return;
         }
         _lastKnownBounds = currentBounds; // Store the valid bounds

         List<Cluster<T>> mapMarkers = await getMarkers(currentBounds); // Pass bounds

         // Check if mapId became null during async operations (e.g., dispose)
         if (_mapId == null) {
            if (kDebugMode) print("ClusterManager: mapId became null during update. Aborting marker update.");
            _isUpdateRunning = false;
            return;
         }

         final Set<Marker> markers =
             Set.from(await Future.wait(mapMarkers.map((m) => markerBuilder(m))));

         // Check again before updating UI
         if (_mapId != null) {
            updateMarkers(markers);
            if (kDebugMode) print("ClusterManager: Update finished. ${markers.length} markers generated.");
         } else {
            if (kDebugMode) print("ClusterManager: mapId became null before calling updateMarkers. Aborting.");
         }

      } catch (e, stack) {
         if (kDebugMode) {
           print('ClusterManager: Error during cluster update: $e');
           print(stack);
         }
      } finally {
        _isUpdateRunning = false;
        if (kDebugMode) print("ClusterManager: Update flag set to false.");
      }
    };

    if (immediate || !_isMapIdle || !kIsWeb) { // Run immediately for non-web, immediate calls, or non-idle web calls from timer
       updateAction();
    } else { // Use timer only for idle web updates to ensure final state settling
        final delay = Duration(milliseconds: 50); // Short delay for idle web update
        _updateTimer = Timer(delay, updateAction);
    }
  }

  /// Retrieve cluster markers - Modified to accept bounds
  Future<List<Cluster<T>>> getMarkers(LatLngBounds mapBounds) async { // Accept bounds
    // mapId check removed - done in _triggerUpdate
    
    // Use provided bounds (already validated in _triggerUpdate)
    final currentMapBounds = mapBounds; 
    
    // Store for adaptive calculations (redundant if always passed, but safe)
    // _lastKnownBounds = currentMapBounds; // Already set in _triggerUpdate

    // Determine if we have special cases
    bool isUltraWide = _isUltraWideView(currentMapBounds);
    bool isSmallView = _isSmallView(currentMapBounds);
    
    // Use current zoom level
    final currentZoom = _zoom;

    // Get adaptive extraPercent based on current view
    double adaptiveExtraPercent = _getAdaptiveExtraPercent(); // Uses _zoom and _lastKnownBounds

    // Calculate bounds with the current adaptive settings
    late LatLngBounds inflatedBounds;
    if (clusterAlgorithm == ClusterAlgorithm.GEOHASH) {
      inflatedBounds = _inflateBounds(currentMapBounds, adaptiveExtraPercent, isSmallView, isUltraWide);
    } else {
      inflatedBounds = currentMapBounds;
    }

    List<T> visibleItems;
    
    // Special filtering for ultra-wide screens
    if (isUltraWide && kIsWeb) {
      // For ultra-wide screens on web, use a more efficient filtering approach
      // First check if items are within the latitude bounds
      visibleItems = items.where((i) {
        return i.location.latitude >= inflatedBounds.southwest.latitude && 
               i.location.latitude <= inflatedBounds.northeast.latitude;
      }).toList();
      
      // Then check longitude bounds with special handling for date line crossing
      if (inflatedBounds.northeast.longitude < inflatedBounds.southwest.longitude) {
        // Date line is crossed - need to check both sides
        visibleItems = visibleItems.where((i) {
          return i.location.longitude >= inflatedBounds.southwest.longitude || 
                 i.location.longitude <= inflatedBounds.northeast.longitude;
        }).toList();
      } else {
        // Normal case - check longitude is within bounds
        visibleItems = visibleItems.where((i) {
          return i.location.longitude >= inflatedBounds.southwest.longitude && 
                 i.location.longitude <= inflatedBounds.northeast.longitude;
        }).toList();
      }
    } 
    // Special case for very small views
    else if (isSmallView) {
      // For small views, we need to be more precise with bounds checking
      visibleItems = items.where((i) {
        // Check latitude first
        bool latOk = i.location.latitude >= inflatedBounds.southwest.latitude &&
                     i.location.latitude <= inflatedBounds.northeast.latitude;
        if (!latOk) return false;

        // Check longitude, handling date line crossing
        bool lngOk;
        if (inflatedBounds.northeast.longitude < inflatedBounds.southwest.longitude) {
          // Date line crossed
          lngOk = i.location.longitude >= inflatedBounds.southwest.longitude ||
                  i.location.longitude <= inflatedBounds.northeast.longitude;
        } else {
          // Normal
          lngOk = i.location.longitude >= inflatedBounds.southwest.longitude &&
                  i.location.longitude <= inflatedBounds.northeast.longitude;
        }
        return lngOk;
      }).toList();
    }
    else {
      // Standard bounds check for normal screens
       visibleItems = items.where((i) {
        // Check latitude first
        bool latOk = i.location.latitude >= inflatedBounds.southwest.latitude &&
                     i.location.latitude <= inflatedBounds.northeast.latitude;
        if (!latOk) return false;

        // Check longitude, handling date line crossing
        bool lngOk;
        if (inflatedBounds.northeast.longitude < inflatedBounds.southwest.longitude) {
          // Date line crossed
          lngOk = i.location.longitude >= inflatedBounds.southwest.longitude ||
                  i.location.longitude <= inflatedBounds.northeast.longitude;
        } else {
          // Normal
          lngOk = i.location.longitude >= inflatedBounds.southwest.longitude &&
                  i.location.longitude <= inflatedBounds.northeast.longitude;
        }
        return lngOk;

      }).toList();
    }

    if (stopClusteringZoom != null && currentZoom >= stopClusteringZoom!) {
      return visibleItems.map((i) => Cluster<T>.fromItems([i])).toList();
    }

    List<Cluster<T>> markers;

    if (clusterAlgorithm == ClusterAlgorithm.GEOHASH ||
        visibleItems.length >= maxItemsForMaxDistAlgo) {
      int level = _findLevel(levels); // Uses _zoom
      markers = _computeClusters(visibleItems, List.empty(growable: true),
          level: level);
    } else {
      markers = _computeClustersWithMaxDist(visibleItems, currentZoom);
    }

    return markers;
  }

  LatLngBounds _inflateBounds(LatLngBounds bounds, double adaptiveExtraPercent, bool isSmallView, bool isUltraWide) {
    // Bounds that cross the date line expand compared to their difference with the date line
    double lng = 0;
    if (bounds.northeast.longitude < bounds.southwest.longitude) {
      lng = adaptiveExtraPercent *
          ((180.0 - bounds.southwest.longitude) +
              (bounds.northeast.longitude + 180));
    } else {
      lng = adaptiveExtraPercent *
          (bounds.northeast.longitude - bounds.southwest.longitude);
    }
    
    lng = lng.abs(); // Ensure positive inflation

    // Different minimum inflation amounts based on view size
    double minLngInflation;
    final currentZoom = _zoom; // Use current zoom
    if (isSmallView) {
      // For very zoomed-in views, use a tiny inflation amount
      minLngInflation = 0.005;
    } else if (isUltraWide) {
      // For ultra-wide views, use a larger inflation amount
      minLngInflation = 0.2;
    } else if (currentZoom > 15) {
      // High zoom, small inflation
      minLngInflation = 0.01;
    } else if (currentZoom > 10) {
      // Medium zoom
      minLngInflation = 0.03;
    } else {
      // Low zoom, standard inflation
      minLngInflation = 0.1;
    }
    
    // Apply minimum if needed
    lng = lng < minLngInflation ? minLngInflation : lng;

    // Latitudes expanded beyond +/- 90 are automatically clamped by LatLng
    double lat = adaptiveExtraPercent * (bounds.northeast.latitude - bounds.southwest.latitude);
    lat = lat.abs(); // Ensure positive inflation
    
    // Different minimum latitude inflation based on view size
    double minLatInflation;
    if (isSmallView) {
      minLatInflation = 0.005;
    } else if (currentZoom > 15) {
      minLatInflation = 0.01;
    } else if (currentZoom > 10) {
      minLatInflation = 0.03;
    } else {
      minLatInflation = 0.1;
    }
    
    // Apply minimum if needed
    lat = lat < minLatInflation ? minLatInflation : lat;

    double nLat = bounds.northeast.latitude + lat;
    double sLat = bounds.southwest.latitude - lat;
    double eLng = bounds.northeast.longitude + lng;
    double wLng = bounds.southwest.longitude - lng;
   
    // Handle longitude wrapping
    if (eLng > 180) eLng = 180; // Clamp or wrap? Let LatLng handle clamping.
    if (wLng < -180) wLng = -180;
    
    // Clamp latitude
    nLat = nLat.clamp(-90.0, 90.0);
    sLat = sLat.clamp(-90.0, 90.0);
    
    // Adjust longitude for date line crossing in the original bounds
    if (bounds.northeast.longitude < bounds.southwest.longitude) {
        // Original bounds cross date line. Inflated bounds might too.
        // Let LatLngBounds constructor handle the logic if wLng > eLng after inflation
    } else {
        // Original bounds don't cross date line. Check if inflation crosses it.
        if (wLng < -180 || eLng > 180) {
            // Inflation crosses the date line. Clamp to edges.
            // LatLngBounds might handle this automatically if southwest longitude > northeast longitude.
             wLng = wLng.clamp(-180.0, 180.0);
             eLng = eLng.clamp(-180.0, 180.0);
        }
    }

    return LatLngBounds(
      southwest: LatLng(sLat, wLng),
      northeast: LatLng(nLat, eLng),
    );
  }

  int _findLevel(List<double> levels) {
    final currentZoom = _zoom; // Use current zoom
    for (int i = levels.length - 1; i >= 0; i--) {
      if (levels[i] <= currentZoom) {
        return i + 1;
      }
    }

    return 1;
  }

  int _getZoomLevel(double zoom) {
    for (int i = levels.length - 1; i >= 0; i--) {
      if (levels[i] <= zoom) {
        return levels[i].toInt();
      }
    }

    return 1;
  }

  List<Cluster<T>> _computeClustersWithMaxDist(
      List<T> inputItems, double zoom) {
    MaxDistClustering<T> scanner = MaxDistClustering(
      epsilon: maxDistParams?.epsilon ?? 20,
    );

    return scanner.run(inputItems, _getZoomLevel(zoom));
  }

  List<Cluster<T>> _computeClusters(
      List<T> inputItems, List<Cluster<T>> markerItems,
      {int level = 5}) {
    if (inputItems.isEmpty) return markerItems;
    // Ensure geohash length doesn't exceed precision or available length
    final clusterLevel = min(level, precision);

    // Group items by geohash prefix at the determined level
    Map<String, List<T>> geohashGroups = {};
    for (var item in inputItems) {
        if (item.geohash.length >= clusterLevel) {
            String key = item.geohash.substring(0, clusterLevel);
            (geohashGroups[key] ??= []).add(item);
        } else {
            // Handle items with geohash shorter than the cluster level (edge case)
             String key = item.geohash; // Use full geohash as key
            (geohashGroups[key] ??= []).add(item);
        }
    }

    // Create a cluster for each group
    for (var group in geohashGroups.values) {
      if (group.isNotEmpty) {
          markerItems.add(Cluster<T>.fromItems(group));
      }
    }
    
    // The recursive part is replaced by the grouping logic above
    return markerItems;

    // --- Old recursive logic removed ---
    // String nextGeohash = inputItems[0].geohash.substring(0, level);
    // List<T> items = inputItems
    //     .where((p) => p.geohash.substring(0, level) == nextGeohash)
    //     .toList();
    // markerItems.add(Cluster<T>.fromItems(items));
    // List<T> newInputList = List.from(
    //     inputItems.where((i) => i.geohash.substring(0, level) != nextGeohash));
    // return _computeClusters(newInputList, markerItems, level: level);
     // --- End of removed logic ---
  }

  static Future<Marker> Function(Cluster) get _basicMarkerBuilder =>
      (cluster) async {
        return Marker(
          markerId: MarkerId(cluster.getId()),
          position: cluster.location,
          onTap: () {
            if (kDebugMode) print(cluster); // Print only in debug mode
          },
          icon: await _getBasicClusterBitmap(cluster.isMultiple ? 125 : 75,
              text: cluster.isMultiple ? cluster.count.toString() : null),
        );
      };

  static Future<BitmapDescriptor> _getBasicClusterBitmap(int size,
      {String? text}) async {
    final PictureRecorder pictureRecorder = PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint paint1 = Paint()..color = Colors.red;

    canvas.drawCircle(Offset(size / 2, size / 2), size / 2.0, paint1);

    if (text != null) {
      TextPainter painter = TextPainter(textDirection: TextDirection.ltr);
      painter.text = TextSpan(
        text: text,
        style: TextStyle(
            fontSize: size / 3,
            color: Colors.white,
            fontWeight: FontWeight.normal),
      );
      painter.layout();
      painter.paint(
        canvas,
        Offset(size / 2 - painter.width / 2, size / 2 - painter.height / 2),
      );
    }

    final img = await pictureRecorder.endRecording().toImage(size, size);
    // Added type check for safety, though toByteData should return ByteData? or throw
    final data = await img.toByteData(format: ImageByteFormat.png);

    if (data == null) {
       // Handle error: return a default bitmap or throw?
       if (kDebugMode) print("Error generating cluster bitmap: toByteData returned null");
       // Returning an empty descriptor might cause issues, maybe have a fallback static one?
       return BitmapDescriptor.defaultMarker;
    }

    return BitmapDescriptor.fromBytes(data.buffer.asUint8List());
  }

   // Helper to estimate zoom from bounds (if getZoomLevel fails)
  double _calculateZoom(LatLngBounds bounds) {
     // Avoid division by zero or log(0) for invalid bounds
     if (bounds.southwest.latitude == bounds.northeast.latitude ||
         bounds.southwest.longitude == bounds.northeast.longitude) {
       return 0; // Or some default zoom
     }

     // Constants for mercator projection
     // Map width in pixels at zoom level 0
     const double MERCATOR_RANGE = 256;

     double mapWidth = _getMapWidth(bounds);
      // Handle bounds crossing the antimeridian properly for zoom calculation
     if (bounds.northeast.longitude < bounds.southwest.longitude) {
         mapWidth = 360 - (bounds.southwest.longitude - bounds.northeast.longitude).abs();
     } else {
         mapWidth = (bounds.northeast.longitude - bounds.southwest.longitude).abs();
     }

     // Prevent invalid map width
     if (mapWidth <= 0) mapWidth = 0.1;

     // Calculate zoom level based on longitude span
     // Formula derived from map width and pixels at zoom 0
     // Google Maps uses a tile size of 256 pixels
     double zoom = (log(360 * MERCATOR_RANGE / mapWidth / 256) / ln2);

     return zoom.clamp(0, 22).toDouble(); // Clamp to valid zoom range and ensure double
  }

  /// Get adaptive inflation percentage based on zoom level and map size
  double _getAdaptiveExtraPercent() {
    // Base value from constructor
    double adaptivePercent = extraPercent;
    
    // No bounds information yet, use default
    if (_lastKnownBounds == null) return adaptivePercent;
    
    // Calculate map width in degrees
    double mapWidth = _getMapWidth(_lastKnownBounds!);
    
    // Use the current _zoom value
    final currentZoom = _zoom; 

    // For very small map views (high zoom), increase extraPercent to ensure we get enough items
    if (currentZoom > 14) {
      adaptivePercent = max(adaptivePercent, 1.0);
    }
    // For medium zoom levels, scale based on width
    else if (currentZoom > 10) {
      if (mapWidth < 0.1) {
        adaptivePercent = max(adaptivePercent, 0.8);
      }
    }
    // For low zoom levels with wide view, reduce the extra percent to prevent loading too many items
    else if (currentZoom < 6 && mapWidth > 45) {
      adaptivePercent = min(adaptivePercent, 0.4);
    }
    
    return adaptivePercent;
  }
  
  /// Calculate map width in degrees
  double _getMapWidth(LatLngBounds bounds) {
    double width;
    if (bounds.northeast.longitude < bounds.southwest.longitude) {
      // Map crosses the date line
      width = (180.0 - bounds.southwest.longitude) + (bounds.northeast.longitude + 180);
    } else {
      width = bounds.northeast.longitude - bounds.southwest.longitude;
    }
    return width.abs(); // Ensure width is positive
  }
  
  /// Calculate map height in degrees
  double _getMapHeight(LatLngBounds bounds) {
    return (bounds.northeast.latitude - bounds.southwest.latitude).abs(); // Ensure height is positive
  }
  
  /// Check if this is an ultra-wide view
  bool _isUltraWideView(LatLngBounds bounds) {
    double width = _getMapWidth(bounds);
    // Ultra-wide is defined as seeing more than 90 degrees of longitude
    return width > 90;
  }
  
  /// Check if this is a very small view (high zoom)
  bool _isSmallView(LatLngBounds bounds) {
    double width = _getMapWidth(bounds);
    double height = _getMapHeight(bounds);
    // Small view is defined as seeing less than 0.05 degrees in either dimension
    return width < 0.05 || height < 0.05;
  }
}
