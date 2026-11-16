import SwiftUI
import UniformTypeIdentifiers
import CompanionCore

private struct PlacesDocument:FileDocument{
    static var readableContentTypes:[UTType]{[UTType(filenameExtension:"gpx") ?? .xml]}
    var data:Data
    init(data:Data){self.data=data}
    init(configuration:ReadConfiguration)throws{data=configuration.file.regularFileContents ?? Data()}
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper{FileWrapper(regularFileWithContents:data)}
}
struct OrganicMapsScreen:View{
    @EnvironmentObject var model:MapModel
    @EnvironmentObject var watch:WatchController
    @State private var importing=false
    @State private var exporting=false
    @State private var working=false
    @State private var exportDocument:PlacesDocument?
    @State private var feedback:String?
    var body:some View{
        List{
            Section("Saved places"){
                Button("Import Organic Maps bookmarks"){importing=true}.disabled(working)
                Button("Export saved places as GPX"){
                    exportDocument=PlacesDocument(data:OrganicMapsInterop.exportGPX(model.sharedSavedPlaces));exporting=true
                }.disabled(model.saved.isEmpty)
                Button("Open saved places in Organic Maps"){open(model.sharedSavedPlaces)}.disabled(model.saved.isEmpty)
                Text("In Organic Maps, open Bookmarks and Tracks, choose a list, then export GPX or GeoJSON. Import that file here. This exchanges point bookmarks; it does not continuously mirror the other app.").font(.caption).foregroundStyle(.secondary)
                Text("Your 32 most recently saved places sync to Trail Map when both apps are open. The watch keeps them independently of its eight recent map views.").font(.caption).foregroundStyle(.secondary)
                if working{ProgressView("Importing places…")}
                if let feedback{Text(feedback).font(.caption).foregroundStyle(.secondary)}
            }
            Section("Offline regions"){
                Text("Download your chosen regions inside Organic Maps. Export its saved points here with GPX or GeoJSON.").font(.subheadline)
                Text("Organic Maps renders its own MWM files. Its public iOS API does not stream map tiles to this companion or watch. Import a CMFMAP1 phone map and a WP2MAP1 watch map built with this project's tools.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Sources"){
                Link("Organic Maps Project",destination:URL(string:"https://organicmaps.app")!)
                Link("Map data © OpenStreetMap and Organic Maps",destination:URL(string:"https://openstreetmap.org/copyright")!)
                Link("Organic Maps iOS API",destination:URL(string:"https://github.com/organicmaps/api-ios")!)
            }
        }.navigationTitle("Organic Maps")
        .fileImporter(isPresented:$importing,allowedContentTypes:[.data],allowsMultipleSelection:false){result in
            guard case .success(let urls)=result,let url=urls.first else{return};working=true
            Task{@MainActor in
                defer{working=false}
                do{let places=try await Task.detached(priority:.userInitiated){
                    let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
                    let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0;guard size<=5_000_000 else{throw MapExchangeError.tooLarge}
                    return try OrganicMapsInterop.importPlaces(Data(contentsOf:url,options:.mappedIfSafe))
                }.value
                    let added=model.mergeSharedPlaces(places);feedback="Added \(added) saved places. Watch sync keeps the most recent 32."
                }catch{feedback=error.localizedDescription}
            }
        }
        .fileExporter(isPresented:$exporting,document:exportDocument,contentType:UTType(filenameExtension:"gpx") ?? .xml,defaultFilename:"CMF saved places"){result in if case .failure(let error)=result{feedback=error.localizedDescription}}
    }
    private func open(_ places:[SharedMapPlace]){
        guard let url=OrganicMapsInterop.mapURL(places:places) else{return}
        UIApplication.shared.open(url,options:[:]){ok in if !ok{Task{@MainActor in feedback="Install Organic Maps to open its offline maps."}}}
    }
}
