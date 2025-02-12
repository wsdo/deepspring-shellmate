import SwiftUI
import Combine
import AXSwift

enum APIKeyValidationState {
    case valid
    case invalid
    case usingFreeTier
}

class AppViewModel: ObservableObject {
    @Published var currentTerminalID: String?
    @Published var currentStateText: String = "No changes on Terminal"
    @Published var updateCounter: Int = 1
    @Published var results: [String: (suggestionsCount: Int, suggestionsHistory: [(UUID, [[String: String]])], updatedAt: Date)] = [:]
    @Published var isGeneratingSuggestion: [String: Bool] = [:]
    @Published var hasUserValidatedOwnOpenAIAPIKey: APIKeyValidationState = .usingFreeTier
    @Published var isAssistantSetupSuccessful: Bool = false
    @Published var areNotificationObserversSetup: Bool = false
    @Published var shouldTroubleShootAPIKey: Bool = false
    @Published var shouldShowNetworkIssueWarning: Bool = false
    @Published var shouldShowSamAltmansFace: Bool = true

    private var consecutiveFailedInternetChecks: Int = 0
    private var internetConnectionGracePeriodTask: Task<Void, Never>?

    private var threadIdDict: [String: String] = [:]
    private var currentTerminalStateID: UUID?
    private let additionalSuggestionDelaySeconds: TimeInterval = 3.0
    private let maxSuggestionsPerEvent: Int = 4
    private var shouldGenerateFollowUpSuggestionsFlag: Bool = true
    private var gptAssistantManager: GPTAssistantManager = GPTAssistantManager.shared

    // UserDefaults keys
    private let GPTSuggestionsFreeTierCountKey = "GPTSuggestionsFreeTierCount"
    private let hasGPTSuggestionsFreeTierCountReachedLimitKey = "hasGPTSuggestionsFreeTierCountReachedLimit"
    private var terminalIDCheckTimer: Timer?
    private var apiKeyValidationDebounceTask: DispatchWorkItem?
    private let isCompanionModeEnabledKey = "isCompanionModeEnabled"
    

    // Limit for free tier suggestions
    @AppStorage("GPTSuggestionsFreeTierLimit") private(set) var GPTSuggestionsFreeTierLimit: Int = 150


