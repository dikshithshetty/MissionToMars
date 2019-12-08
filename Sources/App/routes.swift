import Routing
import Vapor

/// Register your application's routes here.
///
/// [Learn More →](https://docs.vapor.codes/3.0/getting-started/structure/#routesswift)
public func routes(_ router: Router) throws {
    router.get("hello") { req in
        return "Hello, world!"
    }
    /*
    router.get("testRoute") { req -> String in
        let player = Player(username: "empty")
        let mission = Mission()
        let improvement = Improvement(id: nil, name: "test", ownerID: UUID())
        
        return "empty"
    }*/
    
}
