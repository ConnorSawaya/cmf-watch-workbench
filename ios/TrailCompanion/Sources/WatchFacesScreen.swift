import CompanionCore
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SavedFace: Identifiable, Codable {
  var id: UUID, name: String, bytes: Int, created: Date, dialID: UInt32?, installedDevice: String?
  var pendingDialID: UInt32? = nil, pendingDevice: String? = nil
  var file: URL { FaceLibrary.directory.appendingPathComponent(id.uuidString + ".wfdl") }
  var thumbnail: URL { FaceLibrary.directory.appendingPathComponent(id.uuidString + ".png") }
}
enum FaceLibrary {
  static var directory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("watch-faces", isDirectory: true)
  }
  static func load() -> [SavedFace] {
    (try? JSONDecoder().decode(
      [SavedFace].self, from: Data(contentsOf: directory.appendingPathComponent("library.json"))))
      ?? []
  }
  static func save(_ list: [SavedFace]) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(list).write(
      to: directory.appendingPathComponent("library.json"),
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
  static func add(_ file: FaceFile) throws -> SavedFace {
    var list = load()
    let item = SavedFace(
      id: UUID(), name: file.name, bytes: file.data.count, created: Date(), dialID: nil,
      installedDevice: nil)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try file.data.write(
      to: item.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    if let preview = file.preview.flatMap(FaceArtwork.uiImage), let data = preview.pngData() {
      try data.write(to: item.thumbnail, options: .atomic)
    }
    list.insert(item, at: 0)
    try save(list)
    return item
  }
}

struct FaceDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.data] }
  let data: Data
  init(_ data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
enum FaceArtwork {
  static func image(_ w: Int, _ h: Int, _ draw: (UIGraphicsImageRendererContext) -> Void) -> UIImage
  {
    let f = UIGraphicsImageRendererFormat()
    f.scale = 1
    f.opaque = false
    return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: f).image(
      actions: draw)
  }
  static func pixels(_ image: UIImage, alpha: Bool) throws -> FaceImage {
    guard let cg = image.cgImage else { throw WatchFaceError.invalidFile }
    let w = cg.width
    let h = cg.height
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    guard
      let c = CGContext(
        data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else { throw WatchFaceError.invalidFile }
    c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var raw = Data()
    raw.reserveCapacity(w * h * (alpha ? 3 : 2))
    for p in stride(from: 0, to: rgba.count, by: 4) {
      let a = Int(rgba[p + 3])
      let un: (Int) -> Int = { i in a == 0 ? 0 : min(255, Int(rgba[p + i]) * 255 / a) }
      let color = (un(0) >> 3) << 11 | (un(1) >> 2) << 5 | (un(2) >> 3)
      raw.append(UInt8(color & 255))
      raw.append(UInt8(color >> 8))
      if alpha { raw.append(UInt8(a)) }
    }
    return try FaceImage(width: w, height: h, format: alpha ? 5 : 4, pixels: raw)
  }
  static func uiImage(_ image: FaceImage) -> UIImage? {
    guard [4, 5].contains(image.format) else { return nil }
    let b = Array(image.pixels)
    let step = image.format == 5 ? 3 : 2
    var rgba = [UInt8]()
    rgba.reserveCapacity(image.width * image.height * 4)
    for i in stride(from: 0, to: b.count, by: step) {
      let c = Int(b[i]) | Int(b[i + 1]) << 8
      let a = image.format == 5 ? Int(b[i + 2]) : 255
      rgba += [
        UInt8(((c >> 11) * 255 / 31) * a / 255), UInt8((((c >> 5) & 63) * 255 / 63) * a / 255),
        UInt8(((c & 31) * 255 / 31) * a / 255), UInt8(a),
      ]
    }
    let data = Data(rgba) as CFData
    guard let provider = CGDataProvider(data: data),
      let cg = CGImage(
        width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil,
        shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    return UIImage(cgImage: cg)
  }
  static func text(_ text: String, _ rect: CGRect, _ font: UIFont, _ color: UIColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let size = (text as NSString).size(withAttributes: [.font: font])
    (text as NSString).draw(
      in: CGRect(
        x: rect.minX, y: rect.midY - size.height / 2, width: rect.width, height: size.height),
      withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
  }
  static func background(_ photo: UIImage?, _ color: UIColor) -> UIImage {
    image(466, 466) { ctx in
      color.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: 466, height: 466))
      if let photo {
        let factor = max(466 / photo.size.width, 466 / photo.size.height)
        photo.draw(
          in: CGRect(
            x: (466 - photo.size.width * factor) / 2, y: (466 - photo.size.height * factor) / 2,
            width: photo.size.width * factor, height: photo.size.height * factor))
        UIColor.black.withAlphaComponent(0.48).setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 466, height: 466))
      }
      text(
        "BATTERY", CGRect(x: 130, y: 325, width: 206, height: 22),
        .systemFont(ofSize: 14, weight: .medium), .white.withAlphaComponent(0.6))
    }
  }
  static func make(name: String, accent: UIColor, rounded: Bool, photo: UIImage?) throws -> FaceFile
  {
    let bg = background(photo, .black)
    func font(_ size: CGFloat) -> UIFont {
      if rounded,
        let d = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .medium).fontDescriptor
          .withDesign(.rounded)
      {
        return UIFont(descriptor: d, size: size)
      }
      return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }
    func glyph(_ value: String, _ w: Int, _ h: Int, _ size: CGFloat, _ color: UIColor) throws
      -> FaceImage
    {
      try pixels(
        image(w, h) { _ in text(value, CGRect(x: 0, y: 0, width: w, height: h), font(size), color)
        }, alpha: true)
    }
    let digits = try (0...9).map { try glyph(String($0), 64, 104, 88, accent) }
    let small = try (0...9).map { try glyph(String($0), 20, 32, 27, .white) }
    let aod = try (0...9).map { try glyph(String($0), 32, 56, 48, UIColor(white: 0.5, alpha: 1)) }
    let colon = try glyph(":", 20, 104, 80, accent)
    let separator = try glyph("/", 12, 32, 25, .white)
    let dimColon = try glyph(":", 12, 56, 42, UIColor(white: 0.5, alpha: 1))
    let preview = image(466, 466) { _ in
      bg.draw(at: .zero)
      let formatter = DateFormatter()
      formatter.dateFormat = "HH:mm"
      text(
        formatter.string(from: Date()), CGRect(x: 80, y: 160, width: 306, height: 104), font(88),
        accent)
      formatter.dateFormat = "MM/dd"
      text(
        formatter.string(from: Date()), CGRect(x: 160, y: 290, width: 146, height: 32), font(27),
        .white)
    }
    let thumb = image(120, 120) { _ in preview.draw(in: CGRect(x: 0, y: 0, width: 120, height: 120))
    }
    return try FaceCompiler.digital(
      name: name, background: pixels(bg, alpha: false), digits: digits, smallDigits: small,
      aodDigits: aod, colon: colon, separator: separator, aodColon: dimColon,
      preview: pixels(thumb, alpha: false))
  }
  static func thumbnail(_ data: Data) -> UIImage? {
    guard data.count < 50_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
      let cg = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 1024,
        ] as CFDictionary)
    else { return nil }
    return UIImage(cgImage: cg)
  }
}