    @Published var isCompanionModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCompanionModeEnabled, forKey: isCompanionModeEnabledKey)
        }
    }

    @Published var GPTSuggestionsFreeTierCount: Int {
        didSet {
            UserDefaults.standard.set(GPTSuggestionsFreeTierCount, forKey: GPTSuggestionsFreeTierCountKey)
            updateHasGPTSuggestionsFreeTierCountReachedLimit()
        }
    }
    @Published var hasGPTSuggestionsFreeTierCountReachedLimit: Bool {
        didSet {
            UserDefaults.standard.set(hasGPTSuggestionsFreeTierCountReachedLimit, forKey: hasGPTSuggestionsFreeTierCountReachedLimitKey)
        }
    }
    
    @Published var hasInternetConnection: Bool = true {
        didSet {
            if hasInternetConnection == false {
                print("Internet connection lost. Starting check loop.")
                startInternetCheckLoop()
            } else if hasInternetConnection == true {
                print("Internet connection restored. Resetting connection check state.")
                resetInternetConnectionCheckState()
                
                if !areNotificationObserversSetup {
                    print("Setting up assistant and notification observers.")
                    Task {
                        await initializeAssistant()
                    }
                }
            }
        }
    }
    
    private func startInternetConnectionGracePeriod() {
        // Cancel any existing grace period task
        internetConnectionGracePeriodTask?.cancel()

        internetConnectionGracePeriodTask = Task.detached { [weak self] in
            guard let self = self else { return }

            do {
                // Wait for 10 seconds grace period
                try await Task.sleep(nanoseconds: 10 * 1_000_000_000)

                // Check internet connection status after the grace period
                let isConnected = await checkInternetConnection()
                if !isConnected {
                    print("Internet connection still down after grace period. Showing network issue warning.")
                    DispatchQueue.main.async {
                        self.shouldShowNetworkIssueWarning = true
                    }
                } else {
                    print("Internet connection restored during grace period.")
                    self.resetInternetConnectionCheckState()
                }
            } catch {
                print("Error during grace period task: \(error.localizedDescription)")
            }
        }
    }

    private func resetInternetConnectionCheckState() {
        consecutiveFailedInternetChecks = 0
        shouldShowNetworkIssueWarning = false
        internetConnectionGracePeriodTask?.cancel()
        internetConnectionGracePeriodTask = nil
    }
    
    init() {
        self.isCompanionModeEnabled = UserDefaults.standard.bool(forKey: isCompanionModeEnabledKey)
        self.GPTSuggestionsFreeTierCount = UserDefaults.standard.integer(forKey: GPTSuggestionsFreeTierCountKey)
        self.hasGPTSuggestionsFreeTierCountReachedLimit = UserDefaults.standard.bool(forKey: hasGPTSuggestionsFreeTierCountReachedLimitKey)
        updateHasGPTSuggestionsFreeTierCountReachedLimit()
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleUserValidatedOwnOpenAIAPIKey), name: .userValidatedOwnOpenAIAPIKey, object: nil)

        Task {
            await initializeAssistant()
        }
    }
    
    // Method to calculate the likelihood
    func calculateSamAltmansFaceLikelihood() {
        let n = Double(GPTSuggestionsFreeTierCount)
        let adjustedLikelihood = min(100, (1.0 / (1.5 + n / 10)) * 100)
        let randomValue = Double.random(in: 0...100)
        shouldShowSamAltmansFace = randomValue <= adjustedLikelihood

        // DEBUG statement
        print("DEBUG: GPTSuggestionsFreeTierCount: \(GPTSuggestionsFreeTierCount), Adjusted Likelihood: \(adjustedLikelihood), Random Value: \(randomValue), Should Show Sam Altman's Face: \(shouldShowSamAltmansFace)")
    }

    
    func startInternetCheckLoop() {
        DispatchQueue.global().async {
            self.consecutiveFailedInternetChecks = 0  // Reset the counter at the start of the loop

            while !self.hasInternetConnection {
                Task {
                    let isConnected = await checkInternetConnection()
                    if isConnected {
                        DispatchQueue.main.async {
                            self.hasInternetConnection = true
                        }
                        return
                    } else {
                        DispatchQueue.main.async {
                            self.consecutiveFailedInternetChecks += 1
                            print("Internet check failed. Counter: \(self.consecutiveFailedInternetChecks)")

                            if self.consecutiveFailedInternetChecks == 3 {
                                print("Three consecutive failed internet checks. Starting grace period.")
                                self.startInternetConnectionGracePeriod()
                                return
                            }
                        }
                    }
                }
                sleep(1) // 1 second delay
            }
        }
    }

    
    func initializeAssistant() async {
        print("Starting assistant setup...")
        let success = await gptAssistantManager.setupAssistant()
        DispatchQueue.main.async {
            self.isAssistantSetupSuccessful = success
            if success {
                print("Assistant setup successful.")
                print("Assistant ID: \(self.gptAssistantManager.assistantId)")
                self.shouldTroubleShootAPIKey = false
                self.setupNotificationObservers()
            } else {
                print("Assistant setup failed.")
                Task {
                    print("Checking internet connection...")
                    let isConnected = await checkInternetConnection()
                    DispatchQueue.main.async {
                        print("DEBUG: Internet connection check result: \(isConnected)")
                        if isConnected {
                            print("DEBUG: Assistant setup failed and has internet.")
                            self.shouldTroubleShootAPIKey = true
                        } else {
                            print("DEBUG: Assistant setup failed and has no internet.")
                            self.hasInternetConnection = false
                        }
                    }
                }
            }
        }
    }
    
    func startCheckingTerminalID() {
        terminalIDCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.ensureCurrentTerminalIDHasValue()
        }
    }

    func stopCheckingTerminalID() {
        terminalIDCheckTimer?.invalidate()
        terminalIDCheckTimer = nil
    }
    
    func ensureCurrentTerminalIDHasValue() {
        if currentTerminalID == nil || currentTerminalID?.isEmpty == true {
            print("DEBUG: currentTerminalID is nil or empty. Posting reinitializeTerminalWindowID notification.")
            NotificationCenter.default.post(name: .reinitializeTerminalWindowID, object: nil)
        } else {
            print("DEBUG: currentTerminalID has a value: \(currentTerminalID!)")
            stopCheckingTerminalID() // Stop the timer once a valid ID is found
        }
    }
    
    private func setupNotificationObservers() {
        guard !areNotificationObserversSetup else {
            print("Notification observers are already set up.")
            return
        }

        NotificationCenter.default.addObserver(self, selector: #selector(handleTerminalChangeStarted), name: .terminalContentChangeStarted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleTerminalChangeEnded), name: .terminalContentChangeEnded, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleTerminalWindowIdDidChange(_:)), name: .terminalWindowIdDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRequestTerminalContentAnalysis(_:)), name: .requestTerminalContentAnalysis, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleSuggestionGenerationStatusChanged(_:)), name: .suggestionGenerationStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleUserAcceptedFreeCredits), name: .userAcceptedFreeCredits, object: nil)
        areNotificationObserversSetup = true
        startCheckingTerminalID() // Necessary as sometimes the AppViewModel will only setup the observer for handleTerminalWindowIdDidChange after the first setup was run, so the currentTerminalID would be empty, causing errors
    }
    
    @objc private func handleTerminalChangeStarted() {
        if hasGPTSuggestionsFreeTierCountReachedLimit && hasUserValidatedOwnOpenAIAPIKey == .usingFreeTier {
            return
        } else if hasUserValidatedOwnOpenAIAPIKey == .invalid {
            return
        }
        self.currentStateText = "Detecting changes..."
    }
    
    @objc private func handleTerminalChangeEnded() {
        self.currentStateText = "No changes on Terminal"
        // Process trigger the generation of a suggestion.
    }

    @MainActor
    @objc private func handleTerminalWindowIdDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let windowID = userInfo["terminalWindowID"] as? CGWindowID else {
            return
        }
        self.currentTerminalID = String(windowID)
        initializeSampleCommandForOnboardingIfNeeded(for: String(windowID))
        
        resizeTerminalWindowIfNeeded()
    }

    private func resizeTerminalWindowIfNeeded() {
        if OnboardingStateManager.shared.showOnboarding {
            DispatchQueue.main.async { // Ensure everything inside runs on the main thread
                if let runningTerminalApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Terminal" }) {
                    runningTerminalApp.activate()

                    let terminalElement = AXUIElementCreateApplication(runningTerminalApp.processIdentifier)
                    var focusedWindow: CFTypeRef?
                    let focusedWindowResult = AXUIElementCopyAttributeValue(terminalElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

                    guard focusedWindowResult == .success, let terminalWindow = focusedWindow else {
                        print("DEBUG: Failed to determine focused window for the Terminal application.")
                        return
                    }

                    var size: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(terminalWindow as! AXUIElement, kAXSizeAttribute as CFString, &size)
                    var currentSize = CGSize.zero
                    if result == .success {
                        AXValueGetValue(size as! AXValue, .cgSize, &currentSize)
                    }

                    if currentSize.height < 500 {
                        var newSize = CGSize(width: currentSize.width, height: 500) // Declare newSize as var
                        if let sizeValue = AXValueCreate(.cgSize, &newSize) {
                            let setResult = AXUIElementSetAttributeValue(terminalWindow as! AXUIElement, kAXSizeAttribute as CFString, sizeValue)
                            if setResult == .success {
                                print("DEBUG: Resized the terminal window to height 500.")

                                // Wait 1 second before posting the notification
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    NotificationCenter.default.post(name: .manualUpdateAppWindowPositionAndSize, object: nil)
                                }
                            } else {
                                print("DEBUG: Failed to resize the terminal window. Error: \(setResult.rawValue)")
                            }
                        }
                    }
                } else {
                    print("DEBUG: Could not find Terminal app.")
                }
            }
        }
    }

    
    @objc private func handleRequestTerminalContentAnalysis(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let text = userInfo["text"] as? String,
              let windowID = userInfo["currentTerminalWindowID"] as? CGWindowID,
              let source = userInfo["source"] as? String,
              let changeIdentifiedAt = userInfo["changeIdentifiedAt"] as? Double else {
            return
        }
        
        if hasGPTSuggestionsFreeTierCountReachedLimit && hasUserValidatedOwnOpenAIAPIKey == .usingFreeTier {
            return
        } else if hasUserValidatedOwnOpenAIAPIKey == .invalid {
            return
        }

        if !hasInternetConnection {
            print("No internet connection.")
            return
        }
        analyzeTerminalContent(text: text, windowID: windowID, source: source, changeIdentifiedAt: changeIdentifiedAt)
    }
    
    @objc private func handleSuggestionGenerationStatusChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let identifier = userInfo["identifier"] as? String,
              let isGeneratingSuggestion = userInfo["isGeneratingSuggestion"] as? Bool else {
            return
        }
        DispatchQueue.main.async {
            self.isGeneratingSuggestion[identifier] = isGeneratingSuggestion
            self.calculateSamAltmansFaceLikelihood()
        }
    }
    
    @objc private func handleUserValidatedOwnOpenAIAPIKey(_ notification: Notification) {
        print("DEBUG: handleUserValidatedOwnOpenAIAPIKey called")
        
        // Cancel any existing debounced task
        apiKeyValidationDebounceTask?.cancel()
        
        // Debounce logic
        apiKeyValidationDebounceTask = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            // Step 1: Determine the new validation state
            self.determineAPIKeyValidationState(from: notification)

            // Step 2: Process the assistant initialization for valid or acceptable free tier usage
            if self.hasUserValidatedOwnOpenAIAPIKey == .valid ||
               (self.hasUserValidatedOwnOpenAIAPIKey == .usingFreeTier && !self.hasGPTSuggestionsFreeTierCountReachedLimit) {
                self.processAssistantInitialization()
            } else {
                print("DEBUG: User's API key is invalid or free tier limit has been reached")
            }
        }
        
        // Execute the task after a delay of 0.25 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: apiKeyValidationDebounceTask!)
    }
    
    @objc private func handleUserAcceptedFreeCredits() {
        // Increase the limit for free tier suggestions by 2000
        GPTSuggestionsFreeTierLimit += 2000

        // Check if the free tier count has reached the limit again
        updateHasGPTSuggestionsFreeTierCountReachedLimit()
        
        print("User accepted free credits. New limit: \(GPTSuggestionsFreeTierLimit)")
    }


    private func determineAPIKeyValidationState(from notification: Notification) {
        if let userInfo = notification.userInfo, let isValid = userInfo["isValid"] as? Bool {
            self.hasUserValidatedOwnOpenAIAPIKey = isValid ? .valid : .invalid
        } else {
            print("DEBUG: User's API key validation state is unknown (nil)")
            self.hasUserValidatedOwnOpenAIAPIKey = .usingFreeTier
            print("DEBUG: hasUserValidatedOwnOpenAIAPIKey set to usingFreeTier due to nil validation state")
        }
    }

    private func processAssistantInitialization() {
        Task {
            print("DEBUG: Starting assistant initialization")
            await self.initializeAssistant()
            DispatchQueue.main.async {
                print("DEBUG: Assistant initialization completed")
                
                // Clear the entire threadIdDict
                self.threadIdDict.removeAll()
                print("DEBUG: threadIdDict cleared")
            }
        }
    }



    private func analyzeTerminalContent(text: String, windowID: CGWindowID, source: String, changeIdentifiedAt: Double) {
        guard let currentTerminalId = self.currentTerminalID else {
            print("DEBUG: Current terminal ID is nil.")
            return
        }
        self.currentTerminalStateID = UUID()
        guard let terminalStateID = self.currentTerminalStateID else {
            print("DEBUG: Current terminal state ID is nil.")
            return
        }
        
        // Log the event when terminal content analysis is requested
        let changedTerminalContentSentToGptAt = Date().timeIntervalSince1970
        MixpanelHelper.shared.trackEvent(name: "terminalContentAnalysisRequested", properties: [
            "currentTerminalId": currentTerminalId,
            "currentTerminalStateID": terminalStateID.uuidString,
            "changeIdentifiedAt": changeIdentifiedAt,
            "changedTerminalContentSentToGptAt": changedTerminalContentSentToGptAt,
            "triggerSource": source
        ])
        
        
        Task.detached { [weak self] in
            guard let strongSelf = self else {
                print("DEBUG: Self is nil.")
                return
            }
            do {
                print("DEBUG: Calling getOrCreateThreadId for currentTerminalId: \(currentTerminalId)")
                let threadId = try await strongSelf.getOrCreateThreadId(for: currentTerminalId)
                await strongSelf.processGPTResponse(
                    identifier: currentTerminalId,
                    terminalStateID: terminalStateID,
                    threadId: threadId,
                    messageContent: text,
                    changeIdentifiedAt: changeIdentifiedAt,
                    changedTerminalContentSentToGptAt: changedTerminalContentSentToGptAt,
                    source: source
                )
                
                if strongSelf.shouldGenerateFollowUpSuggestionsFlag {
                    DispatchQueue.main.asyncAfter(deadline: .now() + strongSelf.additionalSuggestionDelaySeconds) {
                        strongSelf.generateAdditionalSuggestions(
                            identifier: currentTerminalId,
                            terminalStateID: terminalStateID,
                            threadId: threadId,
                            changeIdentifiedAt: Date().timeIntervalSince1970,
                            source: "automaticFollowUpSuggestion"
                        )
                    }
                }
            } catch {
                print("DEBUG: Error getting or creating thread ID: \(error.localizedDescription)")
                
                if error.localizedDescription.contains("The network connection was lost") ||
                   error.localizedDescription.contains("The request timed out") {
                    DispatchQueue.main.async {
                        strongSelf.hasInternetConnection = false
                        strongSelf.isGeneratingSuggestion[currentTerminalId] = false
                    }
                } else if error.localizedDescription.contains("The Internet connection appears to be offline") {
                    DispatchQueue.main.async {
                        strongSelf.shouldShowNetworkIssueWarning = true
                        strongSelf.hasInternetConnection = false
                        strongSelf.isGeneratingSuggestion[currentTerminalId] = false
                    }
                }
            }
        }
    }
    
    private func generateAdditionalSuggestions(identifier: String, terminalStateID: UUID, threadId: String, changeIdentifiedAt: Double, source: String) {
        if hasGPTSuggestionsFreeTierCountReachedLimit && hasUserValidatedOwnOpenAIAPIKey == .usingFreeTier {
            return
        } else if hasUserValidatedOwnOpenAIAPIKey == .invalid {
            return
        }
        
        if !hasInternetConnection {
            return
        }
        
        guard let currentTerminalID = self.currentTerminalID,
              let currentTerminalStateID = self.currentTerminalStateID,
              currentTerminalID == identifier,
              currentTerminalStateID == terminalStateID else {
            return
        }
        
        if self.currentStateText != "No changes on Terminal" {
            return
        }
        
        if let suggestionsHistory = results[currentTerminalID]?.suggestionsHistory,
           let lastSuggestions = suggestionsHistory.last?.1,
           lastSuggestions.count >= self.maxSuggestionsPerEvent {
            return
        }
        
        // Log the event when terminal content analysis is requested
        let changedTerminalContentSentToGptAt = Date().timeIntervalSince1970
        MixpanelHelper.shared.trackEvent(name: "terminalContentAnalysisRequested", properties: [
            "currentTerminalId": currentTerminalID,
            "currentTerminalStateID": terminalStateID.uuidString,
            "changeIdentifiedAt": changeIdentifiedAt,
            "changedTerminalContentSentToGptAt": changedTerminalContentSentToGptAt,
            "triggerSource": source
        ])
        
        Task.detached { [weak self] in
            guard let strongSelf = self else { return }
            
            await strongSelf.processGPTResponse(
                identifier: identifier,
                terminalStateID: terminalStateID,
                threadId: threadId,
                messageContent: "please generate another suggestion of command. Don't provide a duplicated suggestion",
                changeIdentifiedAt: changeIdentifiedAt,
                changedTerminalContentSentToGptAt: changedTerminalContentSentToGptAt,
                source: source
            )
            
            if strongSelf.shouldGenerateFollowUpSuggestionsFlag {
                DispatchQueue.main.asyncAfter(deadline: .now() + strongSelf.additionalSuggestionDelaySeconds) {
                    strongSelf.generateAdditionalSuggestions(
                        identifier: identifier,
                        terminalStateID: terminalStateID,
                        threadId: threadId,
                        changeIdentifiedAt: Date().timeIntervalSince1970,
                        source: "automaticFollowUpSuggestion"
                    )
                }
            }
        }
    }
    
    @MainActor
    private func getOrCreateThreadId(for identifier: String) async throws -> String {
        print("DEBUG: getOrCreateThreadId called for identifier: \(identifier)")

        if let threadId = threadIdDict[identifier] {
            print("DEBUG: Found existing thread ID for identifier \(identifier): \(threadId)")
            return threadId
        }
        
        print("DEBUG: No existing thread ID for identifier \(identifier). Creating a new thread ID.")
        do {
            let createdThreadId = try await gptAssistantManager.createThread()
            threadIdDict[identifier] = createdThreadId
            print("DEBUG: Created new thread ID for identifier \(identifier): \(createdThreadId)")
            return createdThreadId
        } catch {
            print("DEBUG: Failed to create thread ID for identifier \(identifier) with error: \(error)")
            throw error
        }
    }

    
    private func processGPTResponse(identifier: String, terminalStateID: UUID, threadId: String, messageContent: String, changeIdentifiedAt: Double, changedTerminalContentSentToGptAt: Double, source: String) async {
        Task { @MainActor in
            NotificationCenter.default.post(name: .suggestionGenerationStatusChanged, object: nil, userInfo: ["identifier": identifier, "isGeneratingSuggestion": true])
        }
        do {
            let response = try await gptAssistantManager.processMessageInThread(threadId: threadId, messageContent: messageContent)
            if let command = response["command"] as? String,
               let commandExplanation = response["commandExplanation"] as? String,
               let intention = response["intention"] as? String,
               let shouldGenerateFollowUpSuggestions = response["shouldGenerateFollowUpSuggestions"] as? Bool {
                await appendResult(identifier: identifier, terminalStateID: terminalStateID, response: intention, command: command, explanation: commandExplanation)
                shouldGenerateFollowUpSuggestionsFlag = shouldGenerateFollowUpSuggestions
            }
        } catch {
            print("Error processing message in thread: \(error.localizedDescription)")
            
            if error.localizedDescription.contains("The network connection was lost") ||
               error.localizedDescription.contains("The request timed out") {
                DispatchQueue.main.async {
                    self.hasInternetConnection = false
                    self.isGeneratingSuggestion[identifier] = false
                }
            } else if error.localizedDescription.contains("The Internet connection appears to be offline") {
                DispatchQueue.main.async {
                    self.shouldShowNetworkIssueWarning = true
                    self.hasInternetConnection = false
                    self.isGeneratingSuggestion[identifier] = false
                }
            }
        }

        Task { @MainActor in
            NotificationCenter.default.post(name: .suggestionGenerationStatusChanged, object: nil, userInfo: ["identifier": identifier, "isGeneratingSuggestion": false])
            
            // Log the event when response is received from GPT
            let responseReceivedFromGptAt = Date().timeIntervalSince1970
            let delayToProcessChange = changedTerminalContentSentToGptAt - changeIdentifiedAt
            let delayToGetResponseFromGpt = responseReceivedFromGptAt - changedTerminalContentSentToGptAt
            let totalDelayToProcessChange = responseReceivedFromGptAt - changeIdentifiedAt
            
            MixpanelHelper.shared.trackEvent(name: "terminalContentAnalysisCompleted", properties: [
                "currentTerminalId": identifier,
                "currentTerminalStateID": terminalStateID.uuidString,
                "changeIdentifiedAt": changeIdentifiedAt,
                "changedTerminalContentSentToGptAt": changedTerminalContentSentToGptAt,
                "responseReceivedFromGptAt": responseReceivedFromGptAt,
                "delayToProcessChange": delayToProcessChange,
                "delayToGetResponseFromGpt": delayToGetResponseFromGpt,
                "totalDelayToProcessChange": totalDelayToProcessChange,
                "triggerSource": source
            ])
        }
    }
    
    private func incrementGPTSuggestionsFreeTierCount(by count: Int) {
        GPTSuggestionsFreeTierCount += count
    }
    private func updateHasGPTSuggestionsFreeTierCountReachedLimit() {
        hasGPTSuggestionsFreeTierCountReachedLimit = GPTSuggestionsFreeTierCount >= GPTSuggestionsFreeTierLimit
    }
    
    @MainActor
    private func appendResult(identifier: String, terminalStateID: UUID, response: String?, command: String?, explanation: String?) {
        guard let response = response, !response.isEmpty,
              let command = command, !command.isEmpty,
              let explanation = explanation, !explanation.isEmpty else {
            return
        }
        
        let newEntry = ["gptResponse": response, "suggestedCommand": command, "commandExplanation": explanation]
        let currentTime = Date()
        
        DispatchQueue.main.async {
            if var windowInfo = self.results[identifier] {
                var batchFound = false
                for (index, batch) in windowInfo.suggestionsHistory.enumerated() where batch.0 == terminalStateID {
                    windowInfo.suggestionsHistory[index].1.append(newEntry)
                    batchFound = true
                    break
                }
                if !batchFound {
                    windowInfo.suggestionsHistory.append((terminalStateID, [newEntry]))
                }
                windowInfo.suggestionsCount += 1
                windowInfo.updatedAt = currentTime
                self.results[identifier] = windowInfo
            } else {
                self.results[identifier] = (suggestionsCount: 1, suggestionsHistory: [(terminalStateID, [newEntry])], updatedAt: currentTime)
            }
            
            self.updateCounter += 1
            self.writeResultsToFile()
            if self.hasUserValidatedOwnOpenAIAPIKey == .usingFreeTier {
                self.incrementGPTSuggestionsFreeTierCount(by: 1)
            }
        }
    }
    
    private func getSharedTemporaryDirectory() -> URL {
        let sharedTempDirectory = URL(fileURLWithPath: "/tmp/shellMateShared")
        
        // Ensure the directory exists
        if !FileManager.default.fileExists(atPath: sharedTempDirectory.path) {
            do {
                try FileManager.default.createDirectory(at: sharedTempDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("Failed to create shared temporary directory: \(error)")
            }
        }
        
        return sharedTempDirectory
    }
    
    private func writeResultsToFile() {
        DispatchQueue.global(qos: .background).async { // Moved file writing to a background thread
            guard let currentTerminalID = self.currentTerminalID,
                  let terminalResults = self.results[currentTerminalID] else {
                return
            }
            let filePath = getShellMateCommandSuggestionsFilePath()
            
            var jsonOutput: [String: String] = [:]
            for (batchIndex, batch) in terminalResults.suggestionsHistory.enumerated() {
                for (suggestionIndex, gptResponse) in batch.1.enumerated() {
                    if let suggestedCommand = gptResponse["suggestedCommand"] {
                        let jsonId = "\(batchIndex + 1).\(suggestionIndex + 1)"
                        jsonOutput[jsonId] = suggestedCommand
                    }
                }
            }
            
            do {
                let jsonData = try JSONEncoder().encode(jsonOutput)
                try jsonData.write(to: filePath, options: .atomic)
            } catch {
                print("Failed to write JSON data to file: \(error.localizedDescription)")
            }
        }
    }
    
    @MainActor
    func initializeSampleCommandForOnboardingIfNeeded(for terminalID: String?) {
        guard let terminalID = terminalID else {
            return
        }
        
        let showOnboarding = UserDefaults.standard.object(forKey: "showOnboarding") as? Bool ?? true
        
        guard showOnboarding else {
            return
        }
        
        if self.results[terminalID]?.suggestionsHistory.isEmpty ?? true {
            self.appendResult(identifier: terminalID, terminalStateID: UUID(), response: "Complete the task", command: "sm \"\(getOnboardingSmCommand())\"", explanation: "This is a sample command to show you how to use ShellMate.")
        }
    }
}
