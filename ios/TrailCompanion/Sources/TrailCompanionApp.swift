import SwiftUI
import UniformTypeIdentifiers
import CoreLocation
import Combine
import CompanionCore

@main
struct TrailCompanionApp: App {
    @StateObject private var model = MapModel()
    @StateObject private var watch = WatchController()
    @Environment(\.scenePhase) private var phase
    var body: some Scene { WindowGroup { ContentView().environmentObject(model).environmentObject(watch)
        .preferredColorScheme(.light)
        .task {watch.configureMapSync(model)}
        .onOpenURL {url in guard url.scheme=="cmftrail" else{return};do{if let place=try OrganicMapsInterop.callback(url){_ = model.mergeSharedPlaces([place]);model.activeTab=0}}catch{watch.message=error.localizedDescription}}
        .onChange(of:phase) {_,p in watch.setForeground(p == .active)} } }
}

final class LocationProvider:NSObject,ObservableObject,CLLocationManagerDelegate {
    private let manager=CLLocationManager()
    @Published var location:CLLocation?
    @Published var status="Location off"
    private var requested=false
    private struct Saved:Codable {let lat:Double;let lon:Double;let accuracy:Double;let timestamp:Date}
    private var savedAt=Date.distantPast
    private var ageTimer:Timer?
    private var file:URL? {FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first?.appendingPathComponent("last-location.json")}
    var fresh:Bool {location.map{Date().timeIntervalSince($0.timestamp)>=0 && Date().timeIntervalSince($0.timestamp)<10} ?? false}
    var ageLabel:String {guard let p=location else{return "No position yet"};return fresh ? "Live phone location":"Last known · \(p.timestamp.formatted(date:.abbreviated,time:.shortened))"}
    override init() {
        super.init();manager.delegate=self;manager.desiredAccuracy=kCLLocationAccuracyBestForNavigation;manager.activityType = .fitness;manager.distanceFilter=3
        if let file,let data=try? Data(contentsOf:file),let p=try? JSONDecoder().decode(Saved.self,from:data),CLLocationCoordinate2DIsValid(.init(latitude:p.lat,longitude:p.lon)),p.accuracy>0,p.accuracy<=1000,p.timestamp<=Date() {
            location=CLLocation(coordinate:.init(latitude:p.lat,longitude:p.lon),altitude:0,horizontalAccuracy:p.accuracy,verticalAccuracy:-1,timestamp:p.timestamp);status="Using last known location"
        }
    }
    func start() {
        guard !requested else{return};requested=true
        if ageTimer==nil {ageTimer=Timer.scheduledTimer(withTimeInterval:10,repeats:true) { [weak self] _ in self?.objectWillChange.send()}}
        if manager.authorizationStatus == .notDetermined {manager.requestWhenInUseAuthorization()}
        else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {status="Location permission denied";requested=false}
        else {status="Finding location…";manager.startUpdatingLocation()}
    }
    func locationManagerDidChangeAuthorization(_ manager:CLLocationManager) {
        guard requested else{return}
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {status="Finding location…";manager.startUpdatingLocation()}
        else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {status="Location permission denied";requested=false}
    }
    func locationManager(_ manager:CLLocationManager,didUpdateLocations locations:[CLLocation]) {
        guard let value=locations.last,CLLocationCoordinate2DIsValid(value.coordinate),value.horizontalAccuracy>0,value.horizontalAccuracy<=1000,abs(value.timestamp.timeIntervalSinceNow)<120 else{return}
        location=value;status="Location on"
        if Date().timeIntervalSince(savedAt)>60,let file,let data=try? JSONEncoder().encode(Saved(lat:value.coordinate.latitude,lon:value.coordinate.longitude,accuracy:value.horizontalAccuracy,timestamp:value.timestamp)) {try? data.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication]);savedAt=Date()}
    }
    func persistLastLocation() {
        guard let p=location,let file,let data=try? JSONEncoder().encode(Saved(lat:p.coordinate.latitude,lon:p.coordinate.longitude,accuracy:p.horizontalAccuracy,timestamp:p.timestamp)) else{return}
        try? data.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
    func locationManager(_ manager:CLLocationManager,didFailWithError error:Error) {status=location == nil ? "Location unavailable":"Using last known location"}
}

