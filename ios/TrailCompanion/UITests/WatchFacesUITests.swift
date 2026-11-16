import XCTest

final class WatchFacesUITests: XCTestCase {
  func testCreateAndSaveFaceOffline() {
    let app = XCUIApplication()
    let title = "Clock " + UUID().uuidString.prefix(6)
    app.launchArguments = ["-start-tab", "3"]
    app.launch()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Watch faces")).firstMatch.tap()
    XCTAssertTrue(app.buttons["Create watch face"].waitForExistence(timeout: 5))
    app.buttons["Create watch face"].tap()
    let name = app.textFields["Name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + title + "\n")
    let editor = XCTAttachment(screenshot: app.screenshot())
    editor.name = "Watch face editor"
    editor.lifetime = .keepAlways
    add(editor)
    app.buttons["Save watch face"].tap()
    XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 20))
    XCTAssertFalse(app.buttons["Install on watch"].firstMatch.isEnabled)
    XCTAssertTrue(app.staticTexts["Saved on this phone"].firstMatch.exists)
    let library = XCTAttachment(screenshot: app.screenshot())
    library.name = "Saved watch face"
    library.lifetime = .keepAlways
    add(library)
    app.terminate()
    app.launch()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Watch faces")).firstMatch.tap()
    XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 5))
  }
}
