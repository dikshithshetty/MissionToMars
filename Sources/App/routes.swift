import Routing
import Model
import Vapor

/// Register your application's routes here.
///
/// [Learn More →](https://docs.vapor.codes/3.0/getting-started/structure/#routesswift)
public func routes(_ router: Router) throws {
    
    var errorMessages = [UUID: String?]()
    
    router.get("hello") { req in
        return "Hello, world!"
    }
    
    router.get("testRoute") { req -> Future<Player> in
        let player = Player(username: "testUser")
    
        return player.create(on: req).map(to: Player.self) { player in
            return player
        }
    }
    
    router.get("create/player") { req -> Future<View> in
        return try req.view().render("createPlayer")
    }
    
    router.post("create/player") { req -> Future<View> in
        struct CreateCharacterContext: Codable {
            var errorMessage = "noError"
            var uuid = "unknown"
        }
        let username: String = try req.content.syncGet(at: "username")
        
        return Player.createUser(username: username, on: req).flatMap(to: View.self) { result in
            var context = CreateCharacterContext()
            
            switch result {
            case .success(let player):
                context.uuid = String(player.id!)
            case .failure(let error):
                context.errorMessage = error.localizedDescription
                print(context.errorMessage)
            }
            
            return try req.view().render("userCreated", context)
        }
    }
    
    router.post("login") { req -> Response in
        let idString: String = (try? req.content.syncGet(at: "playerid")) ?? ""
        
        guard let id = UUID(idString) else {
            print("\(idString) is not a valid user id")
            return req.redirect(to: "/")
        }
        
        try req.session()["playerID"] = idString
        return req.redirect(to: "/main")
    }
    
    router.get("main") { req -> Future<View> in
        guard let id = getPlayerIDFromSession(on: req) else {
            throw Abort(.unauthorized)
        }
        
        return getSimulation(on: req).flatMap(to: View.self) { simulation in
            if simulation.simulationShouldUpdate(currentDate: Date()) {
                return Player.query(on: req).all().flatMap(to: View.self) { players in
                    return Mission.query(on: req).all().flatMap(to: View.self) { missions in
                        let result = simulation.updateSimulation(currentDate: Date(), players: players, missions: missions)
                        assert(simulation.id != nil)
                        assert(result.updatedSimulation.id != nil)
                        assert(simulation.id == result.updatedSimulation.id)
                        return result.updatedSimulation.update(on: req).flatMap(to: View.self) { savedSimulation in
                            return Player.savePlayers(result.updatedPlayers, on: req).flatMap(to: View.self) { players in
                                return Mission.saveMissions(result.updatedMissions, on: req).flatMap(to: View.self) { missions in
                                    return getMainViewForPlayer(with: id, simulation: savedSimulation, on: req)
                                }
                            }
                        }
                    }
                }
            } else {
                return getMainViewForPlayer(with: id, simulation: simulation, on: req)
            }
            
        }
    }
    
    router.get("edit/mission") { req -> Future<View> in
        return try getPlayerFromSession(on: req).flatMap(to: View.self) { player in
            return try player.getSupportedMission(on: req).flatMap(to: View.self) { mission in
                guard let supportedMission = mission else {
                    throw Abort(.notFound, reason: "Mission with id \(String(describing: player.ownsMissionID)) not found.")
                }
                
                return try req.view().render("editMission", ["missionName": supportedMission.missionName])
            }
        }
    }
    
    router.post("edit/mission") { req -> Future<Response> in
        let newName: String = try req.content.syncGet(at: "missionName")
        return try getPlayerFromSession(on: req).flatMap(to: Response.self) { player in
            return try player.getSupportedMission(on: req).flatMap(to: Response.self) { mission in
                guard var supportedMission = mission else {
                    throw Abort(.notFound, reason: "Mission with id \(String(describing: player.ownsMissionID)) not found.")
                }
                
                supportedMission.missionName = newName
                return supportedMission.update(on: req).map(to: Response.self) { savedMission in
                    return req.redirect(to: "/main")
                }
            }
        }
    }
    
    router.get("create/mission") { req -> Future<Response> in
        return try getPlayerFromSession(on: req).flatMap(to: Response.self) { player in
            assert(player.id != nil)
            
            let mission = Mission(owningPlayerID: player.id!)
            return mission.create(on: req).flatMap(to: Response.self) { mission in
                var updatedPlayer = player
                updatedPlayer.ownsMissionID = mission.id
                return updatedPlayer.save(on: req).map(to: Response.self) { updatedPlayer in
                    return req.redirect(to: "/main")
                }
            }
        }
    }
    
    router.get("support/mission") { req -> Future<View> in
        guard let id = getPlayerIDFromSession(on: req) else {
            throw Abort(.unauthorized)
        }
        
        return Mission.query(on: req).all().flatMap(to: View.self) { missions in
            let playerFutures = try missions.map { mission in
                return try mission.getOwningPlayer(on: req)
            }
            let playerFuture = playerFutures.flatten(on: req)
            
            return playerFuture.flatMap(to: View.self) { players in
                var mcs = [MissionContext]()
                for i in 0 ..< players.count {
                    mcs.append(MissionContext(id: missions[i].id!, missionName: missions[i].missionName, percentageDone: missions[i].percentageDone, successChance: missions[i].successChance, owningPlayerName: players[i].username))
                }
                return try req.view().render("missions", ["missions": mcs])
            }
        }
    }
    
    router.get("support/mission", UUID.parameter) { req -> Future<Response> in
        let supportedMissionID: UUID = try req.parameters.next()
        
        return try getPlayerFromSession(on: req).flatMap(to: Response.self) { player in
            return Mission.find(supportedMissionID, on: req).flatMap(to: Response.self) { mission in
                guard let supportedMission = mission else {
                    throw Abort(.notFound, reason: "Could not find mission with id \(supportedMissionID)")
                }
                
                var updatedPlayer = player
                
                updatedPlayer.supportsPlayerID = supportedMission.owningPlayerID
                return updatedPlayer.update(on: req).map(to: Response.self) { savedPlayer in
                    return req.redirect(to: "/main")
                }
            }
        }
    }
    
    router.get("donate/to/supportedPlayer") { req -> Future<Response> in
        guard let id = getPlayerIDFromSession(on: req) else {
            throw Abort(.unauthorized)
        }
        
        return Player.find(id, on: req).flatMap(to: Response.self) { player in
            guard var changedPlayer = player else {
                return Future.map(on: req) { return req.redirect(to: "/")}
            }
            
            return try changedPlayer.donateToSupportedPlayer(cash: 1000, on: req).flatMap(to: Response.self) { result in
                switch result {
                case .success(let result):
                    return result.donatingPlayer.update(on: req).flatMap(to: Response.self) { updatedDonatingPlayer in
                        return result.receivingPlayer.update(on: req).map(to: Response.self) { updatedReceivingPlayer in
                            return req.redirect(to: "/main")
                        }
                    }
                case .failure(let error):
                    if let playerError = error as? Player.PlayerError {
                        if playerError == .insufficientFunds {
                            errorMessages[changedPlayer.id!] = "Insufficient funds to donate."
                            return Future.map(on: req) { return req.redirect(to: "/main") }
                        } else {
                            throw error
                        }
                    } else {
                        throw error
                    }
                }
            }
        }
    }
    
    router.get("build/component", String.parameter) { req -> Future<Response> in
        let shortNameString: String = try req.parameters.next()
        
        guard let shortName = Component.ShortName.init(rawValue: shortNameString) else {
            throw Abort(.badRequest, reason: "\(shortNameString) is not a valid component shortname.")
        }
        
        guard let component = Component.getComponentByName(shortName) else {
            throw Abort(.notFound, reason: "No component with shortName \(shortName) found.")
        }
        
        return getSimulation(on: req).flatMap(to: Response.self) { simulation in
            return try getPlayerFromSession(on: req).flatMap(to: Response.self) { player in
                return try player.investInComponent(component, on: req, date: simulation.gameDate).flatMap(to: Response.self) { result in
                    switch result {
                    case .failure(let error):
                        throw error
                    case .success(let investmentResult):
                        return investmentResult.changedPlayer.save(on: req).flatMap(to: Response.self) { savedPlayer in
                            return investmentResult.changedMission.save(on: req).map(to: Response.self) { savedMission in
                                return req.redirect(to: "/main")
                            }
                        }
                    }
                }
            }
        }
        
    }
     
    router.get("upgrade/techLevel") { req -> Future<Response> in
        return try getPlayerFromSession(on: req).flatMap(to: Response.self) { player in
            do {
                let changedPlayer = try player.investInNextLevelOfTechnology()
                return changedPlayer.save(on: req).map(to: Response.self) { savedPlayer in
                    return req.redirect(to: "/main")
                }
            } catch {
                switch error {
                case Player.PlayerError.insufficientTechPoints:
                    print("Insufficient funds to upgrade.")
                    return Future.map(on: req) { return req.redirect(to: "/main") }
                default:
                    throw error
                }
            }
        }
    }
    
    router.get("advance/stage") { req -> Future<Response> in
        return try getPlayerFromSession(on: req).flatMap(to: Response.self) { player in
            return try player.getSupportedMission(on: req).flatMap(to: Response.self) { mission in
                guard let mission = mission else {
                    throw Abort(.badRequest, reason: "No mission found for player.")
                }
                
                let advancedMission = try mission.goToNextStage()
                
                return advancedMission.save(on: req).map(to: Response.self) { savedMission in
                    return req.redirect(to: "/main")
                }
            }
        }
    }
    
    router.get("debug", "allUsers") { req -> Future<[Player]> in
        return Player.query(on: req).all()
    }
    
    router.post("debug", "cash") { req -> Future<[Player]> in
        return Player.query(on: req).all().flatMap(to: [Player].self) { players in
            let richPlayers = players.map { player -> Player in
                var changedPlayer = player
                changedPlayer.debug_setCash(10_000_000_000)
                return changedPlayer
            }
            
            return Player.savePlayers(richPlayers, on: req)
        }
    }
    
    router.get() { req in
        return try req.view().render("index")
    }
    
    func getPlayerIDFromSession(on req: Request) -> UUID? {
        if let session = try? req.session() {
            if let playerID = session["playerID"] {
                return UUID(playerID)
            }
        }
        return nil
    }
    
    func getSimulation(on req: Request) -> Future<Simulation> {
        if let simulationID = Simulation.GLOBAL_SIMULATION_ID {
            return Simulation.find(simulationID, on: req).map(to: Simulation.self) { sim in
                guard let simulation = sim else {
                    throw Abort(.notFound, reason: "Simulation with ID \(simulationID) not found in database.")
                }
                // print("Loaded simulation from database.")
                return simulation
            }
        } else {
            // search for the simulation
            return Simulation.query(on: req).all().flatMap(to: Simulation.self) { sims in
                if let simulation = sims.first {
                    print("Found simulation in database, setting GLOBAL_SIMULATION_ID")
                    Simulation.GLOBAL_SIMULATION_ID = simulation.id!
                    return Future.map(on: req) { return simulation }
                } else {
                    // create a new simulation
                    print("Creating new simulation.")
                    let gameDate = Date().addingTimeInterval(Double(SECONDS_IN_YEAR))
                    let simulation = Simulation(tickCount: 0, gameDate: gameDate, nextUpdateDate: Date())
                    return simulation.create(on: req).map(to: Simulation.self) { sim in
                        Simulation.GLOBAL_SIMULATION_ID = sim.id!
                        return sim
                    }
                }
            }
        }
    }
    
    func getMainViewForPlayer(with id: UUID, simulation: Simulation, on req: Request) -> Future<View> {
        struct MainContext: Codable {
            let player: Player
            let mission: Mission?
            let currentStage: Stage?
            let currentBuildingComponent: Component?
            let costOfNextTechnologyLevel: Double
            let simulation: Simulation
            let errorMessage: String?
            let currentStageComplete: Bool
        }
        
        return Player.find(id, on: req).flatMap(to: View.self) { player in
            guard let player = player else {
                print("Could not find user with id: \(id)")
                throw Abort(.unauthorized)
            }
            
            let errorMessage = errorMessages[id] ?? nil
            errorMessages.removeValue(forKey: id)
 
            // does this player have his/her own mission?
            if let missionID = player.ownsMissionID {
                return try player.getSupportedMission(on: req).flatMap(to: View.self) { mission in
                    guard let mission = mission else {
                        throw Abort(.notFound, reason: "Mission with id \(missionID) does not exist.")
                    }
                    
                    if mission.missionComplete {
                        return try req.view().render("win")
                    }
                    
                    let context = MainContext(player: player, mission: mission, currentStage: mission.currentStage, currentBuildingComponent: mission.currentStage.currentlyBuildingComponent, costOfNextTechnologyLevel: player.costOfNextTechnologyLevel, simulation: simulation, errorMessage: errorMessage, currentStageComplete: mission.currentStage.stageComplete)
                    
                    return try req.view().render("main", context)
                }
            }
            
            // this player does not own his/her own mission, perhaps he/she supports the mission of another player?
            else if let supportedPlayerID = player.supportsPlayerID {
                return try player.getSupportedPlayer(on: req).flatMap(to: View.self) { supportedPlayer in
                    guard let supportedPlayer = supportedPlayer else {
                        throw Abort(.notFound, reason: "Player with id\(supportedPlayerID) does not exist.")
                    }
                    
                    return try supportedPlayer.getSupportedMission(on: req).flatMap(to: View.self) { supportedMission in
                        guard let supportedMission = supportedMission else {
                            throw Abort(.notFound, reason: "Mission with id \(String(describing: supportedPlayer.ownsMissionID)) does not exist.")
                        }
                        
                        if supportedMission.missionComplete {
                            return try req.view().render("win")
                        }
                        
                        let context = MainContext(player: player, mission: supportedMission, currentStage: supportedMission.currentStage, currentBuildingComponent: supportedMission.currentStage.currentlyBuildingComponent, costOfNextTechnologyLevel: player.costOfNextTechnologyLevel, simulation: simulation, errorMessage: errorMessage, currentStageComplete: supportedMission.currentStage.stageComplete)
                        
                        return try req.view().render("main", context)
                    }
                }
            } else {
                let context = MainContext(player: player, mission: nil, currentStage: nil, currentBuildingComponent: nil ,costOfNextTechnologyLevel: player.costOfNextTechnologyLevel, simulation: simulation, errorMessage: errorMessage, currentStageComplete: false)
            
                return try req.view().render("main", context)
            }
        }
    }
    
    func getPlayerFromSession(on req: Request) throws -> Future<Player> {
        guard let id = getPlayerIDFromSession(on: req) else {
            throw Abort(.unauthorized)
        }
        
        return Player.find(id, on: req).map(to: Player.self) { player in
            guard let player = player else {
                throw Abort(.unauthorized)
            }
            return player
        }
    }
}

struct MissionContext: Content {
    let id: UUID
    let missionName: String
    let percentageDone: Double
    let successChance: Double
    let owningPlayerName: String
}
