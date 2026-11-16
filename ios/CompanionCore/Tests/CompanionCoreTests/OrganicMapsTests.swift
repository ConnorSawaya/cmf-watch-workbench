import XCTest
@testable import CompanionCore
final class OrganicMapsTests:XCTestCase{
    func testGPXEscapesAndRoundTripsSavedPlaces()throws{let places=[try SharedMapPlace(name:"Camp & <Water>",latitude:43.737,longitude:7.425)];XCTAssertEqual(try OrganicMapsInterop.importPlaces(OrganicMapsInterop.exportGPX(places)),places)}
    func testGeoJSONPointsIgnoreTracksRatherThanInventingLinks()throws{let data=Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[-122,37]},"properties":{"name":"Camp"}},{"type":"Feature","geometry":{"type":"LineString","coordinates":[[1,2],[3,4]]}}]}"#.utf8);XCTAssertEqual(try OrganicMapsInterop.importPlaces(data).count,1)}
    func testURLAndCallbackUseDocumentedCoordinates()throws{let p=try SharedMapPlace(name:"Camp & water",latitude:37,longitude:-122);let url=try XCTUnwrap(OrganicMapsInterop.mapURL(places:[p]));XCTAssertEqual(url.scheme,"om");let c=try OrganicMapsInterop.callback(URL(string:"cmftrail://pin?ll=37,-122&n=Camp%20%26%20water")!);XCTAssertEqual(c,p);XCTAssertThrowsError(try OrganicMapsInterop.callback(URL(string:"cmftrail://pin?ll=NaN,0")!))}
    func testBookmarkWireBoundsAndCount()throws{let data=try watchPlacesData([WatchPlace(x:100,y:-200,name:"Camp")]);XCTAssertEqual(data.count,44);XCTAssertEqual(String(data:data[20..<24],encoding:.utf8),"Camp");XCTAssertThrowsError(try watchPlacesData(Array(repeating:WatchPlace(x:0,y:0,name:"x"),count:33)))}
}
