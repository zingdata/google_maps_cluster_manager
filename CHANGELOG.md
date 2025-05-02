## 3.1.5

- Implement continuous adaptive bounds scaling to handle ALL screen sizes
- Fix issues with medium-sized screens where clusters weren't visible
- Create graduated extension factors based on viewport size for optimal cluster visibility
- Optimize bounds calculation with dynamically scaled inflation based on zoom level

## 3.1.4

- Fix issue where clusters weren't visible on smaller screens
- Add special handling for small screen sizes to ensure markers are properly displayed
- Improve bounds calculation for all screen sizes

## 3.1.3

- Add caching system to improve performance during map movements
- Add debouncing and throttling mechanisms to reduce unnecessary updates
- Optimize item filtering for better performance with large datasets
- Add ability to enable/disable clustering at runtime
- Improve performance on web platforms with smarter update scheduling

## 3.1.2

- Add support for ultra-wide screens to prevent clusters from disappearing
- Improve bounding area calculations for very wide map views
- Enhance filtering logic to better handle large visible regions
- Increase default extraPercent for web platforms

## 3.1.1

- Fix web-specific issues where clusters disappear on initial load or during zoom operations
- Add throttling mechanism for web to ensure smooth cluster updates
- Improve web map rendering with proper timing for updates

## 3.1.0

- Bump dependency versions
- Max distance clustering

## 3.0.0+1

- Remove useless log

## 3.0.0

**Breaking changes**:

- `ClusterItem` is now a mixin (or a class to extends from) instead of a wrapper around items. This way you don't have to map your items to ClusterItems before using them.
- Remove now useless `initialZoom` parameter.

## 2.0.0

**Breaking changes**:

- Use mapId (with `setMapId` method) to retrieve the map instead of GoogleMapController. This way, the library depends only on `google_maps_flutter_platform_interface` which makes it compatible both with `google_maps_flutter` and `google_maps_flutter_web`.

## 1.0.0

- Migrate to null safety
- Internalising geohash to make it null safety compatible
- Temporary : remove `google_maps_flutter_web` because it needs a reorganization of the project to work correctly (& it's not null safety compatible for the moment)

## 0.3.0

- Add `google_maps_flutter_web` dependency to be compatible with Flutter web
- Update to `google_maps_flutter` version 1.2.0

## 0.2.1

- Improve potential precision of geohash
- Update to `google_maps_flutter` version 1.0.6

## 0.2.0

- Add `stopClusteringZoom` variable
- Update to `google_maps_flutter` version 1.0.2
- Improve `extraPercent` calculation (thanks to @buntagonalprism)

## 0.1.0

- Fix `getMarkers` signature
- Add gif example

## 0.0.2

- Add `setItems` and `addItem` methods
- Add initial zoom

## 0.0.1

- Initial developers preview release.
