import SwiftUI
import AVFoundation

struct WatchQRScanner:UIViewControllerRepresentable {
    var result:(Result<String,Error>)->Void
    func makeUIViewController(context:Context)->QRViewController {let c=QRViewController();c.result=result;return c}
    func updateUIViewController(_ c:QRViewController,context:Context){}
    static func dismantleUIViewController(_ c:QRViewController,coordinator:()) {c.stop()}
}
final class QRViewController:UIViewController,AVCaptureMetadataOutputObjectsDelegate {
    var result:((Result<String,Error>)->Void)?
    private let session=AVCaptureSession()
    private let queue=DispatchQueue(label:"cmf.qr.camera")
    private var preview:AVCaptureVideoPreviewLayer?
    private var reported=false
    private var stopped=false
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for:.video) { [weak self] allowed in
            guard let self else{return}
            if allowed {self.setup()}else{DispatchQueue.main.async {self.result?(.failure(QRError.cameraDenied))}}
        }
    }
    override func viewDidLayoutSubviews(){super.viewDidLayoutSubviews();preview?.frame=view.bounds}
    func stop(){queue.async {self.stopped=true;self.session.stopRunning()}}
    private func setup(){queue.async {
        guard !self.stopped else{return}
        guard let camera=AVCaptureDevice.default(for:.video),let input=try? AVCaptureDeviceInput(device:camera),self.session.canAddInput(input) else {DispatchQueue.main.async{self.result?(.failure(QRError.cameraDenied))};return}
        self.session.beginConfiguration();self.session.addInput(input)
        let output=AVCaptureMetadataOutput()
        guard self.session.canAddOutput(output) else {self.session.commitConfiguration();return}
        self.session.addOutput(output);output.setMetadataObjectsDelegate(self,queue:.main);output.metadataObjectTypes=[.qr];self.session.commitConfiguration()
        DispatchQueue.main.async {let p=AVCaptureVideoPreviewLayer(session:self.session);p.videoGravity = .resizeAspectFill;p.frame=self.view.bounds;self.view.layer.addSublayer(p);self.preview=p}
        self.session.startRunning()
    }}
    func metadataOutput(_ output:AVCaptureMetadataOutput,didOutput objects:[AVMetadataObject],from connection:AVCaptureConnection) {
        guard !reported,let value=(objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else{return}
        reported=true;stop();result?(.success(value))
    }
}
enum QRError:LocalizedError {case cameraDenied;var errorDescription:String?{"Allow camera access to scan the watch QR code, or use Pair reset watch to find it over Bluetooth."}}
