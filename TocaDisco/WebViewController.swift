import Network
import SafariServices
import UIKit
import WebKit

/// La única pantalla de la app: un WKWebView que abre la web de Toca Disco (el control, el panel,
/// la cuenta y el admin) sin barra de direcciones. Es la misma idea que la app de Android
/// (android-movil/ en el repo Rockola): todo lo que se ve es la página, y la app solo pone lo que
/// una página no puede: la pantalla de arranque, el color de las orillas del iPhone, la cámara y
/// los archivos, las descargas y la pantalla de «Sin conexión».
final class WebViewController: UIViewController {

    // ── Constantes que deben coincidir con la web (src/lib/mobile-app.ts) ──

    /// La web reconoce a la app por este sufijo en el user agent (MOBILE_APP_UA).
    static let uaSuffix = "TocaDiscoMovil"
    /// El objeto que la página encuentra en `window` (MOBILE_APP_BRIDGE).
    static let bridgeName = "TocaDiscoApp"
    /// Las zonas de la web que piden sesión.
    static let privatePaths = ["/app", "/control", "/panel", "/admin"]

    /// La dirección que abre la app (APP_URL en project.yml).
    static let appURL: URL = {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "TocaDiscoURL") as? String) ?? ""
        return URL(string: raw.trimmingCharacters(in: .whitespaces)) ?? URL(string: "https://www.tocadisco.com.mx/app")!
    }()

    var initialURL: URL?

    private let defaults = UserDefaults.standard
    private var webView: WKWebView!
    private let topBar = UIView()
    private let bottomBar = UIView()
    private let splash = UIView()
    private let errorView = UIView()
    private let errorTitle = UILabel()
    private let errorText = UILabel()
    private let retryButton = UIButton(type: .system)

    private var barTop = UIColor.black
    private var barBottom = UIColor.black
    private var splashGone = false
    private var failed = false
    private var failedURL: URL?
    private var area = Area.other
    private let monitor = NWPathMonitor()
    private var downloads: [WKDownload: URL] = [:]
    private var urlWatch: NSKeyValueObservation?
    private var lastBounce = Date.distantPast

    private enum Area { case login, privateArea, other }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        let color = ownScreen ? UIColor.black : barTop
        return color.isLight ? .darkContent : .lightContent
    }

    /// En el arranque y en «Sin conexión» mandan los colores de la app, no los de la página.
    private var ownScreen: Bool { !splashGone || !errorView.isHidden }

    // MARK: - Armado de la pantalla

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        barTop = UIColor(hex: defaults.string(forKey: "bar_top")) ?? .black
        barBottom = UIColor(hex: defaults.string(forKey: "bar_bottom")) ?? .black

        buildWebView()
        buildBars()
        buildError()
        buildSplash()
        refreshBars()
        watchNetwork()

        load(initialURL.flatMap { isOurs($0) ? $0 : nil } ?? Self.appURL)
    }

    private func buildWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // La sesión (cookies) se queda guardada en el iPhone.
        config.allowsInlineMediaPlayback = true // Las vistas previas de YouTube se ven dentro de la página.
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = "Mobile/15E148 Safari/604.1 \(Self.uaSuffix)/\(appVersion)"

        // El puente: la página llama a window.TocaDiscoApp.barras(arriba, abajo, fondo) igual que en Android.
        let controller = WKUserContentController()
        let bridge = """
        window.\(Self.bridgeName) = {
          barras: function (arriba, abajo, fondo) {
            try { window.webkit.messageHandlers.\(Self.bridgeName).postMessage([String(arriba), String(abajo), String(fondo)]); } catch (e) {}
          }
        };
        """
        controller.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(WeakMessageHandler(self), name: Self.bridgeName)
        config.userContentController = controller

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true // Deslizar desde la orilla izquierda = «atrás».
        web.allowsLinkPreview = false
        web.isOpaque = false
        let page = UIColor(hex: defaults.string(forKey: "page")) ?? .black
        web.backgroundColor = page
        web.scrollView.backgroundColor = page
        // Sin rebote al llegar al final (la página trae su propio «deslizar para recargar»).
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.showsHorizontalScrollIndicator = false
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        // El contenido nunca queda debajo de la isla, la muesca ni la barra de inicio.
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        webView = web

        // Next cambia de página sin navegar: decidePolicyFor no se entera, pero la dirección sí cambia.
        urlWatch = web.observe(\.url) { [weak self] web, _ in
            guard let url = web.url else { return }
            DispatchQueue.main.async {
                if self?.isSales(url) == true { self?.backToApp() }
            }
        }
    }

    /// Las dos franjas fuera de la zona segura (arriba la barra de estado, abajo la barra de inicio).
    private func buildBars() {
        for bar in [topBar, bottomBar] {
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bottomBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func logoView(size: CGFloat) -> UIImageView {
        let logo = UIImageView(image: UIImage(named: "Logo"))
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: size).isActive = true
        logo.heightAnchor.constraint(equalToConstant: size).isActive = true
        logo.accessibilityLabel = "Logo de Toca Disco"
        return logo
    }

    /// Igual que LaunchScreen.storyboard: el logo sobre negro, hasta que la primera página ya se pintó.
    private func buildSplash() {
        splash.backgroundColor = .black
        splash.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splash)
        let logo = logoView(size: 200)
        splash.addSubview(logo)
        NSLayoutConstraint.activate([
            splash.topAnchor.constraint(equalTo: view.topAnchor),
            splash.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splash.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splash.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            logo.centerXAnchor.constraint(equalTo: splash.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: splash.centerYAnchor),
        ])
    }

    private func buildError() {
        errorView.backgroundColor = .black
        errorView.isHidden = true
        errorView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorView)

        errorTitle.font = .systemFont(ofSize: 22, weight: .bold)
        errorTitle.textColor = UIColor(hex: "#F2F3F5")
        errorTitle.textAlignment = .center
        errorTitle.numberOfLines = 0
        errorText.font = .systemFont(ofSize: 16)
        errorText.textColor = UIColor(hex: "#A9ADB4")
        errorText.textAlignment = .center
        errorText.numberOfLines = 0

        retryButton.setTitle("Reintentar", for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        retryButton.backgroundColor = UIColor(hex: "#F04E14")
        retryButton.setTitleColor(UIColor(hex: "#050506"), for: .normal)
        retryButton.setTitleColor(UIColor(hex: "#050506"), for: .disabled)
        retryButton.layer.cornerRadius = 24
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 32, bottom: 12, right: 32)
        retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [logoView(size: 120), errorTitle, errorText, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.setCustomSpacing(28, after: errorText)
        stack.translatesAutoresizingMaskIntoConstraints = false
        errorView.addSubview(stack)
        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: errorView.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: errorView.trailingAnchor, constant: -32),
        ])
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    // MARK: - Carga

    func open(_ url: URL) {
        if isOurs(url) { load(url) }
    }

    private func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Regresa de una página de venta a la app. Si /app rebotara a una de ellas, no da vueltas sin fin.
    private func backToApp() {
        let bouncing = Date().timeIntervalSince(lastBounce) < 3
        lastBounce = Date()
        if !bouncing { load(Self.appURL) }
    }

    func persistState() {
        // WKWebView ya guarda las cookies en disco; aquí solo los colores de las orillas.
        defaults.set(barTop.hexString, forKey: "bar_top")
        defaults.set(barBottom.hexString, forKey: "bar_bottom")
    }

    /// La página ya se pintó: fuera la pantalla de arranque y la de error.
    private func showWeb() {
        errorView.isHidden = true
        webView.isHidden = false
        hideSplash()
        refreshBars()
    }

    private func hideSplash() {
        guard !splashGone else { return }
        splashGone = true
        UIView.animate(withDuration: 0.22, animations: { self.splash.alpha = 0 }) { _ in
            self.splash.isHidden = true
        }
    }

    // MARK: - Sin conexión

    /// No se pudo abrir la página: pantalla propia con el logo y «Reintentar», nunca la de error de Safari.
    private func fail(_ url: URL?, title: String, text: String) {
        failed = true
        if let url { failedURL = url }
        errorTitle.text = title
        errorText.text = text
        retryButton.setTitle("Reintentar", for: .normal)
        retryButton.isEnabled = true
        retryButton.alpha = 1
        errorView.isHidden = false
        webView.isHidden = true
        hideSplash()
        refreshBars()
    }

    private func failOffline(_ url: URL?) {
        fail(url, title: "Sin conexión",
             text: "No pudimos abrir Toca Disco. Revisa tu wifi o tus datos y vuelve a intentar.")
    }

    @objc private func retry() {
        retryButton.setTitle("Reintentando…", for: .normal)
        retryButton.isEnabled = false
        retryButton.alpha = 0.6
        load(failedURL ?? Self.appURL)
    }

    /// Al volver el internet se reintenta sola, sin esperar a que alguien toque el botón.
    private func watchNetwork() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async {
                guard let self, self.failed, self.retryButton.isEnabled else { return }
                self.retry()
            }
        }
        monitor.start(queue: DispatchQueue(label: "mx.tocadisco.red"))
    }

    // MARK: - Colores de las orillas

    fileprivate func receiveBars(_ values: [String]) {
        guard values.count == 3, let top = UIColor(hex: values[0]) else { return }
        let bottom = UIColor(hex: values[1]) ?? top
        let page = UIColor(hex: values[2]) ?? bottom
        barTop = top
        barBottom = bottom
        webView.backgroundColor = page
        webView.scrollView.backgroundColor = page
        defaults.set(top.hexString, forKey: "bar_top")
        defaults.set(bottom.hexString, forKey: "bar_bottom")
        defaults.set(page.hexString, forKey: "page")
        refreshBars()
    }

    private func refreshBars() {
        topBar.backgroundColor = ownScreen ? .black : barTop
        bottomBar.backgroundColor = ownScreen ? .black : barBottom
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - Enlaces

    private func bareHost(_ host: String?) -> String? {
        guard let host = host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// La dirección es de Toca Disco (con o sin www).
    private func isOurs(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "https" || scheme == "http") && bareHost(url.host) == bareHost(Self.appURL.host)
    }

    /// El pago de la suscripción (Stripe) no se abre ni aquí ni en Safari: en iPhone el plan no se
    /// vende ni se cobra (regla 3.1.1 de Apple).
    private func isPayment(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "stripe.com" || host.hasSuffix(".stripe.com")
    }

    /// Las páginas que venden el plan: el inicio y /contratar. En iPhone no se muestran.
    private func isSales(_ url: URL) -> Bool {
        guard isOurs(url) else { return false }
        let path = url.path
        return path.isEmpty || path == "/" || path == "/contratar" || path.hasPrefix("/contratar/")
    }

    private func openOutside(_ url: URL) {
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            if !opened { self?.toast("No hay una app en este iPhone para abrir ese enlace.") }
        }
    }

    private func areaOf(_ url: URL) -> Area {
        guard isOurs(url) else { return .other }
        let path = url.path
        if path == "/login" { return .login }
        if Self.privatePaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .privateArea }
        return .other
    }

    // MARK: - Avisos

    private func toast(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { alert.dismiss(animated: true) }
    }
}