final class MapModel: ObservableObject {
    @Published var store: OfflineMap?
    private var elevation: OfflineElevation?
    @Published var trailProfile:TrailProfile?
    @Published var profileLoading=false
    @Published var routeGain:Double?
    @Published var error: String?
    @Published var status = "Loading offline map…"
    @Published var center = MapPoint(x:0,y:0)
    @Published var scale: Double = 40000
    @Published var viewSize = CGSize(width:390,height:650)
    @Published var features=[MapFeature]()
    @Published var layers=[MapDrawingLayer]()
    @Published var labelFeatures=[MapFeature]()
    @Published var pins=[SearchPlace]() {didSet {watchRevision+=1}}
    @Published var route:WalkingRoute? {didSet {watchRevision+=1}}
    @Published var routing=false
    @Published var selected: SearchPlace?
    @Published var saved=[SearchPlace]() {didSet{watchRevision+=1}}
    @Published var results=[SearchPlace]()
    @Published var query=""
    @Published var searchStatus="Search places, roads, or trails"
    @Published var activeTab=4
    @Published var showDetails=false
    @Published var message: String?
    @ObservedObject var location=LocationProvider()
    private var viewportJob: DispatchWorkItem?
    private var generation=0
    private var searchGeneration=0
    private var routeGeneration=0
    private var profileGeneration=0
    private var searchJob:DispatchWorkItem?
    private var locationSubscription:AnyCancellable?
    private var loading=false
    let watchQueue=DispatchQueue(label:"cmf.map.watch",qos:.utility)
    @Published var watchRevision=0
    private let mapQueue=DispatchQueue(label:"cmf.map.viewport",qos:.userInitiated)
    private let searchQueue=DispatchQueue(label:"cmf.map.search",qos:.userInitiated)

