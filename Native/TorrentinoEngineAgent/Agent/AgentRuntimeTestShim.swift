// Layer: Engine Agent (Diagnostics & Observability).
// Role: compile-time shim for TorrentinoEngineAgentTests ONLY. The real
//       AgentRuntime (launchd lifecycle, Mach listener, engine wiring) belongs
//       to the agent TOOL and cannot be linked into the test bundle — it drags
//       in EngineCoordinator/BridgeTransferEngine and the ObjC++ adapter.
//       AgentService.health()/hello() read only `AgentRuntime.agentVersion`,
//       so the regression target compiles this minimal stand-in instead.
// Must-not: be registered in any target except TorrentinoEngineAgentTests, or
//           grow behavior — it exists so AgentService can compile in tests.
// Invariants: mirrors the real AgentRuntime.agentVersion semantics (a static
//             version string); no lifecycle behavior whatsoever.
// ponytail: ceiling is the duplicated version constant; upgrade when
//           agentVersion moves to a target-shared constants home both
//           AgentRuntime and the tests can import.

import Foundation

enum AgentRuntime {
    static let agentVersion = "wp13-tests"
}