// MARK: - Navegación

extension WebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }

        // Lo incrustado dentro de una página (el reproductor de YouTube) navega por su cuenta.
        if action.targetFrame?.isMainFrame == false { return decisionHandler(.allow) }

        // Un enlace marcado para descargar (los reportes en CSV).
        if action.shouldPerformDownload { return decisionHandler(.download) }

        switch url.scheme?.lowercased() {
        case "http", "https":
            if isPayment(url) {
                decisionHandler(.cancel)
                toast("Esto no está disponible en la app.")
            } else if isSales(url) {
                decisionHandler(.cancel)
                backToApp()
            } else if isOurs(url) {
                // Con «atrás» no se regresa al formulario de entrada con la sesión ya abierta,
                // ni al panel después de cerrarla (en Android se borra el historial).
                if action.navigationType == .backForward {
                    let target = areaOf(url)
                    if (area == .privateArea && target == .login) || (area == .login && target == .privateArea) {
                        return decisionHandler(.cancel)
                    }
                }
                decisionHandler(.allow)
            } else {
                openOutside(url)
                decisionHandler(.cancel)
            }
        case "about", "blob", "data", "javascript":
            decisionHandler(.allow)
        default:
            // mailto:, tel:, whatsapp:… se abren con su app.
            openOutside(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = response.response as? HTTPURLResponse {
            let disposition = (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
            if disposition.hasPrefix("attachment") { return decisionHandler(.download) }
            // El servidor se está reiniciando o desplegando (502, 503…).
            if response.isForMainFrame && http.statusCode >= 500 {
                decisionHandler(.cancel)
                fail(http.url, title: "Toca Disco no responde",
                     text: "El servicio no está respondiendo en este momento. Espera un poco y vuelve a intentar.")
                return
            }
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failed = false
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url { area = areaOf(url) }
        if !failed { showWeb() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { area = areaOf(url) }
        if !failed { showWeb() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    private func handle(_ error: Error) {
        let ns = error as NSError
        // Una navegación que se cambió por otra a medio camino, o que se volvió descarga, no es un error.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        if failed { return } // Ya se mostró «Toca Disco no responde».
        let url = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        failOffline(url)
    }

    /// El motor web se cayó (o iOS lo cerró por falta de memoria): se recarga.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let url = webView.url { load(url) } else { load(Self.appURL) }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

// MARK: - Ventanas nuevas y diálogos de la página

extension WebViewController: WKUIDelegate {

    /// Un enlace con target="_blank": lo nuestro se abre aquí mismo, lo demás en Safari.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isPayment(url) {
                toast("Esto no está disponible en la app.")
            } else if isOurs(url) {
                webView.load(action.request)
            } else {
                openOutside(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Aceptar", style: .default) { _ in completionHandler() })
        presentOrSkip(alert) { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "Aceptar", style: .default) { _ in completionHandler(true) })
        presentOrSkip(alert) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "Aceptar", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        presentOrSkip(alert) { completionHandler(nil) }
    }

    private func presentOrSkip(_ alert: UIAlertController, skip: () -> Void) {
        if presentedViewController == nil { present(alert, animated: true) } else { skip() }
    }

    /// La cámara y el micrófono los pide la página (por ejemplo, para grabar un anuncio).
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(bareHost(origin.host) == bareHost(Self.appURL.host) ? .prompt : .deny)
    }
}

// MARK: - Descargas (reportes en CSV y demás)

extension WebViewController: WKDownloadDelegate {

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("descargas", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "archivo" : suggestedFilename
        let destination = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        downloads[download] = destination
        completionHandler(destination)
    }

    /// Ya bajó: se abre el menú de compartir para guardarlo en Archivos, mandarlo por WhatsApp, etc.
    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloads.removeValue(forKey: download) else { return }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = view
        share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        present(share, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: download)
        toast("No se pudo descargar el archivo. Intenta de nuevo.")
    }
}

// MARK: - Puente con la página

extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.bridgeName, message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url, isOurs(url),
              let values = message.body as? [String] else { return }
        receiveBars(values)
    }
}

/// WKUserContentController retiene a quien recibe los mensajes; esto evita que la pantalla nunca se libere.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// MARK: - Colores

extension UIColor {
    /// Solo se aceptan colores escritos como #rrggbb, igual que en Android.
    convenience init?(hex: String?) {
        guard let hex, hex.count == 7, hex.hasPrefix("#"),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }

    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.6
    }
}