    init() {
        locationSubscription=location.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if let i=CommandLine.arguments.firstIndex(of:"-start-tab"),i+1<CommandLine.arguments.count,let tab=Int(CommandLine.arguments[i+1]),[0,1,3,4,5].contains(tab) {activeTab=tab}
        if let data=UserDefaults.standard.data(forKey:"saved-places"),let places=try? JSONDecoder().decode([SearchPlace].self,from:data) {saved=places}
    }
    func loadIfNeeded() {
        guard store==nil,!loading else {return};loading=true
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                guard let url=MapAssets.phoneURL else{DispatchQueue.main.async{self.loading=false;self.status="Import an offline map in Settings"};return}
                let map=try OfflineMap(url:url)
                DispatchQueue.main.async {self.store=map;self.loading=false;self.status=MapAssets.phoneName;self.showMapBounds();if self.query.count>=2 {self.search()}}
            } catch {DispatchQueue.main.async {self.loading=false;self.error=error.localizedDescription;self.status="Map unavailable"}}
        }
    }
    func importPhoneMap(_ url:URL) {
        DispatchQueue.global(qos:.userInitiated).async {
            do{try MapAssets.importPhone(url);DispatchQueue.main.async{self.store=nil;self.loadIfNeeded()}}
            catch{DispatchQueue.main.async{self.message=error.localizedDescription}}
        }
    }
    func showMapBounds() {
        guard let map=store else{return}
        let box=map.chunks.reduce(CGRect.null){$0.union(CGRect(x:$1.bounds[0],y:$1.bounds[1],width:$1.bounds[2]-$1.bounds[0],height:$1.bounds[3]-$1.bounds[1]))}
        guard !box.isNull else{return};center=MapPoint(x:box.midX,y:box.midY)
        scale=min(55000,max(1,max(box.width/max(200,viewSize.width),box.height/max(200,viewSize.height))*1.12));updateViewport()
    }
    func showRegion(_ abbreviation:String?=nil) {
        guard let store else{return}
        let shapes=abbreviation.map{key in store.states.filter{$0.abbreviation==key}} ?? store.states
        let box=shapes.reduce(CGRect.null){$0.union($1.path.boundingBoxOfPath)}
        guard !box.isNull else{return}
        center=MapPoint(x:box.midX,y:box.midY)
        scale=min(55000,max(1,max(box.width/max(200,viewSize.width),box.height/max(200,viewSize.height))*1.12))
        updateViewport()
    }
    func setViewSize(_ size:CGSize) { if size.width>0 && size.height>0 && viewSize != size {viewSize=size;updateViewport()} }
    func updateViewport() {
        viewportJob?.cancel();generation += 1;let version=generation
        guard let map=store else{return}
        let c=center,s=scale,w=Double(viewSize.width),h=Double(viewSize.height)
        let bounds=[c.x-w*s/2,c.y-h*s/2,c.x+w*s/2,c.y+h*s/2]
        let job=DispatchWorkItem {
            let decoded=map.visibleFeatures(bounds:bounds,scale:s)
            let layers=MapDrawingLayer.build(decoded)
            let labels=Array(decoded.filter{!$0.name.isEmpty && ($0.kind==7 || ($0.kind==0 && ["path","bridleway","footway","cycleway"].contains($0.subtype)))}.prefix(400))
            DispatchQueue.main.async {if version==self.generation {self.features=decoded;self.layers=layers;self.labelFeatures=labels;self.watchRevision+=1}}
        }
        viewportJob=job;mapQueue.asyncAfter(deadline:.now()+0.2,execute:job)
    }
    func search() {
        searchJob?.cancel();searchGeneration += 1;let version=searchGeneration, text=query, c=center
        guard text.trimmingCharacters(in:.whitespacesAndNewlines).count>=2 else {results=[];searchStatus="Type at least two letters";return}
        guard let map=store else {searchStatus="Loading map…";return};results=[];searchStatus="Searching…"
        let job=DispatchWorkItem {
            let results=map.search(text,near:c)
            DispatchQueue.main.async {if version==self.searchGeneration {self.results=results;self.searchStatus=results.isEmpty ? "No results" : "\(results.count) results\(results.count == 300 ? " (limit)" : "")"}}
        }
        searchJob=job;searchQueue.asyncAfter(deadline:.now()+0.3,execute:job)
    }
    func showOnMap(_ places:[SearchPlace]) {
        guard !places.isEmpty else{return};route=nil;routeGeneration+=1;pins=Array(places.prefix(300));selected=nil
        let xs=pins.map(\.point.x),ys=pins.map(\.point.y)
        let left=xs.min()!,right=xs.max()!,top=ys.min()!,bottom=ys.max()!
        center=MapPoint(x:(left+right)/2,y:(top+bottom)/2)
        scale = places.count==1 ? 30 : max(10,min(55000,max((right-left)/max(100,Double(viewSize.width)*0.7),(bottom-top)/max(100,Double(viewSize.height)*0.7))))
        activeTab=0;updateViewport()
    }
    func select(_ place: SearchPlace) {
        route=nil;routeGain=nil;routeGeneration+=1;profileGeneration+=1;let version=profileGeneration
        selected=place;trailProfile=nil;profileLoading=place.kind=="trail";center=place.point;scale=20;activeTab=0;showDetails=true;updateViewport()
        if place.kind=="trail",let map=store,let elevation=elevation {
            DispatchQueue.global(qos:.userInitiated).async {
                let profile=elevation.trailProfile(map:map,place:place)
                DispatchQueue.main.async {if version==self.profileGeneration {self.trailProfile=profile;self.profileLoading=false}}
            }
        } else {profileLoading=false}
    }
    func routeTo(_ place:SearchPlace) {
        guard let current=location.location,abs(current.timestamp.timeIntervalSinceNow)<120 else {
            location.start();message="Turn on location and wait for a current position, then try Route again.";return
        }
        guard let map=store else {message="The offline map is still loading.";return}
        routeGeneration += 1;let version=routeGeneration,start=Self.project(current.coordinate),elevation=elevation;routing=true;route=nil;routeGain=nil
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                let result=try OfflineRouter.find(map:map,start:start,end:place.point)
                let gain=elevation?.gain(result.points)
                DispatchQueue.main.async {if version==self.routeGeneration {
                    self.routing=false;self.route=result;self.routeGain=gain
                    let xs=result.points.map(\.x),ys=result.points.map(\.y)
                    let left=xs.min()!,right=xs.max()!,top=ys.min()!,bottom=ys.max()!
                    self.center=MapPoint(x:(left+right)/2,y:(top+bottom)/2)
                    self.scale=max(3,min(55000,max((right-left)/max(100,Double(self.viewSize.width)*0.7),(bottom-top)/max(100,Double(self.viewSize.height)*0.7))))
                    self.updateViewport()
                }}
            } catch {DispatchQueue.main.async {if version==self.routeGeneration {self.routing=false;self.message=error.localizedDescription}}}
        }
    }
    var sharedSavedPlaces:[SharedMapPlace]{saved.compactMap{p in try? SharedMapPlace(name:p.name,latitude:atan(sinh(-p.point.y/6378137))*180/Double.pi,longitude:p.point.x/6378137*180/Double.pi)}}
    @discardableResult func mergeSharedPlaces(_ places:[SharedMapPlace])->Int{
        var keys=Set(saved.map{String(format:"%.0f/%.0f/%@",$0.point.x,$0.point.y,$0.name)})
        var added=0;var merged=saved
        for p in places{let point=Self.project(.init(latitude:p.latitude,longitude:p.longitude));let key=String(format:"%.0f/%.0f/%@",point.x,point.y,p.name);if keys.insert(key).inserted{merged.append(SearchPlace(name:p.name,kind:"place",point:point));added+=1}}
        if added>0{saved=merged;if let data=try? JSONEncoder().encode(saved){UserDefaults.standard.set(data,forKey:"saved-places")}};return added
    }
    func toggleSave(_ place:SearchPlace) {
        if let index=saved.firstIndex(where:{$0.id==place.id}) {saved.remove(at:index)} else {saved.append(place)}
        if let data=try? JSONEncoder().encode(saved) {UserDefaults.standard.set(data,forKey:"saved-places")}
    }
    func centerOnLocation() {
        guard let current=location.location else {location.start();return}
        location.start();center=Self.project(current.coordinate);scale=20;updateViewport()
    }
    static func project(_ coordinate:CLLocationCoordinate2D)->MapPoint {
        let r=6378137.0,lat=max(-85,min(85,coordinate.latitude))*Double.pi/180
        return MapPoint(x:r*coordinate.longitude*Double.pi/180,y:-r*log(tan(Double.pi/4+lat/2)))
    }
    func distance(to place:SearchPlace)->String? {
        guard let current=location.location,abs(current.timestamp.timeIntervalSinceNow)<120 else{return nil}
        let lat=atan(sinh(-place.point.y/6378137))*180/Double.pi,lon=place.point.x/6378137*180/Double.pi
        let meters=current.distance(from:CLLocation(latitude:lat,longitude:lon))
        return meters<161 ? "\(Int((meters*3.28084/10).rounded())*10) ft away" : String(format:"%.1f mi away",meters/1609.344)
    }
}

