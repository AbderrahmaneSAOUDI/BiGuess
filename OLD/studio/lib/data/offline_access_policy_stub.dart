final _markers = <String>{};
bool readMarker(String key) => _markers.contains(key);
void writeMarker(String key) => _markers.add(key);
void removeMarker(String key) => _markers.remove(key);
