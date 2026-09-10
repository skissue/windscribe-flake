#pragma once

#include <cstdint>

namespace marks {

// fwmark on the WireGuard socket so its encrypted endpoint packets bypass the VPN routing
// table; matched verbatim by the kill-switch firewall. Constant by design — the routing-table
// id may vary (see WireGuardController::getRoutingTable), this must not.
constexpr uint32_t kWireGuardFwMark = 51820;

// Starting id for the WireGuard policy-routing table search (see WireGuardController::getRoutingTable).
// Independent of the fwmark: this seed may vary as tables get probed, the mark must not. Same value
// as the WireGuard tools default; kept separate so the two concepts don't get coupled.
constexpr uint32_t kInitialRoutingTableId = 51820;

// fwmark OpenVPN applies to its own packets (--mark); matched by the kill-switch firewall.
constexpr uint32_t kOpenVpnFwMark = 20310;

// WireGuard policy rules run before host policies such as Tailscale's 5210-5270 block.
// 4200 is intentionally left available for a user-installed fwmark jump.  Excluded
// destinations jump over the Windscribe capture rules to the nop landing rule, then
// resume normal policy evaluation.
constexpr uint32_t kWireGuardExcludeRulePriority = 4201;
constexpr uint32_t kWireGuardMainRulePriority = 4202;
constexpr uint32_t kWireGuardVpnRulePriority = 4203;
constexpr uint32_t kWireGuardLandingRulePriority = 4204;

} // namespace marks