struct WatchFacesScreen: View {
  @EnvironmentObject var watch: WatchController
  @State private var creating = false
  @State private var importing = false
  @State private var export: FaceDocument?
  @State private var exporting = false
  @State private var exportName = "Watch face"
  @State private var deleting: SavedFace?
  var body: some View {
    List {
      Section {
        Button {
          creating = true
        } label: {
          Label("Create watch face", systemImage: "plus")
        }
        Button {
          importing = true
        } label: {
          Label("Import .wfdl or .bin", systemImage: "square.and.arrow.down")
        }
      }
      Section("Your faces") {
        if watch.faces.isEmpty {
          Text(
            "Create a face with your own colours and photo, or import a compatible Watch Pro 2 face."
          ).foregroundStyle(.secondary)
        }
        ForEach(watch.faces) { face in
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
              if let image = UIImage(contentsOfFile: face.thumbnail.path) {
                Image(uiImage: image).resizable().scaledToFit().frame(width: 74, height: 74)
                  .clipShape(Circle())
              }
              VStack(alignment: .leading, spacing: 5) {
                Text(face.name).font(.headline)
                Text(ByteCountFormatter.string(fromByteCount: Int64(face.bytes), countStyle: .file))
                  .font(.caption).foregroundStyle(.secondary)
                Text(
                  watch.faceIsInstalled(face) ? "Installed on this watch" : "Saved on this phone"
                ).font(.caption).foregroundStyle(
                  watch.faceIsInstalled(face) ? Color.cmfGreen : .secondary)
              }
            }
            HStack {
              Button(watch.faceIsInstalled(face) ? "Installed" : "Install on watch") {
                watch.installFace(face)
              }.buttonStyle(.borderedProminent).tint(.cmfInk).disabled(
                watch.busy || watch.faceIsInstalled(face) || !(watch.connected || watch.stockPaired)
              )
              Spacer()
              Menu {
                Button("Export file") {
                  do {
                    export = FaceDocument(try Data(contentsOf: face.file))
                    exportName = face.name
                    exporting = true
                  } catch { watch.message = error.localizedDescription }
                }
                if watch.faceIsInstalled(face) {
                  Button("Delete from watch", role: .destructive) { deleting = face }
                } else {
                  Button("Delete saved face", role: .destructive) { watch.deleteLocalFace(face) }
                }
              } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
              }
            }
          }.padding(.vertical, 8)
        }
      }
      Section {
        Text(
          "Faces run on the normal watch home screen, including a separate always-on clock. Time, date and battery come from the watch. Installation uses a free face slot and does not replace your firmware."
        ).font(.caption).foregroundStyle(.secondary)
        if watch.busy {
          ProgressView(value: watch.progress)
          Text(watch.status).font(.caption)
        }
        Text(watch.faceStatus).font(.caption).foregroundStyle(.secondary)
      }
    }.navigationTitle("Watch faces").sheet(isPresented: $creating) {
      FaceDesigner { file in watch.saveFace(file) }
    }
    .fileImporter(
      isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false
    ) { result in
      do {
        guard let url = try result.get().first else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= FaceFile.maximumBytes else { throw WatchFaceError.tooComplex }
        watch.saveFace(try FaceFile(Data(contentsOf: url)))
      } catch { watch.message = error.localizedDescription }
    }
    .fileExporter(
      isPresented: $exporting, document: export, contentType: .data,
      defaultFilename: exportName + ".wfdl"
    ) { result in if case .failure(let e) = result { watch.message = e.localizedDescription } }
    .confirmationDialog(
      "Delete this face from the watch?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      if let face = deleting {
        Button("Delete from watch", role: .destructive) {
          watch.removeFace(face)
          deleting = nil
        }
      }
    }
  }
}
struct FaceDesigner: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name = "My face"
  @State private var accent = Color.white
  @State private var rounded = true
  @State private var photoItem: PhotosPickerItem?
  @State private var photo: UIImage?
  @State private var working = false
  @State private var error: String?
  let save: (FaceFile) -> Void
  var body: some View {
    NavigationStack {
      Form {
        Section {
          TimelineView(.periodic(from: .now, by: 60)) { context in
            ZStack {
              Circle().fill(.black)
              if let photo {
                Image(uiImage: photo).resizable().scaledToFill().frame(width: 260, height: 260)
                  .clipped()
                Color.black.opacity(0.48)
              }
              VStack(spacing: 0) {
                Spacer()
                Text(context.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                  .font(
                    .system(size: 48, weight: .regular, design: rounded ? .rounded : .monospaced)
                  ).monospacedDigit().foregroundStyle(accent)
                Spacer().frame(height: 20)
                Text(context.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))).font(
                  .system(size: 15, design: .monospaced)
                ).foregroundStyle(.white)
                Text("BATTERY").font(.system(size: 8, weight: .medium)).foregroundStyle(
                  .white.opacity(0.6)
                ).padding(.top, 10)
                Text("—").foregroundStyle(.white).font(.caption)
                Spacer().frame(height: 38)
              }
            }.frame(width: 260, height: 260).clipShape(Circle()).frame(maxWidth: .infinity)
          }.listRowBackground(Color.clear)
          Text("Phone preview. The installed face uses the watch’s live clock, date and battery.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("Design") {
          TextField("Name", text: $name).textInputAutocapitalization(.words)
          ColorPicker("Clock colour", selection: $accent, supportsOpacity: false)
          Toggle("Rounded digits", isOn: $rounded)
          PhotosPicker(selection: $photoItem, matching: .images) {
            Label("Choose background photo", systemImage: "photo")
          }
          if photo != nil { Button("Remove photo") { photo = nil } }
        }
        Section {
          Button(working ? "Building face…" : "Save watch face") { build() }.disabled(
            working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
      }.navigationTitle("New watch face")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }.disabled(working)
          }
        }
        .onChange(of: photoItem) { _, item in
          Task {
            if let data = try? await item?.loadTransferable(type: Data.self) {
              photo = FaceArtwork.thumbnail(data)
            }
          }
        }
    }
  }
  private func build() {
    working = true
    error = nil
    let title = name
    let color = UIColor(accent)
    let round = rounded
    let image = photo
    Task {
      do {
        let file = try await Task.detached(priority: .userInitiated) {
          try FaceArtwork.make(name: title, accent: color, rounded: round, photo: image)
        }.value
        save(file)
        dismiss()
      } catch { self.error = error.localizedDescription }
      working = false
    }
  }
}
