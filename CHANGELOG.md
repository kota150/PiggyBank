# Changelog

All notable changes to Piggy Bank are listed here.

## [Unreleased]

### Added
- Warnings at vendors and trainers: a ⚠ icon and tooltip flag anything that would dip into your savings, including Repair All.
- Flight path warnings in the destination tooltip.
- Auction house warnings: a ⚠ icon on item buyouts, and a pop-up heads-up (with its own set of puns) before you confirm a commodity purchase.
- All spending warnings share one setting: **Warn me before I spend savings**.
- **Classic Era support** (`PiggyBank_Vanilla.toc`): fallbacks for window parts older clients lack, the older bank/trade/mail/trainer events, an Interface Options entry, and warnings on the classic auction house's Bid and Buyout buttons.
- README with screenshots, CHANGELOG and .gitignore.

### Changed
- Retail TOC interface version set to 120105.

## [1.1.0] - 2026-10-30

### Added
- Redesigned `/piggy` window in Blizzard style, with **Piggy**, **Goals**, **Stats** and **Settings** tabs.
- Every setting can be changed in the window. Slash commands are now optional.
- Gold / silver / copper display for savings and spendable gold.
- Gold / silver / copper inputs for goals and for feeding the piggy.
- Savings rate slider with − / + buttons and mouse-wheel support.
- Stats tab: lifetime saved, income tracked, biggest deposit, goals completed, piggies smashed, times caught raiding the piggy, and more.
- New settings: lock the floating piggy, reset its position, turn scold pop-ups on or off, turn sounds on or off.
- Entry in **Esc → Options → AddOns** and in the minimap addon menu.
- WoW Forever support (`PiggyBank_Forever.toc`).

### Changed
- The floating piggy is now **off by default**.
- When you spend your savings, the piggy pops up with a random cheesy pun (26 of them), wiggles, and hides again after 8 seconds unless it's set to always show.

## [1.0.0] - 2026-10-30

### Added
- First release.
- Automatically saves a percentage (0–90%) of all gold you earn.
- Bag money counter shows only spendable gold.
- Bank, warband bank, guild bank and trade gold isn't counted as income. Mailbox gold is optional.
- Up to 5 savings goals with progress bars and a cheer when you reach one.
- Feed the piggy by hand.
- Whack the piggy 3 times to smash it and release your savings.
- Floating piggy with savings tooltip.