struct ContentView: View {
    @EnvironmentObject var watch:WatchController
    @EnvironmentObject var model:MapModel
    var body:some View {
        TabView(selection:$model.activeTab) {
            WatchScreen().tabItem {Label("Today",systemImage:"house")}.tag(4)
            HealthScreen().tabItem {Label("Health",systemImage:"heart")}.tag(5)
            MapScreen().tabItem {Label("Explore",systemImage:"map")}.tag(0)
            SearchScreen().tabItem {Label("Search",systemImage:"magnifyingglass")}.tag(1)
            SettingsScreen().tabItem {Label("Watch",systemImage:"applewatch")}.tag(3)
        }.tint(.cmfOrange)
        .alert("CMF Companion",isPresented:Binding(get:{watch.message != nil},set:{if !$0 {watch.message=nil}})) {Button("OK",role:.cancel){watch.message=nil}} message:{Text(watch.message ?? "")}
    }
}

struct MapScreen: View {
    @EnvironmentObject var model:MapModel
    @State private var dragCenter:MapPoint?
    @State private var initialScale:Double?
    @State private var showingSaved=false
    private func screen(_ point:MapPoint,size:CGSize)->CGPoint {
        CGPoint(x:(point.x-model.center.x)/model.scale+size.width/2,y:(point.y-model.center.y)/model.scale+size.height/2)
    }
    var body:some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack(alignment:.topTrailing) {
                    Canvas(rendersAsynchronously:true) { context,size in
                        context.fill(Path(CGRect(origin:.zero,size:size)),with:.color(Color(cgColor:MapColors.color(model.store?.states.isEmpty == false ? 0:1))))
                        if let map=model.store {
                            var mapContext=context
                            mapContext.translateBy(x:size.width/2-model.center.x/model.scale,y:size.height/2-model.center.y/model.scale)
                            mapContext.scaleBy(x:1/model.scale,y:1/model.scale)
                            for state in map.states {
                                let path=Path(state.path)
                                mapContext.fill(path,with:.color(Color(cgColor:MapColors.color(1))),style:FillStyle(eoFill:true))
                                mapContext.stroke(path,with:.color(Color(cgColor:MapColors.color(10))),lineWidth:0.8*model.scale)
                            }
                            for layer in model.layers {
                                let path=Path(layer.path)
                                switch layer.kind {
                                case 0:mapContext.stroke(path,with:.color(Color(cgColor:MapColors.color(5))),lineWidth:1.2*model.scale)
                                case 1:mapContext.stroke(path,with:.color(Color(cgColor:MapColors.color(7))),lineWidth:1.6*model.scale)
                                case 2:mapContext.stroke(path,with:.color(Color(cgColor:MapColors.color(4))),lineWidth:model.scale)
                                default:mapContext.fill(path,with:.color(Color(cgColor:MapColors.color(layer.kind==4 ? 4:layer.kind==3 ? 2:12))),style:FillStyle(eoFill:true))
                                }
                            }
                        }
                        if model.scale>=1500,let map=model.store {
                            var stateLabels=[CGRect]()
                            for state in map.states.sorted(by:{$0.abbreviation<$1.abbreviation}) {
                                let position=screen(state.center,size:size)
                                let box=CGRect(x:position.x-10,y:position.y-8,width:20,height:16)
                                if position.x>12,position.x<size.width-12,position.y>10,position.y<size.height-10,!stateLabels.contains(where:{$0.intersects(box)}) {
                                    stateLabels.append(box)
                                    context.draw(Text(state.abbreviation).font(.system(size:10,weight:.medium)).foregroundColor(.secondary),at:position)
                                }
                            }
                        }
                        var labelled=Set<String>(),labelCount=0,occupied=[CGRect]()
                        for feature in model.labelFeatures {
                            if labelCount>=100 {break}
                            let isTrail=feature.kind==0 && ["path","bridleway","footway","cycleway"].contains(feature.subtype)
                            guard feature.kind==7 || (isTrail && model.scale<50) || (feature.kind==0 && model.scale<10) else {continue}
                            guard let points=feature.parts.first,!points.isEmpty,!labelled.contains(feature.name) else {continue}
                            let position=screen(points[points.count/2],size:size)
                            guard position.x>=10,position.x<=size.width-10,position.y>=10,position.y<=size.height-10 else {continue}
                            let box=CGRect(x:position.x-Double(feature.name.count)*2.8,y:position.y-7,width:Double(feature.name.count)*5.6,height:14).insetBy(dx:-4,dy:-3)
                            guard !occupied.contains(where:{$0.intersects(box)}) else{continue};occupied.append(box)
                            context.draw(Text(feature.name).font(.system(size:10,weight:.medium)).foregroundColor(isTrail ? .green : .black),at:position)
                            labelled.insert(feature.name);labelCount+=1
                        }
                        if let route=model.route {
                            let routePath=CGMutablePath()
                            if let first=route.points.first {routePath.move(to:CGPoint(x:first.x,y:first.y));for point in route.points.dropFirst(){routePath.addLine(to:CGPoint(x:point.x,y:point.y))}}
                            var routeContext=context
                            routeContext.translateBy(x:size.width/2-model.center.x/model.scale,y:size.height/2-model.center.y/model.scale)
                            routeContext.scaleBy(x:1/model.scale,y:1/model.scale)
                            routeContext.stroke(Path(routePath),with:.color(.white),lineWidth:6*model.scale);routeContext.stroke(Path(routePath),with:.color(.blue),lineWidth:3.5*model.scale)
                        }
                        for place in model.pins {
                            let p=screen(place.point,size:size);let rect=CGRect(x:p.x-5,y:p.y-5,width:10,height:10)
                            context.fill(Path(ellipseIn:rect),with:.color(.orange));context.stroke(Path(ellipseIn:rect),with:.color(.white),lineWidth:1.5)
                        }
                        if let selected=model.selected {
                            let p=screen(selected.point,size:size);let rect=CGRect(x:p.x-7,y:p.y-7,width:14,height:14)
                            context.fill(Path(ellipseIn:rect),with:.color(.red));context.stroke(Path(ellipseIn:rect),with:.color(.white),lineWidth:2)
                        }
                        if let location=model.location.location {
                            let p=screen(MapModel.project(location.coordinate),size:size);let rect=CGRect(x:p.x-7,y:p.y-7,width:14,height:14)
                            context.fill(Path(ellipseIn:rect),with:.color(model.location.fresh ? .blue:.orange));context.stroke(Path(ellipseIn:rect),with:.color(.white),lineWidth:2)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:0).onChanged { value in
                        if dragCenter == nil {dragCenter=model.center}
                        if let start=dragCenter, hypot(value.translation.width,value.translation.height)>5 {
                            model.center=MapPoint(x:start.x-value.translation.width*model.scale,y:start.y-value.translation.height*model.scale);model.updateViewport()
                        }
                    }.onEnded { value in
                        defer {dragCenter=nil}
                        if hypot(value.translation.width,value.translation.height)<6 {
                            let closest=model.pins.map {($0,hypot(screen($0.point,size:geometry.size).x-value.location.x,screen($0.point,size:geometry.size).y-value.location.y))}.min {$0.1<$1.1}
                            if let closest,closest.1<20 {model.select(closest.0)}
                        }
                    })
                    .simultaneousGesture(MagnificationGesture().onChanged { value in
                        if initialScale==nil {initialScale=model.scale}
                        if let start=initialScale {model.scale=max(1,min(55000,start/Double(value)));model.updateViewport()}
                    }.onEnded {_ in initialScale=nil})
                    VStack(spacing:10) {
                        Button {model.showRegion()} label:{Text("US").font(.system(size:13,weight:.semibold)).frame(width:42,height:42)}
                        Button {model.showMapBounds()} label:{Text("Fit").font(.system(size:13,weight:.semibold)).frame(width:42,height:42)}
                        Button {model.centerOnLocation()} label:{Image(systemName:"location.fill").frame(width:42,height:42)}
                        Button {model.scale=max(1,model.scale/2);model.updateViewport()} label:{Image(systemName:"plus").frame(width:42,height:42)}
                        Button {model.scale=min(55000,model.scale*2);model.updateViewport()} label:{Image(systemName:"minus").frame(width:42,height:42)}
                    }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).padding()
                    VStack(alignment:.leading) {
                        LocationBadge().padding(12)
                        Spacer()
                        MapScaleBar().padding(.leading,12)
                        HStack {Text("© OpenStreetMap contributors").font(.caption2).padding(5).background(.thinMaterial,in:RoundedRectangle(cornerRadius:5));Spacer()}.padding(8)}
                    if model.routing {ProgressView("Finding route…").padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))}
                    if let error=model.error {Text(error).padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))}
                    else if model.store == nil {ProgressView(model.status).padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))}
                }
                .onAppear {model.loadIfNeeded();model.setViewSize(geometry.size)}.onChange(of:geometry.size) {_,value in model.setViewSize(value)}
            }
            .navigationTitle("Explore").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented:$showingSaved) {SavedScreen()}
            .toolbar {Button {showingSaved=true} label:{Image(systemName:"star")};if !model.pins.isEmpty {Button("Clear dots") {model.pins=[];model.selected=nil;model.route=nil}}}
            .safeAreaInset(edge:.bottom) {if let route=model.route {Text(String(format:"%.1f mi walking · approximate",route.distance/1609.344)+(model.routeGain.map { " · ↑\(Int(($0*3.28084).rounded())) ft rough" } ?? "")).font(.caption).padding(8).background(.regularMaterial,in:Capsule()).padding(6)}}
            .alert("Trail Map",isPresented:Binding(get:{model.message != nil},set:{if !$0 {model.message=nil}})) {Button("OK",role:.cancel){model.message=nil}} message:{Text(model.message ?? "")}
            .sheet(isPresented:$model.showDetails) {if let place=model.selected {PlaceDetails(place:place).presentationDetents([.medium,.large])}}
        }
    }
}

