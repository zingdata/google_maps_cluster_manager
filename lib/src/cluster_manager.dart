import 'dart:math';
import 'dart:ui';
import 'dart:async';
import 'dart:collection';

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
      this.stopClusteringZoom,
      this.maxDistanceBetweenClustersByZoom,
      bool enableClustering = true})
      : this.markerBuilder = markerBuilder ?? _basicMarkerBuilder,
        this.extraPercent = extraPercent ?? (kIsWeb ? 1.0 : 0.5),
        this._enableClustering = enableClustering,
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

  /// Whether clustering is enabled
  bool get enableClustering => _enableClustering;
  bool _enableClustering;

  /// Distance multiplier by zoom level to determine clustering proximity
  final Map<int, double>? maxDistanceBetweenClustersByZoom;

  /// Precision of the geohash
  static final int precision = kIsWeb ? 12 : 20;

  /// Google Maps map id
  int? _mapId;

  /// List of items
  Iterable<T> get items => _items;
  Iterable<T> _items;

  /// Last known zoom
  late double _zoom;
  
  /// Last known bounds
  LatLngBounds? _lastBounds;
  
  /// Last known camera position
  CameraPosition? _lastPosition;

  /// Cache of recently computed clusters
  final _clusterCache = _ClusterCache<T>();
  
  /// Flag to track if map is idle
  bool _isMapIdle = true;

  /// Throttle timer for web updates
  Timer? _throttleTimer;
  
  /// Debounce timer for map movements
  Timer? _debounceTimer;

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

  /// Enable/disable clustering
  void setEnableClustering(bool enableClustering) {
    if (this._enableClustering != enableClustering) {
      this._enableClustering = enableClustering;
      _clusterCache.clear();
      updateMap();
    }
  }

  void _updateClusters() async {
    if (_mapId == null) return;
    
    // On web, throttle updates to prevent flickering
    if (kIsWeb) {
      _throttleTimer?.cancel();
      _throttleTimer = Timer(Duration(milliseconds: 50), () async {
        _updateClustersFinal();
      });
    } else {
      _updateClustersFinal();
    }
  }
  
  void _updateClustersFinal() async {
    if (_mapId == null) return;
    
    // Get the current visible region
    final LatLngBounds mapBounds = await GoogleMapsFlutterPlatform.instance
        .getVisibleRegion(mapId: _mapId!);
    
    // Check cache first if bounds haven't changed significantly
    if (_lastBounds != null && 
        _isSimilarBounds(_lastBounds!, mapBounds) &&
        _clusterCache.hasValidCacheFor(_zoom)) {
      final cachedMarkers = _clusterCache.get(_zoom);
      if (cachedMarkers != null) {
        updateMarkers(cachedMarkers);
        return;
      }
    }
    
    _lastBounds = mapBounds;
    
    final List<Cluster<T>> mapMarkers = await getMarkers();
    if (mapMarkers.isEmpty && _isMapIdle) {
      // If no markers and map is idle, try again with a slightly delayed call
      Future.delayed(Duration(milliseconds: 100), () {
        if (_isMapIdle) _updateClusters();
      });
      return;
    }

    final Set<Marker> markers = 
        Set.from(await Future.wait(mapMarkers.map((m) => markerBuilder(m))));
    
    // Cache the results
    _clusterCache.put(_zoom, markers);
    
    updateMarkers(markers);
  }
  
  bool _isSimilarBounds(LatLngBounds bounds1, LatLngBounds bounds2) {
    // Check if bounds are similar enough to reuse cached clusters
    const double tolerance = 0.01; // ~1.1km at equator
    
    return (bounds1.northeast.latitude - bounds2.northeast.latitude).abs() < tolerance &&
           (bounds1.northeast.longitude - bounds2.northeast.longitude).abs() < tolerance &&
           (bounds1.southwest.latitude - bounds2.southwest.latitude).abs() < tolerance &&
           (bounds1.southwest.longitude - bounds2.southwest.longitude).abs() < tolerance;
  }

  /// Update all cluster items
  void setItems(List<T> newItems) {
    _items = newItems;
    _clusterCache.clear();
    updateMap();
  }

  /// Add on cluster item
  void addItem(ClusterItem newItem) {
    _items = List.from([...items, newItem]);
    _clusterCache.clear();
    updateMap();
  }

  /// Method called on camera move
  void onCameraMove(CameraPosition position, {forceUpdate = false}) {
    _isMapIdle = false;
    _zoom = position.zoom;
    
    // If the position changed significantly, clear the cache
    if (_lastPosition != null) {
      if ((position.zoom - _lastPosition!.zoom).abs() > 0.5 || 
          (position.target.latitude - _lastPosition!.target.latitude).abs() > 0.1 ||
          (position.target.longitude - _lastPosition!.target.longitude).abs() > 0.1) {
        _clusterCache.clearExcept(position.zoom);
      }
    }
    _lastPosition = position;
    
    // Debounce rapid camera movements
    _debounceTimer?.cancel();
    
    if (forceUpdate) {
      updateMap();
    } else if (kIsWeb) {
      // For web, apply a short debounce to smooth out updates during panning
      _debounceTimer = Timer(Duration(milliseconds: 100), () {
        // Only update if we're not at the exact same zoom level as a cached result
        if (!_clusterCache.hasExactCacheFor(_zoom)) {
          _updateClusters();
        }
      });
    }
  }

  /// Retrieve cluster markers
  Future<List<Cluster<T>>> getMarkers() async {
    if (_mapId == null) return List.empty();

    final LatLngBounds mapBounds = await GoogleMapsFlutterPlatform.instance
        .getVisibleRegion(mapId: _mapId!);

    // Determine viewport characteristics
    double latSpan = (mapBounds.northeast.latitude - mapBounds.southwest.latitude).abs();
    double lngSpan = (mapBounds.northeast.longitude - mapBounds.southwest.longitude).abs();
    
    // Use these to create adaptive inflation
    late LatLngBounds inflatedBounds;
    if (clusterAlgorithm == ClusterAlgorithm.GEOHASH) {
      inflatedBounds = _inflateBounds(mapBounds);
    } else {
      inflatedBounds = mapBounds;
    }

    // Get appropriate visible items using adaptive filtering
    List<T> visibleItems = _getAdaptiveVisibleItems(items, inflatedBounds, mapBounds, latSpan, lngSpan);

    // If clustering is disabled, or we're at a high zoom level, return individual markers
    if (!enableClustering || (stopClusteringZoom != null && _zoom >= stopClusteringZoom!))
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
  
  List<T> _getAdaptiveVisibleItems(
      Iterable<T> allItems, 
      LatLngBounds inflatedBounds, 
      LatLngBounds originalBounds,
      double latSpan, 
      double lngSpan) {
    
    // Create graduated extension factors based on viewport size
    // This creates a continuous scale rather than discrete categories
    double extensionFactor;
    
    if (latSpan < 0.05 || lngSpan < 0.05) {
      // Very small screens - maximum extension
      extensionFactor = 0.5;
    } else if (latSpan < 0.1 || lngSpan < 0.1) {
      // Small screens
      extensionFactor = 0.35;
    } else if (latSpan < 0.3 || lngSpan < 0.3) {
      // Medium-small screens
      extensionFactor = 0.25;
    } else if (latSpan < 0.8 || lngSpan < 0.8) {
      // Medium screens
      extensionFactor = 0.15;
    } else if (latSpan < 2.0 || lngSpan < 2.0) {
      // Medium-large screens
      extensionFactor = 0.1;
    } else {
      // Large screens - minimum extension
      extensionFactor = 0.05;
    }
    
    // Special handling for ultra-wide screens
    bool isUltraWideScreen = lngSpan > 90;
    
    // Apply extension to bounds
    LatLngBounds extendedBounds;
    
    if (!isUltraWideScreen) {
      // Normal bounds
      double latExtension = max(latSpan * extensionFactor, 0.05);
      double lngExtension = max(lngSpan * extensionFactor, 0.05);
      
      extendedBounds = LatLngBounds(
        southwest: LatLng(
          inflatedBounds.southwest.latitude - latExtension,
          inflatedBounds.southwest.longitude - lngExtension
        ),
        northeast: LatLng(
          inflatedBounds.northeast.latitude + latExtension,
          inflatedBounds.northeast.longitude + lngExtension
        )
      );
    } else {
      // Ultra-wide screen handling (date line crossing, etc.)
      extendedBounds = inflatedBounds;
    }
    
    // Two-stage filtering for better performance
    // First filter by latitude (simpler calculation)
    final latFiltered = allItems.where((i) {
      return i.location.latitude >= extendedBounds.southwest.latitude && 
             i.location.latitude <= extendedBounds.northeast.latitude;
    });
    
    // Then filter by longitude - handle date line crossing if needed
    if (extendedBounds.northeast.longitude < extendedBounds.southwest.longitude) {
      // Date line crossed - need to check both sides
      return latFiltered.where((i) {
        return i.location.longitude >= extendedBounds.southwest.longitude || 
               i.location.longitude <= extendedBounds.northeast.longitude;
      }).toList();
    } else {
      // Standard longitude check
      return latFiltered.where((i) {
        return i.location.longitude >= extendedBounds.southwest.longitude && 
               i.location.longitude <= extendedBounds.northeast.longitude;
      }).toList();
    }
  }

  LatLngBounds _inflateBounds(LatLngBounds bounds) {
    // Get the span of the visible region to determine appropriate inflation
    double latSpan = (bounds.northeast.latitude - bounds.southwest.latitude).abs();
    double lngSpan = (bounds.northeast.longitude - bounds.southwest.longitude).abs();
    
    // Calculate adaptive inflation factor based on the visible region size
    // Smaller regions get more inflation, larger regions get less
    double adaptiveExtraPercent = extraPercent;
    
    // Apply scaling based on screen size - increases inflation as viewport gets smaller
    if (latSpan < 1.0 || lngSpan < 1.0) {
      // For smaller viewports, increase inflation factor
      double scaleFactor = 1.0 + (1.0 - min(latSpan, lngSpan)) * 2.0;
      adaptiveExtraPercent = extraPercent * scaleFactor;
    }
    
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

    // Ensure minimum inflation regardless of screen size
    // Gradually increase minimum for smaller viewports
    double minFactor = 0.1;
    if (latSpan < 0.5 || lngSpan < 0.5) {
      minFactor = 0.2;
    }
    if (latSpan < 0.1 || lngSpan < 0.1) {
      minFactor = 0.3;
    }
    
    double minLngInflation = minFactor; // Minimum longitude inflation
    lng = lng < minLngInflation ? minLngInflation : lng;

    // Latitudes expanded beyond +/- 90 are automatically clamped by LatLng
    double lat = adaptiveExtraPercent * 
        (bounds.northeast.latitude - bounds.southwest.latitude);
    
    // Apply same minimum inflation to latitude
    double minLatInflation = minFactor;
    lat = lat < minLatInflation ? minLatInflation : lat;

    double eLng = (bounds.northeast.longitude + lng).clamp(-_maxLng, _maxLng);
    double wLng = (bounds.southwest.longitude - lng).clamp(-_maxLng, _maxLng);

    // Handle date line crossing and extremely wide bounds
    bool isExtremelyWide = lngSpan > 90;
    
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

/// Cache for cluster results to avoid recomputation
class _ClusterCache<T extends ClusterItem> {
  // Store markers by zoom level with LRU eviction
  final _cache = LinkedHashMap<double, Set<Marker>>();
  final int _maxSize = 5; // Maximum number of zoom levels to cache
  
  Set<Marker>? get(double zoom) {
    // Return closest zoom level within 0.1
    final exactMatch = _cache[zoom];
    if (exactMatch != null) {
      // Move to end of LRU
      final value = _cache.remove(zoom);
      _cache[zoom] = value!;
      return exactMatch;
    }
    
    // Look for close matches
    for (final cachedZoom in _cache.keys) {
      if ((cachedZoom - zoom).abs() < 0.1) {
        // Close enough to use
        final value = _cache.remove(cachedZoom);
        _cache[cachedZoom] = value!;
        return value;
      }
    }
    
    return null;
  }
  
  void put(double zoom, Set<Marker> markers) {
    // Evict oldest if at capacity
    if (_cache.length >= _maxSize) {
      _cache.remove(_cache.keys.first);
    }
    
    _cache[zoom] = markers;
  }
  
  bool hasValidCacheFor(double zoom) {
    // Check for exact or close match
    if (_cache.containsKey(zoom)) return true;
    
    for (final cachedZoom in _cache.keys) {
      if ((cachedZoom - zoom).abs() < 0.1) {
        return true;
      }
    }
    
    return false;
  }
  
  bool hasExactCacheFor(double zoom) {
    return _cache.containsKey(zoom);
  }
  
  void clear() {
    _cache.clear();
  }
  
  void clearExcept(double zoom) {
    final keysToRemove = _cache.keys.where((k) => (k - zoom).abs() > 0.5).toList();
    for (final key in keysToRemove) {
      _cache.remove(key);
    }
  }
}
