//
//  FrontEndController.swift
//  App
//
//  Created by Maarten Engels on 29/12/2019.
//

import Foundation
import Vapor
import Leaf
import Model
import MailJet

class FrontEndController: RouteCollection {
    
    // this is an ugly hack to get the application (we need it as a worker to do the DB actions for the update of the simulation)
    static var app: Application!
    var errorMessages = [UUID: String?]()
    var infoMessages = [UUID: String?]()
    var simulationIsUpdating = false
    
    func boot(router: Router) throws {
        router.get("create/player") { req -> Future<View> in
            return try req.view().render("createPlayer", ["startingImprovements": Improvement.startImprovements])
        }
        
        router.post("create/player") { req -> Future<View> in
            struct CreateCharacterContext: Codable {
                var errorMessage = "noError"
                var email = ""
                var uuid = "unknown"
            }
            let emailAddress: String = try req.content.syncGet(at: "emailAddress")
            let name: String = try req.content.syncGet(at: "name")
            let shortNameForm: Int = try req.content.syncGet(at: "startingImprovement")
            guard let startingImprovement = Improvement.ShortName.init(rawValue: shortNameForm) else {
                throw Abort(.badRequest, reason: "Invalid starting improvement shortname \(shortNameForm).")
            }
            
            return Player.createUser(emailAddress: emailAddress, name: name, startImprovementShortName: startingImprovement, on: req).flatMap(to: View.self) { result in
                var context = CreateCharacterContext()
                
                switch result {
                case .success(let player):
                    context.uuid = String(player.id!)
                    context.email = player.emailAddress
                    
                    if let publicKey = Environment.get("MAILJET_API_KEY"), let privateKey = Environment.get("MAILJET_SECRET_KEY") {
                    
                        let mailJetConfig = MailJetConfig(apiKey: publicKey, secretKey: privateKey, senderName: "Mission2Mars Support", senderEmail: "support@mission2mars.space")
                        mailJetConfig.sendMessage(to: emailAddress, toName: name, subject: "Your login id", message: """
                            Welcome \(player.name) to Mission2Mars
                            
                            Your login id is: \(player.id!)
                            Please keep this code secret, as there is no other authentication method at this time!
                            
                            Have fun!
                            
                            - the Mission2Mars team
                            Sent from: \(Environment.get("ENVIRONMENT") ?? "local test")
                            """, htmlMessage: """
                            <h1>Welcome \(player.name) to Mission2Mars</h1>
                            
                            <h3>Your login id is: <b>\(player.id!)</b></h3>
                            <p>Please keep this code secret, as there is no other authentication method at this time!</p>
                            <p>&nbsp;</p>
                            <p>Have fun!</p>
                            <p>&nbsp;</p>
                            <p>- the Mission2Mars team</p>
                            <p>Sent from: \(Environment.get("ENVIRONMENT") ?? "unknown")</p>
                            """, on: req)
                        }
                case .failure(let error):
                    switch error {
                    case .userAlreadyExists:
                        context.errorMessage = "A user with email address '\(emailAddress)' already exists. Please choose another one."
                    default:
                        context.errorMessage = error.localizedDescription
                    }
                }
                
                return try req.view().render("userCreated", context)
            }
        }
        
        router.post("login") { req -> Response in
            let idString: String = (try? req.content.syncGet(at: "playerid")) ?? ""
            
            guard UUID(idString) != nil else {
                print("\(idString) is not a valid user id")
                return req.redirect(to: "/")
            }
            
            try req.session()["playerID"] = idString
            return req.redirect(to: "/main")
        }
        
        router.get("main") { req in
            return try mainPage(req: req, page: "main")
        }
        
        router.get("mission") { req in
            return try mainPage(req: req, page: "mission")
        }
        
        router.get("technology") { req in
            return try mainPage(req: req, page: "technology")
        }
        
        router.get("improvements") { req in
            return try mainPage(req: req, page: "improvements")
        }
        
        
        func mainPage(req: Request, page: String) throws -> Future<View> {
            guard let id = self.getPlayerIDFromSession(on: req) else {
                return try req.view().render("index")
            }
            
            if simulationIsUpdating {
                self.infoMessages[id] = "Simulation is updating. Thanks for your patience!"
            }
            
            // NOTE: updating 1000 players takes ~3.5 seconds
            // 5000 players takes ~35 seconds
            // 6000 players takes ~53 seconds
            // NON LINEAR behaviour
            return self.getSimulation(on: req).flatMap(to: View.self) { simulation in
                let startUpdateTime = Date()
                if simulation.simulationShouldUpdate(currentDate: Date()) && self.simulationIsUpdating == false {
                    self.simulationIsUpdating = true
                    
                    _ = FrontEndController.app.withPooledConnection(to: .sqlite) { conn -> Future<Void> in
                        return Player.query(on: conn).all().flatMap(to: Void.self) { players in
                            return Mission.query(on: conn).all().flatMap(to: Void.self) { missions in
                                
                                print("Loading all data took: \(startUpdateTime.timeIntervalSinceNow.magnitude) seconds.")
                                //var stopWatch = Date()
                                let result = simulation.updateSimulation(currentDate: Date(), players: players, missions: missions)
                                //print("Updating simulation struct took: \(stopWatch.timeIntervalSinceNow.magnitude) seconds.")
                                assert(simulation.id != nil)
                                assert(result.updatedSimulation.id != nil)
                                assert(simulation.id == result.updatedSimulation.id)
                                //stopWatch = Date()
                                return result.updatedSimulation.update(on: conn).flatMap(to: Void.self) { savedSimulation in
                                    return Player.savePlayers(result.updatedPlayers, on: conn).flatMap(to: Void.self) { players in
                                        //print("Saving players took: \(stopWatch.timeIntervalSinceNow.magnitude) seconds")
                                        /*print("Start sleep")
                                        sleep(10)
                                        print("End sleep")*/
                                        //stopWatch = Date()
                                        return Mission.saveMissions(result.updatedMissions, on: conn).map(to: Void.self) { [weak self] missions in
                                            //print("Saving missions took: \(stopWatch.timeIntervalSinceNow.magnitude) seconds")
                                            assert(self != nil)
                                            self!.simulationIsUpdating = false
                                            self?.infoMessages[id] = "Simulation updated. Thanks for your patience!"
                                            print("Update took: \(startUpdateTime.timeIntervalSinceNow.magnitude) seconds.")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                return self.getMainViewForPlayer(with: id, simulation: simulation, on: req, page: page)
            }
        }
        
        router.get("edit/mission") { req -> Future<View> in
            return try self.getPlayerFromSession(on: req).flatMap(to: View.self) { player in
                return try player.getSupportedMission(on: req).flatMap(to: View.self) { missionResult in
                    switch missionResult {
                    case .success(let mission):
                        return try req.view().render("editMission", ["missionName": mission.missionName])
                    case .failure(let error):
                        throw error
                    }
                }
            }
        }
        
        router.post("edit/mission") { req -> Future<Response> in
            let newName: String = try req.content.syncGet(at: "missionName")
            return try self.getPlayerFromSession(on: req).flatMap(to: Response.self) { player in
                return try player.getSupportedMission(on: req).flatMap(to: Response.self) { missionResult in
                    switch missionResult {
                    case .success(var mission):
                        mission.missionName = newName
                        return mission.update(on: req).map(to: Response.self) { savedMission in
                            return req.redirect(to: "/mission")
                        }
                    case .failure(let error):
                        throw error
                    }
                }
            }
        }
        
        router.get("create/mission") { req -> Future<Response> in
            return try self.getPlayerFromSession(on: req).flatMap(to: Response.self) { player in
                assert(player.id != nil)
                
                let mission = Mission(owningPlayerID: player.id!)
                return mission.create(on: req).flatMap(to: Response.self) { mission in
                    var updatedPlayer = player
                    updatedPlayer.ownsMissionID = mission.id
                    return updatedPlayer.save(on: req).map(to: Response.self) { updatedPlayer in
                        return req.redirect(to: "/mission")
                    }
                }
            }
        }
        
        router.get("support/mission") { req -> Future<View> in
            guard self.getPlayerIDFromSession(on: req) != nil else {
                throw Abort(.unauthorized)
            }
            
            return Mission.query(on: req).all().flatMap(to: View.self) { missions in
                let unfinishedMissions = missions.filter { mission in mission.missionComplete == false }
                let playerFutures = try unfinishedMissions.map { mission in
                    return try mission.getOwningPlayer(on: req)
                }
                let playerFuture = playerFutures.flatten(on: req)
                
                return playerFuture.flatMap(to: View.self) { playerResults in
                    var mcs = [MissionContext]()
                    for i in 0 ..< playerResults.count {
                        switch playerResults[i] {
                        case .success(let player):
                            mcs.append(MissionContext(id: missions[i].id!, missionName: missions[i].missionName, percentageDone: missions[i].percentageDone, owningPlayerName: player.name))
                        case .failure(let error):
                            print(error)
                        }
                    }
                    return try req.view().render("missions", ["missions": mcs])
                }
            }
        }
        
        router.get("support/mission", UUID.parameter) { req -> Future<Response> in
            let supportedMissionID: UUID = try req.parameters.next()
            
            return try self.getPlayerFromSession(on: req).flatMap(to: Response.self) { player in
                return Mission.find(supportedMissionID, on: req).flatMap(to: Response.self) { mission in
                    guard let supportedMission = mission else {
                        throw Abort(.notFound, reason: "Could not find mission with id \(supportedMissionID)")
                    }
                    
                    guard supportedMission.missionComplete == false else {
                        self.errorMessages[player.id!] = "You cannot support a mission that is already complete."
                        return Future.map(on: req) { return req.redirect(to: "/main") }
                    }
                    
                    var updatedPlayer = player
                    
                    updatedPlayer.supportsPlayerID = supportedMission.owningPlayerID
                    return updatedPlayer.update(on: req).map(to: Response.self) { savedPlayer in
                        return req.redirect(to: "/mission")
                    }
                }
            }
        }
        
        router.get("donate/to", String.parameter) { req -> Future<View> in
            struct DonateContext: Content {
                let player: Player
                let receivingPlayerName: String
                let receivingPlayerEmail: String
            }
            
            let receivingPlayerEmail: String = try req.parameters.next()
            
            return try self.getPlayerFromSession(on: req).flatMap(to: View.self) {
            player in
                return Player.query(on: req).filter(\.emailAddress, .equal, receivingPlayerEmail).first().flatMap(to: View.self) { receivingPlayer in
                    guard let receivingPlayer = receivingPlayer else {
                        throw Abort(.notFound, reason: "Could not find player with emailadress \(receivingPlayerEmail)")
                    }
                    
                    let context = DonateContext(player: player, receivingPlayerName: receivingPlayer.name, receivingPlayerEmail: receivingPlayer.emailAddress)
                        return try req.view().render("donate", context)
                    }
            }
        }
        
        router.get("donate/to", String.parameter, "cash", String.parameter) { req -> Future<Response> in
            guard let id = self.getPlayerIDFromSession(on: req) else {
                throw Abort(.unauthorized)
            }
            
            let receivingPlayerEmail: String = try req.parameters.next()
            let donateString: String = try req.parameters.next()
            
            return Player.find(id, on: req).flatMap(to: Response.self) { player in
                guard let donatingPlayer = player else {
                    return Future.map(on: req) { return req.redirect(to: "/")}
                }
                
                return Player.query(on: req).filter(\.emailAddress, .equal, receivingPlayerEmail).first().flatMap(to: Response.self) { receivingPlayer in
                    guard let receivingPlayer = receivingPlayer else {
                        return Future.map(on: req) { return req.redirect(to: "/")}
                    }
                    
                    let cash: Double
                    switch donateString {
                    case "1k":
                        cash = 1_000
                    case "10k":
                        cash = 10_000
                    case "100k":
                        cash = 100_000
                    case "1m":
                        cash = 1_000_000
                    case "1b":
                        cash = 1_000_000_000
                    case "10b":
                        cash = 10_000_000_000
                    default:
                        cash = 0
                    }
                    
                    return try donatingPlayer.donateToPlayerSupportingSameMission(cash: cash, receivingPlayer: receivingPlayer, on: req).flatMap(to: Response.self) { donationResult in
                        switch donationResult{
                        case .success(let changedDonatingPlayer, let changedReceivingPlayer):
                            return changedDonatingPlayer.update(on: req).flatMap(to: Response.self) { updatedDonatingPlayer in
                                return changedReceivingPlayer.update(on: req).map(to: Response.self) { updatedReceivingPlayer in
                                    self.infoMessages[changedDonatingPlayer.id!] = "You donated $\(Int(cash)) to \(changedReceivingPlayer.name)"
                                    return req.redirect(to: "/mission")
                                }
                            }
                        case .failure(let error):
                            if let playerError = error as? Player.PlayerError {
                                if playerError == .insufficientFunds {
                                    self.errorMessages[donatingPlayer.id!] = "Insufficient funds to donate."
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
        }
        
        router.get("donate/to", String.parameter, "tech", Int.parameter) { req -> Future<Response> in
            guard let id = self.getPlayerIDFromSession(on: req) else {
                throw Abort(.unauthorized)
            }
            
            let receivingPlayerEmail: String = try req.parameters.next()
            let techPoints: Int = try req.parameters.next()
            
            return Player.find(id, on: req).flatMap(to: Response.self) { player in
                guard let donatingPlayer = player else {
                    return Future.map(on: req) { return req.redirect(to: "/")}
                }
                
                return Player.query(on: req).filter(\.emailAddress, .equal, receivingPlayerEmail).first().flatMap(to: Response.self) { receivingPlayer in
                    guard let receivingPlayer = receivingPlayer else {
                        return Future.map(on: req) { return req.redirect(to: "/")}
                    }
                    
                    return try donatingPlayer.donateToPlayerSupportingSameMission(tech: Double(techPoints), receivingPlayer: receivingPlayer, on: req).flatMap(to: Response.self) { donationResult in
                        switch donationResult{
                        case .success(let changedDonatingPlayer, let changedReceivingPlayer):
                            return changedDonatingPlayer.update(on: req).flatMap(to: Response.self) { updatedDonatingPlayer in
                                return changedReceivingPlayer.update(on: req).map(to: Response.self) { updatedReceivingPlayer in
                                    self.infoMessages[changedDonatingPlayer.id!] = "You donated \(techPoints) technology points to \(changedReceivingPlayer.name)"
                                    return req.redirect(to: "/mission")
                                }
                            }
                        case .failure(let error):
                            if let playerError = error as? Player.PlayerError {
                                if playerError == .insufficientFunds {
                                    self.errorMessages[donatingPlayer.id!] = "Insufficient technology points to donate."
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
        }
        
        router.get("build/component", String.parameter) { req -> Future<Response> in
            let shortNameString: String = try req.parameters.next()
            
            guard let shortName = Component.ShortName.init(rawValue: shortNameString) else {
                throw Abort(.badRequest, reason: "\(shortNameString) is not a valid component shortname.")
            }
            
            guard let component = Component.getComponentByName(shortName) else {
                throw Abort(.notFound, reason: "No component with shortName \(shortName) found.")
            }
            
            return self.getSimulation(on: req).flatMap(to: Response.self) { simulation in
                return try self.getPlayerFromSession(on: req).flatMap(to: Response.self) { player in
                    return try player.investInComponent(component, on: req, date: simulation.gameDate).flatMap(to: Response.self) { result in
                        switch result {
                        case .failure(let error):
                            throw error
                            
                        case .success(let investmentResult):
                            return investmentResult.changedPlayer.save(on: req).flatMap(to: Response.self) { savedPlayer in
                                return investmentResult.changedMission.save(on: req).map(to: Response.self) { savedMission in
                                    return req.redirect(to: "/mission")
                                }
                            }
                        }
                    }
                }
            }
            
        }
        
        router.get("advance/stage") { req -> Future<Response> in
            return try self.getPlayerFromSession(on: req).flatMap(to: Response.self) { player in
                return try player.getSupportedMission(on: req).flatMap(to: Response.self) { missionResult in
                    switch missionResult {
                    case .success(let mission):
                        let advancedMission = try mission.goToNextStage()
                        
                        return advancedMission.save(on: req).map(to: Response.self) { savedMission in
                            return req.redirect(to: "/mission")
                        }
                    case .failure(let error):
                        throw error
                    }
                }
            }
        }
        
        router.get("build/improvements") { req -> Future<View> in
            struct ImprovementBuildContext: Codable {
                let player: Player
                let possibleImprovements: [Improvement]
            }
            
            return try self.getPlayerFromSession(on: req).flatMap(to: View.self) {
            player in
                
                let possibleImprovements = Improvement.unlockedImprovementsForPlayer(player)/*.filter { improvement in
                    // filter out the improvements the player has already built
                    player.improvements.contains(improvement) == false
                }*/
                
                let context = ImprovementBuildContext(player: player, possibleImprovements: possibleImprovements)
                
                return try req.view().render("improvements", context)
            }
        }
        
        router.get("build/improvements", Int.parameter) { req -> Future<Response> in
            let number: Int = try req.parameters.next()
            
            guard let shortName = Improvement.ShortName(rawValue: number) else {
                return Future.map(on: req) { return req.redirect(to: "/main")}
            }
            
            return try self.getPlayerFromSession(on: req).flatMap(to: Response.self) {
            player in
                guard let improvement = Improvement.getImprovementByName(shortName) else {
                    self.errorMessages[player.id!] = "No improvement with shortName \(shortName) found."
                    return Future.map(on: req) { return req.redirect(to: "/main")}
                }
                
                do {
                    
                    let buildingPlayer = try player.startBuildImprovement(improvement, startDate: Date())
                    return buildingPlayer.save(on: req).map(to: Response.self) { savedPlayer in
                        self.infoMessages[savedPlayer.id!] = "Started working on \(improvement.name)."
                        return req.redirect(to: "/improvements")
                    }
                } catch {
                    switch error {
                    case Player.PlayerError.insufficientImprovementSlots:
                        self.errorMessages[player.id!] = "You can have a maximum of \(player.improvementSlotsCount) improvements."
                    case Player.PlayerError.insufficientFunds:
                        self.errorMessages[player.id!] = "Insufficient funds to build \(improvement.name)."
                        return Future.map(on: req) { return req.redirect(to: "/main") }
                    case Player.PlayerError.playerIsAlreadyBuildingImprovement:
                        self.errorMessages[player.id!] = "You can't build \(improvement.name) while you are building \(player.currentlyBuildingImprovement?.name ?? "unknown")"
                        return Future.map(on: req) { return req.redirect(to: "/main") }
                    default:
                        throw error
                    }
                    return Future.map(on: req) { return req.redirect(to: "/main") }
                }
            }
        }
        
        router.get("rush/improvements", Int.parameter) { req -> Future<Response> in
            let number: Int = try req.parameters.next()
            
            guard let shortName = Improvement.ShortName(rawValue: number) else {
                return Future.map(on: req) { return req.redirect(to: "/main")}
            }
            
            return try self.getPlayerFromSession(on: req).flatMap(to: Response.self) {
            player in
                guard let improvement = Improvement.getImprovementByName(shortName) else {
                    self.errorMessages[player.id!] = "No improvement with shortName \(shortName) found."
                    return Future.map(on: req) { return req.redirect(to: "/main")}
                }
                
                do {
                    let rushingPlayer = try player.rushImprovement(improvement)
                    return rushingPlayer.save(on: req).map(to: Response.self) { savedPlayer in
                        self.infoMessages[savedPlayer.id!] = "Succesfully rushed \(improvement.name)."
                        return req.redirect(to: "/improvements")
                    }
                } catch {
                    switch error {
                    case Player.PlayerError.insufficientFunds:
                        self.errorMessages[player.id!] = "Insufficient funds to rush \(improvement.name)."
                        return Future.map(on: req) { return req.redirect(to: "/main") }
                    case Improvement.ImprovementError.improvementCannotBeRushed:
                        self.errorMessages[player.id!] = "\(improvement.name) cannot be rushed."
                        return Future.map(on: req) { return req.redirect(to: "/main") }
                    default:
                        self.errorMessages[player.id!] = error.localizedDescription
                        return Future.map(on: req) { return req.redirect(to: "/main") }
                    }
                    //return Future.map(on: req) { return req.redirect(to: "/main") }
                }
            }
        }
        
        router.get("sell/improvement", Int.parameter) { req -> Future<Response> in
            let number: Int = try req.parameters.next()
            
            guard let shortName = Improvement.ShortName(rawValue: number) else {
                return Future.map(on: req) { return req.redirect(to: "/main")}
            }
            
            return try self.getPlayerFromSession(on: req).flatMap(to: Response.self) {
            player in
                guard let improvement = Improvement.getImprovementByName(shortName) else {
                    self.errorMessages[player.id!] = "No improvement with shortName \(shortName) found."
                    return Future.map(on: req) { return req.redirect(to: "/main")}
                }
                
                do {
                    let sellingPlayer = try player.sellImprovement(improvement)
                    return sellingPlayer.save(on: req).map(to: Response.self) { savedPlayer in
                        self.infoMessages[savedPlayer.id!] = "Succesfully sold \(improvement.name)."
                        return req.redirect(to: "/improvements")
                    }
                } catch {
                    switch error {
                    case Improvement.ImprovementError.improvementIncomplete:
                        self.errorMessages[player.id!] = "You can only sell completed improvements."
                        return Future.map(on: req) { return req.redirect(to: "/main") }
                    default:
                        self.errorMessages[player.id!] = error.localizedDescription
                        return Future.map(on: req) { return req.redirect(to: "/main") }
                    }
                    //return Future.map(on: req) { return req.redirect(to: "/main") }
                }
            }
        }
        
        router.get("mission/supportingPlayers") { req -> Future<View> in
            struct SupportingPlayerContext: Content {
                let player: Player
                let supportingPlayers: [Player]
                let mission: Mission
            }
            
            return try self.getPlayerFromSession(on: req).flatMap(to: View.self) {
            player in
                return try player.getSupportedMission(on: req).flatMap(to: View.self) { missionResult in
                    switch missionResult {
                    case .success(let mission):
                        return try mission.getSupportingPlayers(on: req).flatMap(to: View.self) { supportingPlayers in
                            let context = SupportingPlayerContext(player: player, supportingPlayers: supportingPlayers, mission: mission)
                            return try req.view().render("mission_supportingPlayers", context)
                        }
                    case .failure(let error):
                        throw error
                    }
                }
            }
        }
        
        router.get("unlock/technologies") { req -> Future<View> in
            struct UnlockTechnologyContext: Codable {
                let player: Player
                let possibleTechnologies: [Technology]
            }
            
            return try self.getPlayerFromSession(on: req).flatMap(to: View.self) {
            player in
                
                let possibleTechnologies = Technology.unlockableTechnologiesForPlayer(player)
                
                let context = UnlockTechnologyContext(player: player, possibleTechnologies: possibleTechnologies)
                
                return try req.view().render("technologies", context)
            }
        }
        
        router.get("unlock/technologies", Int.parameter) { req -> Future<Response> in
            let number: Int = try req.parameters.next()
            
            guard let shortName = Technology.ShortName(rawValue: number) else {
                return Future.map(on: req) { return req.redirect(to: "/main")}
            }
            
            return try self.getPlayerFromSession(on: req).flatMap(to: Response.self) {
            player in
                guard let technology = Technology.getTechnologyByName(shortName) else {
                    self.errorMessages[player.id!] = "No technology with shortName \(shortName) found."
                    return Future.map(on: req) { return req.redirect(to: "/main")}
                }
                
                do {
                    
                    let unlockingPlayer = try player.investInTechnology(technology)
                    return unlockingPlayer.save(on: req).map(to: Response.self) { savedPlayer in
                        self.infoMessages[savedPlayer.id!] = "Succesfully unlocked \(technology.name)."
                        return req.redirect(to: "/technology")
                    }
                } catch {
                    switch error {
                    case Player.PlayerError.playerAlreadyUnlockedTechnology:
                        self.errorMessages[player.id!] = "You already unlocked \(technology.name)."
                    case Player.PlayerError.insufficientTechPoints:
                        self.errorMessages[player.id!] = "Insufficient technology points to unlock \(technology.name)."
                    case Player.PlayerError.playerMissesPrerequisiteTechnology:
                        self.errorMessages[player.id!] = "You miss the prerequisite technology to unlock \(technology.name)."
                    default:
                        throw error
                    }
                    return Future.map(on: req) { return req.redirect(to: "/main") }
                }
            }
        }
        
        router.get("debug", "allUsers") { req -> Future<[Player]> in
            guard (Environment.get("DEBUG_MODE") ?? "inactive") == "active" else {
                throw Abort(.notFound)
            }
            return Player.query(on: req).all()
        }
        
        router.post("debug", "cash") { req -> Future<[Player]> in
            guard (Environment.get("DEBUG_MODE") ?? "inactive") == "active" else {
                throw Abort(.notFound)
            }
            
            return Player.query(on: req).all().flatMap(to: [Player].self) { players in
                let richPlayers = players.map { player -> Player in
                    var changedPlayer = player
                    changedPlayer.debug_setCash(4_000_000_000)
                    return changedPlayer
                }
                
                return Player.savePlayers(richPlayers, on: req)
            }
        }
        
        router.post("debug", "tech") { req -> Future<[Player]> in
            guard (Environment.get("DEBUG_MODE") ?? "inactive") == "active" else {
                throw Abort(.notFound)
            }
            
            return Player.query(on: req).all().flatMap(to: [Player].self) { players in
                let smartPlayers = players.map { player -> Player in
                    var changedPlayer = player
                    changedPlayer.debug_setTech(1000)
                    return changedPlayer
                }
                
                return Player.savePlayers(smartPlayers, on: req)
            }
        }
        
        router.post("debug", "createDummyUsers") { req -> Future<[Player]> in
            guard (Environment.get("DEBUG_MODE") ?? "inactive") == "active" else {
                throw Abort(.notFound)
            }
            
            var futures = [Future<Player>]()
            for i in 0 ..< 1_000 {
                let playerFuture = Player.createUser(emailAddress: "dummyUser\(i)\(Int.random(in: 0...1_000_000))@example.com", name: "dummyUser\(i)\(Int.random(in: 0...1_000_000))", on: req).map(to: Player.self) { result in
                    switch result {
                    case .success(let player):
                        return player
                    case .failure(let error):
                        throw error
                    }
                }
                futures.append(playerFuture)
            }
            return futures.flatten(on: req)
        }
        
        router.get() { req in
            return try req.view().render("index")
        }
        
        struct DataDump: Content {
            let simulation: Simulation
            let players: [Player]
            let missions: [Mission]
        }
        
        router.get("debug/backup") { req -> Future<String> in
            guard (Environment.get("DEBUG_MODE") ?? "inactive") == "active" else {
                throw Abort(.notFound)
            }
            
            return self.getSimulation(on: req).flatMap(to: String.self) { simulation in
                return Player.query(on: req).all().flatMap(to: String.self) { players in
                    return Mission.query(on: req).all().map(to: String.self) { missions in
                        do {
                            let dataDump = DataDump(simulation: simulation, players: players, missions: missions)
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = .prettyPrinted
                            let data = try encoder.encode(dataDump)
                            let backupDir = Environment.get("BACKUP_PATH") ?? ""
                            let formatter = DateFormatter()
                            formatter.dateFormat = "YYYYMMdd_HHmmss"
                            
                            let formattedDate = formatter.string(from: Date())
                            print(formattedDate)
                            let url = URL(fileURLWithPath: "\(backupDir)backup_\(formattedDate).json")
                            try data.write(to: url)
                            return "Done"
                        } catch {
                            print(error)
                            return("Error while backup up: \(error).")
                        }
                    }
                }
            }
        }
        
        router.get("debug/dataDump") { req -> Future<DataDump> in
            guard (Environment.get("DEBUG_MODE") ?? "inactive") == "active" else {
                throw Abort(.notFound)
            }
            
            return self.getSimulation(on: req).flatMap(to: DataDump.self) { simulation in
                return Player.query(on: req).all().flatMap(to: DataDump.self) { players in
                    return Mission.query(on: req).all().map(to: DataDump.self) { missions in
                        return DataDump(simulation: simulation, players: players, missions: missions)
                    }
                }
            }
        }
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
    
    func getMainViewForPlayer(with id: UUID, simulation: Simulation, on req: Request, page: String = "overview") -> Future<View> {
        struct MainContext: Codable {
            let player: Player
            let mission: Mission?
            let currentStage: Stage?
            let currentBuildingComponents: [Component]
            let simulation: Simulation
            let errorMessage: String?
            let infoMessage: String?
            let currentStageComplete: Bool
            let unlockableTechnologogies: [Technology]
            let unlockedTechnologies: [Technology]
            let unlockedComponents: [Component]
            let techlockedComponents: [Component]
            let playerIsBuildingComponent: Bool
            let cashPerDay: Double
            let techPerDay: Double
            let page: String
            let simulationIsUpdating: Bool
        }
        
        return Player.find(id, on: req).flatMap(to: View.self) { player in
            guard let player = player else {
                print("Could not find user with id: \(id)")
                throw Abort(.unauthorized)
            }
            
            let errorMessage = self.errorMessages[id] ?? nil
            self.errorMessages.removeValue(forKey: id)
            let infoMessage = self.infoMessages[id] ?? nil
            self.infoMessages.removeValue(forKey: id)
 
            return try player.getSupportedMission(on: req).flatMap(to: View.self) { missionResult in
                switch missionResult {
                case .success(let mission):
                    if mission.missionComplete {
                        return try req.view().render("win")
                    }
                    
                    var unlockedComponents = [Component]()
                    var techlockedComponents = [Component]()
                    
                    for component in mission.currentStage.components {
                        if component.playerHasPrerequisitesForComponent(player) {
                            unlockedComponents.append(component)
                        } else {
                            techlockedComponents.append(component)
                        }
                    }
                    
                    let context = MainContext(player: player, mission: mission, currentStage: mission.currentStage, currentBuildingComponents: mission.currentStage.currentlyBuildingComponents, simulation: simulation, errorMessage: errorMessage, infoMessage: infoMessage, currentStageComplete: mission.currentStage.stageComplete, unlockableTechnologogies: Technology.unlockableTechnologiesForPlayer(player), unlockedTechnologies: player.unlockedTechnologies, unlockedComponents: unlockedComponents, techlockedComponents: techlockedComponents, playerIsBuildingComponent: mission.currentStage.playerIsBuildingComponentInStage(player), cashPerDay: player.cashPerTick, techPerDay: player.techPerTick, page: page, simulationIsUpdating: self.simulationIsUpdating)
                    
                    return try req.view().render("main", context)
                case .failure(let error):
                    if let error = error as? Player.PlayerError {
                        switch error {
                        case .noMission:
                            let context = MainContext(player: player, mission: nil, currentStage: nil, currentBuildingComponents: [], simulation: simulation, errorMessage: errorMessage, infoMessage: infoMessage,  currentStageComplete: false, unlockableTechnologogies: Technology.unlockableTechnologiesForPlayer(player), unlockedTechnologies: player.unlockedTechnologies, unlockedComponents: [], techlockedComponents: [], playerIsBuildingComponent: false, cashPerDay: player.cashPerTick, techPerDay: player.techPerTick, page: page, simulationIsUpdating: self.simulationIsUpdating)
                            
                                return try req.view().render("main", context)
                        default:
                            throw error
                        }
                    } else {
                        throw (error)
                    }
                }
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
    let owningPlayerName: String
}
