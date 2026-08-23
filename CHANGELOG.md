# Changelog

## 1.0.1.0:
- Added German (de) translation - contributed by Phips98
- Added Ukrainian (uk) translation - contributed by daniilua

## 1.0.0.0:
- Improved negotiation cooldowns - they now expire by day instead of only at month boundaries, and the "try again" message shows the days remaining when less than a month is left
- Fixed multiplayer clients not seeing negotiated (unlisted) farmland purchases on the map/PDA until saving and rejoining
- Fixed being able to re-roll the NPC buyer's opening bid by repeatedly walking away from a sell negotiation (added a short re-list cooldown)
- Fixed a field staying buyable while not for sale after a negotiated purchase failed to complete on the server (for example, blocked by an active field mission); the availability bypass is now cleared as soon as the deal is processed
- Added Italian (it) translation - contributed by FirenzeIT

## 0.6.1.0 (Beta - 2026-05-15):
- Added Watchlist notification when a watched farmland's negotiation cooldown ends

## 0.6.0.0 (Beta - 2026-05-09):

### Added
- Added Watchlist - track farmlands you are interested in via the map's Farmlands subcategory and the farmland action menu, with a notification when a watched farmland goes up for sale; persists across save/load and isolates per-farm in multiplayer
- Added three independent negotiation toggles: Negotiate purchases, Negotiate sales, and Unlisted offers (replaces single on/off toggle)
- Added save migration from old single negotiation toggle - existing saves automatically map to all three settings
- Added color blind mode support - farmland overlays and legend switch to blue/orange when enabled in game settings

### Changed
- Improved negotiation fairness - players must increase buy offers and decrease sell asks each round
- Improved cooldown message in sell mode - no longer says "the owner is not interested" when the player is the owner

### Fixed
- Fixed seller counter-offer going below their minimum acceptable price during negotiation
- Fixed NPC buyer offer exceeding their maximum willingness to pay during negotiation
- Fixed seller's first counter sometimes equaling their opening demand with high stubbornness
- Fixed buyer's opening offer not visible when entering counter-ask in sell dialog
- Fixed negotiation dialog closing when submitting a non-monotonic offer/ask
- Fixed negotiation defaulting to Off on fresh saves instead of On
- Fixed listing prices and market values not updating when price per hectare is changed in settings
- Fixed sell cooldown blocking owner from re-listing after NPC buyer walks away
- Fixed "Negotiate Sale" button appearing on placeables and buildings instead of only on farmland
- Fixed buying or offering on a $0 farmland (map-border / outside-of-map plots) showing a "Negotiation error" - now falls through to the vanilla free purchase
- Fixed missing listing price on clients for newly-listed watched parcels in multiplayer

## 0.5.0.0 (Beta - 2026-03-21):
- Changed base price setting from multiplier presets to direct price per hectare input
- Fixed list price not showing correctly when Precision Farming mod is active
- Fixed logger registration error when multiple Ritter mods are loaded

## 0.4.0.2 (Beta):
- Added listing price validation: cannot exceed twice the market value
- Clamped the NPC's opening bid to the market-value ceiling
- Fixed sell negotiation exploit where inflated listing prices bypassed NPC market value cap

## 0.4.0.1 (Beta):
- Fixed keyboard navigation not reaching Farmland Market settings in Game Settings
- Fixed negotiation toggle (BinaryOption) visual glitch where slider was misaligned

## 0.4.0.0 (Beta)
- Added dedicated negotiation dialog with offer history, field details, and action buttons
- Added seller names in negotiation messages for clearer context
- Improved cooldown messages to show remaining time in months
- Changed from Alpha to Beta

## 0.3.0.0 (Alpha)
- Added negotiation system - buy and sell farmland through multi-round offers and counter-offers
- Added "Make offer" and "Negotiate sale" buttons replacing instant buy/sell
- Added negotiation cooldown per field to prevent repeated attempts
- Added negotiation toggle in Game Settings
- Added context box showing list price for listed fields and market value for owned fields
- Added multiplayer locking to prevent simultaneous negotiations on the same field
- Fixed farmland price leaking through "Not for sale" when Precision Farming is active

## 0.2.0.0 (Alpha)
- Added field availability system - not all fields are for sale at all times
- Added five difficulty presets: Easy, Normal, Hard, Harder, Realistic (or off)
- Added seasonal market variation - more fields listed Nov-Mar
- Added map color coding for available and unavailable fields
- Added farmland legend showing For Sale, Not For Sale, and My Farm
- Added base price multiplier setting (replaces fixed base price)
- Added settings to Game Settings menu (availability preset and price multiplier)
- Added multiplayer sync for all settings and availability state
- Changed the price multiplier tooltip to show the map's base price per hectare

## 0.1.0.0 (Alpha)
- Added the initial Farmland Market release
- Added estimated crop value to farmland prices
- Added a configurable base price per hectare
