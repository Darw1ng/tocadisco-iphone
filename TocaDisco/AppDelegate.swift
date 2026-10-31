import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}

/// La única ventana de la app; adentro va la pantalla con la web de Toca Disco.
@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.overrideUserInterfaceStyle = .dark
        let controller = WebViewController()
        // Un enlace de Toca Disco que abrió la app (por ejemplo, el del correo para cambiar la contraseña).
        controller.initialURL = connectionOptions.urlContexts.first?.url
            ?? connectionOptions.userActivities.first?.webpageURL
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let url = userActivity.webpageURL {
            (window?.rootViewController as? WebViewController)?.open(url)
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        (window?.rootViewController as? WebViewController)?.persistState()
    }
}