struct SearchScreen: View {
    @EnvironmentObject var model:MapModel
    var body:some View {
        NavigationStack {
            VStack {
                HStack {Image(systemName:"magnifyingglass");TextField("Search places, roads, trails",text:$model.query).textInputAutocapitalization(.never).autocorrectionDisabled()}
                    .padding(10).background(.quaternary,in:RoundedRectangle(cornerRadius:10)).padding(.horizontal)
                HStack {Text(model.searchStatus).font(.caption).foregroundStyle(.secondary);Spacer();if !model.results.isEmpty {Button("Show on map") {model.showOnMap(model.results)}}}.padding(.horizontal)
                List(model.results) { place in Button {model.pins=model.results;model.select(place)} label:{PlaceRow(place:place)} }
                    .listStyle(.plain)
            }.background(Color.cmfPaper).navigationTitle("Search")
                .task {model.loadIfNeeded()}
                .onChange(of:model.query) {_,_ in model.search()}
        }
    }
}
struct PlaceRow: View {
    @EnvironmentObject var model:MapModel
    let place:SearchPlace
    var body:some View {VStack(alignment:.leading,spacing:3) {Text(place.name).foregroundStyle(.primary);Text([place.kind.capitalized,model.distance(to:place)].compactMap{$0}.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)}}
}
struct SavedScreen: View {
    @EnvironmentObject var model:MapModel
    var body:some View {NavigationStack {List {ForEach(model.saved) {place in Button {model.pins=[place];model.select(place)} label:{PlaceRow(place:place)}}.onDelete {offsets in for index in offsets.sorted(by:>) {model.toggleSave(model.saved[index])}}}.overlay {if model.saved.isEmpty {ContentUnavailableView("No saved places",systemImage:"star",description:Text("Search for a place and tap Save."))}}.navigationTitle("Saved")}}
}
struct PlaceDetails: View {
    @EnvironmentObject var model:MapModel
    @Environment(\.dismiss) var dismiss
    let place:SearchPlace
    var body:some View {NavigationStack {List {
        Section {LabeledContent("Type",value:place.kind.capitalized);LabeledContent("Distance",value:model.distance(to:place) ?? "Turn on location");Text("Distance is straight-line, not a walking route.").font(.caption).foregroundStyle(.secondary)}
        if place.kind=="trail" {
            Section("Trail segment") {
                if model.profileLoading {ProgressView("Loading elevation…")}
                else if let profile=model.trailProfile {
                    LabeledContent("Segment",value:String(format:"%.1f mi",profile.length/1609.344))
                    LabeledContent("Gain / loss",value:"↑\(Int((profile.gain*3.28084).rounded())) / ↓\(Int((profile.loss*3.28084).rounded())) ft")
                    LabeledContent("Source",value:profile.source)
                    Text("Rough estimate from a 370 m terrain grid; steep terrain may be inaccurate.").font(.caption).foregroundStyle(.secondary)
                } else {Text("Elevation unavailable for this segment.").foregroundStyle(.secondary)}
            }
        }
        Section {Button(model.saved.contains(where:{$0.id==place.id}) ? "Remove saved place" : "Save place") {model.toggleSave(place)};Button("Walking route") {dismiss();model.routeTo(place)};Text("Walking routes are experimental and may be incomplete or wrong. USGS-only trail segments are not used for routing.").font(.caption).foregroundStyle(.secondary)}
    }.navigationTitle(place.name).navigationBarTitleDisplayMode(.inline)}}
}
struct MapSettingsScreen: View {
    @EnvironmentObject var model:MapModel
    @State private var importing=false
    var body:some View {Group {List {
        Section("Offline map") {LabeledContent("Coverage",value:MapAssets.phoneName);LabeledContent("Map data",value:MapAssets.size(MapAssets.phoneBytes));Button("Import phone map (.cmfmap)"){importing=true};Text("Build a map for your chosen region, then import it here. Search and drawing work offline.")}
        Section("Location") {Text(model.location.status);Button("Enable location") {model.location.start()}}
        Section("Watch") {Button("Watch connection and code updates") {model.activeTab=3};Text("Manage watch apps, health sync and device settings from the Watch tab.")}
        Section("Sources") {Text("© OpenStreetMap contributors; additional imported data retains its source license.").font(.caption)}
    }.navigationTitle("Settings").fileImporter(isPresented:$importing,allowedContentTypes:[.data]){result in if case .success(let url)=result{model.importPhoneMap(url)}}}}
}
