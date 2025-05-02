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
  late double _zoom;
  
  /// Flag to track if map is idle
  bool _isMapIdle = true;
  
  /// Last known map bounds
  LatLngBounds? _lastKnownBounds;

  /// Throttle timer for web updates
  Timer? _throttleTimer;

  final double _maxLng = 180 - pow(10, -10.0) as double;

  /// Set Google Map Id for the cluster manager
  void setMapId(int mapId, {bool withUpdate = true}) async {
    _mapId = mapId;
    _zoom = await GoogleMapsFlutterPlatform.instance.getZoomLevel(mapId: mapId);
    if (withUpdate) {
      // For web, ensure we render markers after a short delay for map to fully initialize
      if (kIsWeb) {
        Future.delayed(Duration(milliseconds: 100), () {
          updateMap();
        });
      } else {
        updateMap();
      }
    }
  }

  /// Method called on map update to update cluster. Can also be manually called to force update.
  void updateMap() {
    _isMapIdle = true;
    _updateClusters();
  }

  void _updateClusters() async {
    if (_mapId == null) return;
    
    // On web, throttle updates to prevent flickering
    if (kIsWeb) {
      _throttleTimer?.cancel();
      _throttleTimer = Timer(Duration(milliseconds: 50), () async {
        // Store current bounds for adaptive calculations
        if (_mapId != null) {
          _lastKnownBounds = await GoogleMapsFlutterPlatform.instance
            .getVisibleRegion(mapId: _mapId!);
        }
        
        List<Cluster<T>> mapMarkers = await getMarkers();
        if (mapMarkers.isEmpty && _isMapIdle) {
          // If no markers and map is idle, try again with a slightly delayed call
          Future.delayed(Duration(milliseconds: 100), () {
            if (_isMapIdle) _updateClusters();
          });
          return;
        }

        final Set<Marker> markers =
            Set.from(await Future.wait(mapMarkers.map((m) => markerBuilder(m))));

        updateMarkers(markers);
      });
    } else {
      // Store current bounds for adaptive calculations
      if (_mapId != null) {
        _lastKnownBounds = await GoogleMapsFlutterPlatform.instance
          .getVisibleRegion(mapId: _mapId!);
      }
      
      List<Cluster<T>> mapMarkers = await getMarkers();
      final Set<Marker> markers =
          Set.from(await Future.wait(mapMarkers.map((m) => markerBuilder(m))));
      updateMarkers(markers);
    }
  }

  /// Update all cluster items
  void setItems(List<T> newItems) {
    _items = newItems;
    updateMap();
  }

  /// Add on cluster item
  void addItem(ClusterItem newItem) {
    _items = List.from([...items, newItem]);
    updateMap();
  }

  /// Method called on camera move
  void onCameraMove(CameraPosition position, {forceUpdate = false}) {
    _isMapIdle = false;
    _zoom = position.zoom;
    if (forceUpdate) {
      updateMap();
    }
  }

  /// Get adaptive inflation percentage based on zoom level and map size
  double _getAdaptiveExtraPercent() {
    // Base value from constructor
    double adaptivePercent = extraPercent;
    
    // No bounds information yet, use default
    if (_lastKnownBounds == null) return adaptivePercent;
    
    // Calculate map width in degrees
    double mapWidth = _getMapWidth(_lastKnownBounds!);
    
    // For very small map views (high zoom), increase extraPercent to ensure we get enough items
    if (_zoom > 14) {
      adaptivePercent = max(adaptivePercent, 1.0);
    }
    // For medium zoom levels, scale based on width
    else if (_zoom > 10) {
      if (mapWidth < 0.1) {
        adaptivePercent = max(adaptivePercent, 0.8);
      }
    }
    // For low zoom levels with wide view, reduce the extra percent to prevent loading too many items
    else if (_zoom < 6 && mapWidth > 45) {
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
    return width;
  }
  
  /// Calculate map height in degrees
  double _getMapHeight(LatLngBounds bounds) {
    return bounds.northeast.latitude - bounds.southwest.latitude;
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

  /// Retrieve cluster markers
  Future<List<Cluster<T>>> getMarkers() async {
    if (_mapId == null) return List.empty();

    final LatLngBounds mapBounds = await GoogleMapsFlutterPlatform.instance
        .getVisibleRegion(mapId: _mapId!);
        
    // Store for future adaptive calculations
    _lastKnownBounds = mapBounds;

    // Determine if we have special cases
    bool isUltraWide = _isUltraWideView(mapBounds);
    bool isSmallView = _isSmallView(mapBounds);
    
    // Get adaptive extraPercent based on current view
    double adaptiveExtraPercent = _getAdaptiveExtraPercent();

    // Calculate bounds with the current adaptive settings
    late LatLngBounds inflatedBounds;
    if (clusterAlgorithm == ClusterAlgorithm.GEOHASH) {
      inflatedBounds = _inflateBounds(mapBounds, adaptiveExtraPercent, isSmallView, isUltraWide);
    } else {
      inflatedBounds = mapBounds;
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
        if (inflatedBounds.northeast.longitude < inflatedBounds.southwest.longitude) {
          // Handle date line crossing
          return i.location.latitude >= inflatedBounds.southwest.latitude &&
                 i.location.latitude <= inflatedBounds.northeast.latitude &&
                 (i.location.longitude >= inflatedBounds.southwest.longitude || 
                  i.location.longitude <= inflatedBounds.northeast.longitude);
        } else {
          // Standard bounds check
          return i.location.latitude >= inflatedBounds.southwest.latitude &&
                 i.location.latitude <= inflatedBounds.northeast.latitude &&
                 i.location.longitude >= inflatedBounds.southwest.longitude &&
                 i.location.longitude <= inflatedBounds.northeast.longitude;
        }
      }).toList();
    }
    else {
      // Standard bounds check for normal screens
      visibleItems = items.where((i) {
        return inflatedBounds.contains(i.location);
      }).toList();
    }

    if (stopClusteringZoom != null && _zoom >= stopClusteringZoom!)
      return visibleItems.map((i) => Cluster<T>.fromItems([i])).toList();

    List<Cluster<T>> markers;

    if (clusterAlgorithm == ClusterAlgorithm.GEOHASH ||
        visibleItems.length >= maxItemsForMaxDistAlgo) {
      int level = _findLevel(levels);
      markers = _computeClusters(visibleItems, List.empty(growable: true),
          level: level);
    } else {
      markers = _computeClustersWithMaxDist(visibleItems, _zoom);
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

    // Different minimum inflation amounts based on view size
    double minLngInflation;
    if (isSmallView) {
      // For very zoomed-in views, use a tiny inflation amount
      minLngInflation = 0.005;
    } else if (isUltraWide) {
      // For ultra-wide views, use a larger inflation amount
      minLngInflation = 0.2;
    } else if (_zoom > 15) {
      // High zoom, small inflation
      minLngInflation = 0.01;
    } else if (_zoom > 10) {
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
    
    // Different minimum latitude inflation based on view size
    double minLatInflation;
    if (isSmallView) {
      minLatInflation = 0.005;
    } else if (_zoom > 15) {
      minLatInflation = 0.01;
    } else if (_zoom > 10) {
      minLatInflation = 0.03;
    } else {
      minLatInflation = 0.1;
    }
    
    // Apply minimum if needed
    lat = lat < minLatInflation ? minLatInflation : lat;

    double eLng = (bounds.northeast.longitude + lng).clamp(-_maxLng, _maxLng);
    double wLng = (bounds.southwest.longitude - lng).clamp(-_maxLng, _maxLng);

    // Special case for extremely wide bounds to prevent over-inflation
    bool isExtremelyWide = _getMapWidth(bounds) > 90;
    
    return LatLngBounds(
      southwest: LatLng(bounds.southwest.latitude - lat, wLng),
      northeast:
          LatLng(bounds.northeast.latitude + lat, isExtremelyWide && lng == 0 ? bounds.northeast.longitude : (lng != 0 ? eLng : _maxLng)),
    );
  }

  int _findLevel(List<double> levels) {
    for (int i = levels.length - 1; i >= 0; i--) {
      if (levels[i] <= _zoom) {
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
    String nextGeohash = inputItems[0].geohash.substring(0, level);

    List<T> items = inputItems
        .where((p) => p.geohash.substring(0, level) == nextGeohash)
        .toList();

    markerItems.add(Cluster<T>.fromItems(items));

    List<T> newInputList = List.from(
        inputItems.where((i) => i.geohash.substring(0, level) != nextGeohash));

    return _computeClusters(newInputList, markerItems, level: level);
  }

  static Future<Marker> Function(Cluster) get _basicMarkerBuilder =>
      (cluster) async {
        return Marker(
          markerId: MarkerId(cluster.getId()),
          position: cluster.location,
          onTap: () {
            print(cluster);
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
    final data = await img.toByteData(format: ImageByteFormat.png) as ByteData;

    return BitmapDescriptor.fromBytes(data.buffer.asUint8List());
  }
}
