import XCTest
@testable import CompanionCore
final class MapComposerTests:XCTestCase {
    func testWatchViewportValidation() {
        let v=WatchViewport(message:Data([84,77,1,17,0,0,0,0,0,0,0,0,8,0]))
        XCTAssertEqual(v?.scale,8);XCTAssertEqual(v?.x,0)
        XCTAssertNil(WatchViewport(message:Data([84,77,1,17,0,0,0,0,0,0,0,0,0,0])))
    }
    func testClippingKeepsCrossingRoadWithDistantEndpoints() {
        let a=WatchMapComposer.segments(lines:[.init(points:[.init(x:-100000,y:0),.init(x:100000,y:0)],kind:0)],center:.init(x:0,y:0),scale:8)
        XCTAssertEqual(a.count,1);XCTAssertEqual(a[0].x1,-1880);XCTAssertEqual(a[0].x2,1880)
    }
    func testStraightGeometrySimplifiesAndReversedDuplicatesDisappear() {
        let p=(0...100).map{WatchMapPoint(x:Double($0)*10,y:0)}
        let a=WatchMapComposer.segments(lines:[.init(points:p,kind:1),.init(points:p.reversed(),kind:1)],center:.init(x:0,y:0),scale:8)
        XCTAssertEqual(a.count,1)
    }
    func testDenseOneCellCannotCrowdOutOtherCellsOrTrail() {
        var lines=[WatchMapLine]()
        for i in 0..<1000 {
            let a=WatchMapPoint(x:Double(i%50),y:Double(i%100))
            let b=WatchMapPoint(x:Double(i%50+20),y:Double(i%100+60))
            lines.append(WatchMapLine(points:[a,b],kind:0))
        }
        lines.append(.init(points:[.init(x:-1500,y:-1200),.init(x:-1000,y:-1200)],kind:1))
        lines.append(.init(points:[.init(x:1000,y:1200),.init(x:1500,y:1200)],kind:3))
        let a=WatchMapComposer.segments(lines:lines,center:.init(x:0,y:0),scale:8,limit:20)
        XCTAssertLessThanOrEqual(a.count,20);XCTAssertTrue(a.contains{$0.kind==1});XCTAssertTrue(a.contains{$0.kind==3})
    }
}
